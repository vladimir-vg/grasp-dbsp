%%%-------------------------------------------------------------------
%%% @doc Barrier-aware per-key aggregation (non-linear, single-upstream).
%%%
%%% Receives IndexedZSet deltas. Maintains per-key input data (seen)
%%% and precomputed aggregate results. On barrier, recomputes
%%% aggregates for changed keys, emits ±1 deltas for diffs.
%%%
%%% State: #{init_fn => fun(), update_fn => fun(),
%%%          seen => #{Key => #{Val => Weight}},
%%%          results => #{Key => Agg}, buffer => [{W,{K,V}}],
%%%          downstream => pid}
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_aggregate).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type op_state() :: #{
    init_fn    := fun((term(), integer()) -> term()),
    update_fn  := fun((term(), term(), integer()) -> term()),
    result_fn  := fun((term()) -> term() | drop),
    seen       := #{term() => term()},
    results    := #{term() => term()},
    buffer     := [{integer(), term()}],
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{function := AggBin} = Args) when is_binary(AggBin) ->
    AggAtom = agg_binary_to_atom(AggBin),
    Value = maps:get(value_mod, Args, gdbsp_value),
    {Init, Update, Result} = agg_init_update(AggAtom, Value),
    init(#{init_fn => Init, update_fn => Update, result_fn => Result});
init(#{init_fn := InitFn, update_fn := UpdateFn, result_fn := ResultFn}) ->
    {#{init_fn => InitFn, update_fn => UpdateFn, result_fn => ResultFn,
       seen => #{}, results => #{}, buffer => [], downstream_label => default},
     [default], [default]}.

%% Aggregate init/update/result dispatch — delegates to gdbsp_operator_spec
%% for common aggregates; xor keeps its own Value:bytewise_xor integration.
-spec agg_init_update(atom(), module()) ->
    {fun((term(), integer()) -> term()),
     fun((term(), term(), integer()) -> term()),
     fun((term()) -> term() | drop)}.
agg_init_update('xor', Value) ->
    {fun(V, _W) -> {byte_size(V), V} end,
     fun({poisoned, _} = Acc, _V, _W) -> Acc;
         ({Len, Acc}, V, _W) when byte_size(V) =:= Len ->
             {Len, try Value:bytewise_xor(Acc, V)
                   catch error:undef -> Acc bxor V end};
         (_, _, _) -> {poisoned, none}
     end,
     fun({poisoned, _}) -> drop;
         ({_, Acc}) -> Acc
     end};
agg_init_update(Agg, _Value) ->
    gdbsp_operator_spec:agg_init_update(Agg).


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{buffer := Buf, downstream_label := Label} = St,
             default, {delta, Meta, Deltas}) ->
    NewBuf = Buf ++ Deltas,
    case maps:find(barrier, Meta) of
        {ok, _} ->
            {St2, Output} = compute_aggregate(St#{buffer := NewBuf}),
            Actions = case Output of
                [] -> [{send, Label, {delta, Meta, []}}];
                _  -> [{send, Label, {delta, Meta, Output}}]
            end,
            {St2#{buffer := []}, Actions};
        error ->
            {St#{buffer := NewBuf}, []}
    end.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.

%%====================================================================
%% Internal
%%====================================================================

compute_aggregate(#{init_fn := InitFn, update_fn := UpdateFn,
                    result_fn := ResultFn,
                    seen := Seen, results := Results,
                    buffer := Buf} = St) ->
    %% Unwrap IndexedZSet entries from buffer
    Entries = unwrap_buffer(Buf),
    %% Apply deltas to per-key seen maps, tracking changed keys
    {Seen2, Changed} = apply_to_seen(Entries, Seen, #{}),
    %% Recompute aggregates for changed keys, emit diffs
    {Results2, Output} = recompute_changed(Changed, Seen2, Results,
                                            InitFn, UpdateFn, ResultFn),
    {St#{seen := Seen2, results := Results2}, Output}.

unwrap_buffer(Buf) ->
    lists:flatmap(fun unwrap_entry/1, Buf).

%% {1, {Key, [{W, V}, ...]}}
unwrap_entry({1, {Key, Vals}}) -> [{Key, Vals}];
unwrap_entry({Key, Vals}) -> [{Key, Vals}].

%% Apply IndexedZSet entries (Key => Pairs) to seen maps
apply_to_seen([], Seen, Changed) ->
    {Seen, Changed};
apply_to_seen([{Key, Pairs} | Rest], Seen, Changed) ->
    KeySeen = maps:get(Key, Seen, #{}),
    KeySeen2 = gdbsp_zset:apply_deltas(gdbsp_zset:normalize_vals(Pairs), KeySeen),
    Changed2 = case KeySeen2 of
        KeySeen -> Changed;
        _ -> Changed#{Key => true}
    end,
    Seen2 = case gdbsp_zset:is_empty(KeySeen2) of
        true -> maps:remove(Key, Seen);
        false -> Seen#{Key => KeySeen2}
    end,
    apply_to_seen(Rest, Seen2, Changed2).

recompute_changed(Changed, Seen, Results, InitFn, UpdateFn, ResultFn) ->
    maps:fold(
        fun(Key, _, {ResAcc, OutAcc}) ->
            KeySeen = maps:get(Key, Seen, #{}),
            Acc = fold_key(KeySeen, InitFn, UpdateFn),
            NewAgg = case Acc of
                undefined -> undefined;
                _ -> ResultFn(Acc)
            end,
            OldAgg = maps:get(Key, Results, undefined),
            ResAcc2 = case NewAgg of
                undefined -> maps:remove(Key, ResAcc);
                drop -> maps:remove(Key, ResAcc);
                _ -> ResAcc#{Key => NewAgg}
            end,
            OutAcc2 = compute_agg_delta(Key, OldAgg, NewAgg, OutAcc),
            {ResAcc2, OutAcc2}
        end,
        {Results, []},
        Changed
    ).

fold_key(KeySeen, InitFn, UpdateFn) ->
    case maps:to_list(KeySeen) of
        [] -> undefined;
        [{V, W} | Rest] ->
            Acc0 = InitFn(V, W),
            lists:foldl(
                fun({V2, W2}, Acc) -> UpdateFn(Acc, V2, W2) end,
                Acc0,
                Rest
            )
    end.

compute_agg_delta(_Key, undefined, NewAgg, Acc) ->
    %% Key appeared
    [{1, {_Key, NewAgg}} | Acc];
compute_agg_delta(_Key, _OldAgg, undefined, Acc) ->
    %% Key disappeared
    [{-1, {_Key, _OldAgg}} | Acc];
compute_agg_delta(_Key, _OldAgg, drop, Acc) ->
    %% Key became invalid (poisoned group)
    [{-1, {_Key, _OldAgg}} | Acc];
compute_agg_delta(_Key, undefined, undefined, Acc) ->
    Acc;
compute_agg_delta(_Key, undefined, drop, Acc) ->
    Acc;
compute_agg_delta(_Key, OldAgg, NewAgg, Acc) when OldAgg =:= NewAgg ->
    Acc;
compute_agg_delta(_Key, OldAgg, NewAgg, Acc) ->
    %% Key changed
    [{1, {_Key, NewAgg}}, {-1, {_Key, OldAgg}} | Acc].

agg_binary_to_atom(<<"agg:", Name/binary>>) ->
    binary_to_existing_atom(Name, utf8);
agg_binary_to_atom(Name) when is_binary(Name) ->
    binary_to_existing_atom(Name, utf8).
