%%%-------------------------------------------------------------------
%%% @doc Barrier-aware equi-join (bilinear, multi-upstream).
%%%
%%% Two inputs: lhs and rhs IndexedZSets. Persistent per-key indexes
%%% merged on commit. Per-round deltas come from gdbsp_barrier:record's
%%% Acc — no duplicate lhs_buf / rhs_buf.
%%%
%%% Bilinear formula: (A⋈B)^Δ = A^Δ⋈B^Δ + A⁻¹⋈B^Δ + A^Δ⋈B⁻¹
%%%
%%% Label-based — no PIDs in state. The barrier is keyed by labels
%%% [lhs_label, rhs_label]. The proc wrapper resolves PIDs to labels.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_join).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").
-include("gdbsp_debug.hrl").

-type op_state() :: #{
    'fun'        := fun((term(), term(), term()) -> term()),
    lhs_index    := #{term() => [[term()]]},
    rhs_index    := #{term() => [[term()]]},
    lhs_label    := term(),
    rhs_label    := term(),
    barrier      := gdbsp_barrier:barrier_state(),
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

%%====================================================================
%% Init
%%====================================================================

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{shared_vars := SV, left_val_vars := LV, right_val_vars := RV,
       merged_fields := MF, lhs_label := LL, rhs_label := RL} = Args) ->
    Value = maps:get(value_mod, Args, gdbsp_value),
    JoinFn = fun(Key, LVal, RVal) ->
        M0 = merge_key_vars(SV, Key, #{}),
        M1 = merge_val_vars(LV, LVal, M0),
        RowMap = merge_val_vars(RV, RVal, M1),
        Value:map_to_struct(RowMap, {struct, MF, exact})
    end,
    init(#{'fun' => JoinFn, lhs_label => LL, rhs_label => RL});
init(#{'fun' := JoinFn,
       lhs_label := LL, rhs_label := RL}) ->
    BS = gdbsp_barrier:init([LL, RL]),
    State = #{
        'fun'      => JoinFn,
        lhs_index  => #{},
        rhs_index  => #{},
        lhs_label  => LL,
        rhs_label  => RL,
        barrier    => BS,
        downstream_label => default
    },
    {State, [LL, RL], [default]}.


%%====================================================================
%% handle_delta
%%====================================================================

-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{barrier := BS} = St, Label, Msg) ->
    case gdbsp_operator_spec:barrier_collect(St, Label, Msg, BS, 2) of
        {error, Reason} ->
            {St, [{error, Reason}]};
        {not_ready, NewSt} ->
            {NewSt, []};
        {ok, NewSt, Acc} ->
            commit(NewSt, Acc)
    end.

%%====================================================================
%% merge_metas — labeled Meta union
%%====================================================================

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(LabeledMetas) ->
    gdbsp_operator_spec:merge_metas_consistent(LabeledMetas).

%%====================================================================
%% Internal — commit: compute bilinear output, merge indexes, emit
%%====================================================================

commit(#{lhs_label := LL, rhs_label := RL,
         lhs_index := LI, rhs_index := RI,
          'fun' := JoinFn, downstream_label := OutLabel} = St, Acc) ->
    LHSMeta = gdbsp_operator_spec:meta_for(Acc, LL),
    RHSMeta = gdbsp_operator_spec:meta_for(Acc, RL),
    MergedMeta = merge_metas(#{LL => LHSMeta, RL => RHSMeta}),
    LB = gdbsp_operator_spec:deltas_of(Acc, LL),
    RB = gdbsp_operator_spec:deltas_of(Acc, RL),
    Deltas = compute_bilinear(JoinFn, LB, RB, LI, RI),
    NewLI = merge_indexed(LB, LI),
    NewRI = merge_indexed(RB, RI),
    St2 = St#{lhs_index := NewLI, rhs_index := NewRI},
    case Deltas of
        [] ->
            {St2, [{send, OutLabel, {delta, MergedMeta, []}}]};
        _ ->
            {St2, [{send, OutLabel, {delta, MergedMeta, Deltas}}]}
    end.

%%====================================================================
%% Bilinear join formula
%%====================================================================

compute_bilinear(JoinFn, LeftBuf, RightBuf, LeftPrev, RightPrev) ->
    Term1 = do_join(JoinFn, unwrap_deltas(LeftBuf), unwrap_deltas(RightBuf)),
    Term2 = do_join(JoinFn, index_to_flat(LeftPrev), unwrap_deltas(RightBuf)),
    Term3 = do_join(JoinFn, unwrap_deltas(LeftBuf), index_to_flat(RightPrev)),
    ?DBG("OP gdbsp_op_join INSTR bilinear: t1(ΔL⋈ΔR)=~w t2(L⋈ΔR)=~w t3(ΔL⋈R)=~w total=~w" ++ "~n", [length(Term1), length(Term2), length(Term3), length(Term1) + length(Term2) + length(Term3)]),
    Term1 ++ Term2 ++ Term3.

unwrap_deltas([]) -> [];
unwrap_deltas([{1, {Key, Vals}} | Rest]) ->
    [{Key, Vals} | unwrap_deltas(Rest)];
unwrap_deltas([{_Key, _Vals} = Tuple | Rest]) ->
    [Tuple | unwrap_deltas(Rest)].

do_join(JoinFn, Left, Right) ->
    LeftMap = indexed_to_map(Left),
    RightMap = indexed_to_map(Right),
    maps:fold(
        fun(Key, LeftVals, Acc) ->
            case maps:find(Key, RightMap) of
                {ok, RightVals} ->
                    [{LW * RW, JoinFn(Key, LV, RV)}
                     || {LW, LV} <- LeftVals,
                        {RW, RV} <- RightVals] ++ Acc;
                error ->
                    Acc
            end
        end,
        [],
        LeftMap
    ).

indexed_to_map(Indexed) ->
    lists:foldl(
        fun({Key, Vals}, Acc) ->
            Pairs = gdbsp_zset:normalize_vals(Vals),
            Old = maps:get(Key, Acc, []),
            maps:put(Key, Pairs ++ Old, Acc)
        end,
        #{},
        Indexed
    ).

index_to_flat(IndexedState) ->
    maps:fold(
        fun(Key, Vals, Acc) ->
            Acc ++ [{Key, [{W, V}]} || {W, V} <- Vals]
        end,
        [],
        IndexedState
    ).

merge_indexed([], State) -> State;
merge_indexed(Buffer, State) ->
    lists:foldl(
        fun({Key, Vals}, Acc) ->
            Pairs = gdbsp_zset:normalize_vals(Vals),
            Old = maps:get(Key, Acc, []),
            OldZset = gdbsp_zset:from_list(Old),
            Merged = gdbsp_zset:apply_deltas(Pairs, OldZset),
            MergedList = gdbsp_zset:to_list(Merged),
            case MergedList of
                [] -> maps:remove(Key, Acc);
                _  -> maps:put(Key, MergedList, Acc)
            end
        end,
        State,
        unwrap_deltas(Buffer)
    ).

merge_key_vars([V], Key, Map) ->
    maps:put(V, Key, Map);
merge_key_vars(Vars, Key, Map) ->
    merge_val_vars(Vars, Key, Map).

merge_val_vars([], _Val, Map) ->
    Map;
merge_val_vars(Vars, Val, Map) when is_tuple(Val), tuple_size(Val) =:= length(Vars) ->
    lists:foldl(fun({V, I}, Acc) ->
        maps:put(V, element(I, Val), Acc)
    end, Map, lists:zip(Vars, lists:seq(1, tuple_size(Val))));
merge_val_vars([V], Val, Map) ->
    maps:put(V, Val, Map).
