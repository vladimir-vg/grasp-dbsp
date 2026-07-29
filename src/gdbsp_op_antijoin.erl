%%%-------------------------------------------------------------------
%%% @doc Barrier-aware antijoin operator.
%%%
%%% Two inputs: left (flat rows) and right (flat or indexed rows).
%%% The antijoin outputs left rows whose key does NOT appear in the
%%% right side.
%%%
%%% Deltas:
%%%   Left delta row (key K, weight W): if right has K, suppressed;
%%%     otherwise passes through.
%%%   Right delta row (key K, weight W_R):
%%%     - If K goes from absent→present: output -Wa for each stored
%%%       left row on K.
%%%     - If K goes from present→absent: output +Wa for each stored
%%%       left row on K.
%%%
%%% Formula: (A ▶ B)^Δ = A^Δ − (A^Δ ⋈ B^Δ + A⁻¹ ⋈ B^Δ + A^Δ ⋈ B⁻¹)
%%%
%%% Uses gdbsp_barrier for synchronization. Per-round deltas come
%%% from barrier:record's Acc — no duplicate lhs_buf / rhs_buf.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_antijoin).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type op_state() :: #{
    key_vars       := [binary()],
    lhs_index      := #{term() => [{integer(), term()}]},
    rhs_index      := #{term() => integer()},
    lhs_label      := term(),
    rhs_label      := term(),
    barrier        := gdbsp_barrier:barrier_state(),
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

%%====================================================================
%% Init
%%====================================================================

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{key_vars := KeyVars,
       lhs_label := LL, rhs_label := RL}) ->
    BS = gdbsp_barrier:init([LL, RL]),
    State = #{
        key_vars   => KeyVars,
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
%% merge_metas
%%====================================================================

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(LabeledMetas) ->
    gdbsp_operator_spec:merge_metas_consistent(LabeledMetas).

%%====================================================================
%% Internal — commit
%%====================================================================

commit(#{lhs_label := LL, rhs_label := RL,
         lhs_index := LI, rhs_index := RI,
         key_vars := KeyVars,
         downstream_label := OutLabel} = St, Acc) ->
    LHSMeta = gdbsp_operator_spec:meta_for(Acc, LL),
    RHSMeta = gdbsp_operator_spec:meta_for(Acc, RL),
    MergedMeta = merge_metas(#{LL => LHSMeta, RL => RHSMeta}),
    LB = gdbsp_operator_spec:deltas_of(Acc, LL),
    RB = gdbsp_operator_spec:deltas_of(Acc, RL),
    TempRI = merge_right_buf(RB, RI, KeyVars),
    RightOut = right_delta_outputs(RB, RI, LI, KeyVars),
    LeftOut = left_delta_outputs(LB, TempRI, KeyVars),
    NewLI = merge_left_buf(LB, LI, KeyVars),
    NewRI = merge_right_buf(RB, RI, KeyVars),
    St2 = St#{lhs_index := NewLI, rhs_index := NewRI},
    Deltas = RightOut ++ LeftOut,
    case Deltas of
        [] ->
            {St2, [{send, OutLabel, {delta, MergedMeta, []}}]};
        _ ->
            {St2, [{send, OutLabel, {delta, MergedMeta, Deltas}}]}
    end.

%%====================================================================
%% Right delta outputs (A⁻¹ ⋈ B^Δ)
%%====================================================================

%%====================================================================
%% Right delta inputs are in indexed format {1, {Key, [{W, Val}]}}
%% where the inner weight is the actual delta weight.
%%====================================================================

unwrapped_right_deltas(RB, KeyVars) ->
    lists:flatmap(
        fun({1, {Key, InnerDeltas}}) when is_list(InnerDeltas) ->
            [{W, Key} || {W, _Val} <- InnerDeltas];
           ({W, Row}) when is_integer(W) ->
            [{W, extract_key(Row, KeyVars)}]
        end,
        RB
    ).

right_delta_outputs(RB, RI, LI, KeyVars) ->
    lists:flatmap(
        fun({W_R, K}) ->
            OldW = maps:get(K, RI, 0),
            NewW = OldW + W_R,
            A_Rows = maps:get(K, LI, []),
            case {OldW, NewW} of
                {0, Pos} when Pos > 0 ->
                    [{-Wa, Ra} || {Wa, Ra} <- A_Rows];
                {Pos, 0} when Pos > 0 ->
                    [{Wa, Ra} || {Wa, Ra} <- A_Rows];
                _ ->
                    []
            end
        end,
        unwrapped_right_deltas(RB, KeyVars)
    ).

%%====================================================================
%% Left delta outputs (A^Δ − A^Δ ⋈ B^Δ − A^Δ ⋈ B⁻¹)
%%====================================================================

left_delta_outputs(LB, TempRI, KeyVars) ->
    lists:flatmap(
        fun({W_L, LeftRow}) ->
            K = extract_key(LeftRow, KeyVars),
            case maps:get(K, TempRI, 0) of
                0 -> [{W_L, LeftRow}];
                _ -> []
            end
        end,
        LB
    ).

%%====================================================================
%% Index merging helpers
%%====================================================================

merge_right_buf(RB, State, KeyVars) ->
    lists:foldl(
        fun({W, K}, Acc) ->
            Old = maps:get(K, Acc, 0),
            NewW = Old + W,
            if NewW =:= 0 -> maps:remove(K, Acc);
               true -> maps:put(K, NewW, Acc)
            end
        end,
        State,
        unwrapped_right_deltas(RB, KeyVars)
    ).

%%====================================================================
%% Key extraction — left side (flat struct or map rows)
%%====================================================================

extract_key({value, {struct, _, _}, TypedValues}, KeyVars) ->
    case KeyVars of
        [V] ->
            {value, _Type, Val} = maps:get(V, TypedValues),
            Val;
        _ ->
            list_to_tuple([begin
                {value, _Type, Val} = maps:get(V, TypedValues),
                Val
            end || V <- KeyVars])
    end;
extract_key(Row, KeyVars) when is_map(Row) ->
    case KeyVars of
        [V] -> maps:get(V, Row);
        _ -> list_to_tuple([maps:get(V, Row) || V <- KeyVars])
    end.

merge_left_buf(Deltas, State, KeyVars) ->
    lists:foldl(
        fun({W, Row}, Acc) ->
            K = extract_key(Row, KeyVars),
            OldRows = maps:get(K, Acc, []),
            Merged = merge_row_value(W, Row, OldRows),
            case Merged of
                [] -> maps:remove(K, Acc);
                _  -> maps:put(K, Merged, Acc)
            end
        end,
        State,
        Deltas
    ).

merge_row_value(W, Row, []) ->
    if W =:= 0 -> [];
       true -> [{W, Row}]
    end;
merge_row_value(W, Row, [{OldW, _OldRow} | Rest]) ->
    NewW = OldW + W,
    if NewW =:= 0 -> Rest;
       true -> [{NewW, Row} | Rest]
    end.
