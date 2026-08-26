%%%-------------------------------------------------------------------
%%% @doc Barrier-aware per-key aggregation via a compiled aggregate plan.
%%%
%%% Receives IndexedZSet deltas where each value is the whole input row.
%%% Maintains per-key input data (seen) and precomputed aggregate
%%% results. On barrier, recomputes aggregates for changed keys and
%%% emits ±1 deltas for diffs.
%%%
%%% The plan (built by gdbsp_agg_plan) carries ordered accumulator slots
%%% (each an init/update/result MFA triple plus an argument expression
%%% over the row) and a result expression that combines slot results into
%%% the output struct. Slot-argument evaluation failures crash loudly —
%%% they indicate a type-checker bug, never a skip-able row.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_aggregate).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type op_state() :: #{
    plan       := map(),
    seen       := #{term() => #{term() => integer()}},
    results    := #{term() => term()},
    buffer     := [{integer(), term()}],
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{slots := _} = Plan) ->
    {#{plan => Plan, seen => #{}, results => #{}, buffer => [],
       downstream_label => default},
      [default], [default]}.


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{buffer := Buf, downstream_label := Label} = St,
             default, {delta, Meta, Deltas}) ->
    NewBuf = Buf ++ Deltas,
    case maps:find(barrier, Meta) of
        {ok, state_reset} ->
            {St#{seen := #{}, results := #{}, buffer := []},
             [{send, Label, {delta, Meta, []}}]};
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

compute_aggregate(#{plan := Plan, seen := Seen, results := Results,
                    buffer := Buf} = St) ->
    Entries = unwrap_buffer(Buf),
    {Seen2, Changed} = apply_to_seen(Entries, Seen, #{}),
    {Results2, Output} = recompute_changed(Changed, Seen2, Results, Plan),
    {St#{seen := Seen2, results := Results2}, Output}.

unwrap_buffer(Buf) ->
    lists:flatmap(fun unwrap_entry/1, Buf).

%% {1, {Key, [{W, Row}, ...]}}
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

recompute_changed(Changed, Seen, Results, Plan) ->
    maps:fold(
        fun(Key, _, {ResAcc, OutAcc}) ->
            KeySeen = maps:get(Key, Seen, #{}),
            NewAgg = compute_group(Plan, KeySeen),
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

%% Fold the rows for each slot, compute slot results, then evaluate the
%% result expression over the slot results. Returns the result map (raw
%% field values), `drop`, or `undefined` (empty group).
compute_group(Plan, KeySeen) ->
    case map_size(KeySeen) of
        0 ->
            undefined;
        _ ->
            Slots = maps:get(slots, Plan),
            Rows = maps:to_list(KeySeen),
            SlotResults = [compute_slot(Slot, Rows, Plan) || Slot <- Slots],
            case lists:any(fun(R) -> R =:= drop end, SlotResults) of
                true -> drop;
                false -> eval_result(Plan, SlotResults)
            end
    end.

compute_slot(#{arg := none, impl := {{M, IF, _}, {M, UF, _}, {M, RF, _}}},
             Rows, _Plan) ->
    [{_Row0, W0} | Rest] = Rows,
    Acc0 = M:IF(none, W0),
    Acc = lists:foldl(fun({_Row, W}, A) -> M:UF(A, none, W) end, Acc0, Rest),
    M:RF(Acc);
compute_slot(#{arg := ArgExpr, impl := {{M, IF, _}, {M, UF, _}, {M, RF, _}}},
             Rows, Plan) ->
    [{Row0, W0} | Rest] = Rows,
    V0 = eval_arg(ArgExpr, Row0, Plan),
    Acc0 = M:IF(V0, W0),
    Acc = lists:foldl(
        fun({Row, W}, A) ->
            V = eval_arg(ArgExpr, Row, Plan),
            M:UF(A, V, W)
        end, Acc0, Rest),
    M:RF(Acc).

eval_arg(ArgExpr, Row, Plan) ->
    RowArg = maps:get(row_arg, Plan),
    KwargOrder = maps:get(kwarg_order, Plan),
    case gdbsp_eval:eval_with_row(ArgExpr, Row, RowArg, KwargOrder) of
        {ok, {value, _, V}} -> V;
        drop_row -> erlang:error({slot_arg_drop_row, ArgExpr});
        {error, Reason} -> erlang:error({slot_arg_eval_failed, Reason})
    end.

eval_result(Plan, SlotResults) ->
    ResultExpr = maps:get(result_expr, Plan),
    RowArg = maps:get(row_arg, Plan),
    KwargOrder = maps:get(kwarg_order, Plan),
    Substituted = substitute_slots(ResultExpr, SlotResults),
    EmptyRow = {value, {struct, #{}, exact}, #{}},
    case gdbsp_eval:eval_with_row(Substituted, EmptyRow, RowArg, KwargOrder) of
        {ok, {value, {struct, _, _}, _} = StructVal} ->
            gdbsp_value:struct_to_map(StructVal);
        {ok, Other} ->
            erlang:error({aggregate_result_not_struct, Other});
        drop_row ->
            erlang:error(aggregate_result_drop_row);
        {error, Reason} ->
            erlang:error({aggregate_result_eval_failed, Reason})
    end.

substitute_slots(Expr, RawResults) ->
    substitute(Expr, RawResults).

substitute({value, T, {slot, N}}, RawResults) ->
    {value, T, lists:nth(N + 1, RawResults)};
substitute({value, _, _} = V, _RawResults) -> V;
substitute({arg, _} = A, _RawResults) -> A;
substitute({call, Name, PosArgs, KwArgs}, RawResults) ->
    {call, Name, [substitute(A, RawResults) || A <- PosArgs],
           maps:map(fun(_K, V) -> substitute(V, RawResults) end, KwArgs)};
substitute({get, Obj, Keys}, RawResults) ->
    {get, substitute(Obj, RawResults), [substitute(K, RawResults) || K <- Keys]};
substitute({slice, Obj, S1, S2, S3}, RawResults) ->
    {slice, substitute(Obj, RawResults),
            substitute_opt(S1, RawResults), substitute_opt(S2, RawResults),
            substitute_opt(S3, RawResults)}.

substitute_opt(undefined, _RawResults) -> undefined;
substitute_opt(E, RawResults) -> substitute(E, RawResults).

compute_agg_delta(_Key, undefined, NewAgg, Acc) ->
    [{1, {_Key, NewAgg}} | Acc];
compute_agg_delta(_Key, _OldAgg, undefined, Acc) ->
    [{-1, {_Key, _OldAgg}} | Acc];
compute_agg_delta(_Key, _OldAgg, drop, Acc) ->
    [{-1, {_Key, _OldAgg}} | Acc];
compute_agg_delta(_Key, undefined, undefined, Acc) ->
    Acc;
compute_agg_delta(_Key, undefined, drop, Acc) ->
    Acc;
compute_agg_delta(_Key, OldAgg, NewAgg, Acc) when OldAgg =:= NewAgg ->
    Acc;
compute_agg_delta(_Key, OldAgg, NewAgg, Acc) ->
    [{1, {_Key, NewAgg}}, {-1, {_Key, OldAgg}} | Acc].
