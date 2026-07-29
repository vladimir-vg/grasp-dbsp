%%%-------------------------------------------------------------------
%%% @doc Barrier-aware deduplication (non-linear, single-upstream).
%%%
%%% Maintains a private accumulated weight map (seen). Buffers
%%% deltas between barriers. On barrier, computes which rows
%%% transition from absent to present, emitting +1 deltas.
%%%
%%% State: #{seen => #{Row => Weight}, buffer => [{W, Row}],
%%%          downstream => pid}
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_distinct).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").
-include("gdbsp_debug.hrl").

-type op_state() :: #{
    seen       := #{term() => integer()},
    buffer     := [{integer(), term()}],
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(_Args) ->
    {#{seen => #{}, buffer => [], downstream_label => default},
     [default], [default]}.


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{seen := Seen, buffer := Buf0, downstream_label := Label} = St,
             default, {delta, Meta, Deltas}) ->
    NewBuf = Buf0 ++ Deltas,
    case maps:find(barrier, Meta) of
        {ok, _} ->
            {Output, Seen2} = compute_distinct(NewBuf, Seen),
            Actions = case Output of
                [] -> [{send, Label, {delta, Meta, []}}];
                _  -> [{send, Label, {delta, Meta, Output}}]
            end,
            {#{seen => Seen2, buffer => [], downstream_label => Label}, Actions};
        error ->
            {St#{buffer := NewBuf}, []}
    end.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.

%%====================================================================
%% Internal
%%====================================================================

compute_distinct(Buf, Seen) ->
    IterCount = lists:foldl(fun({W, Row}, {Out, S}) ->
        Old = maps:get(Row, S, 0),
        New = Old + W,
        Out2 = emit_transition(Row, Old, New, Out),
        S2 = case New of
            0 -> maps:remove(Row, S);
            _ -> S#{Row => New}
        end,
        ?DBG("OP gdbsp_op_distinct INSTR row=~100p old_w=~w delta=~w new_w=~w emits=~w" ++ "~n", [Row, Old, W, New, length(Out2) - length(Out)]),
        {Out2, S2}
    end, {[], Seen}, Buf),
    ?DBG("OP gdbsp_op_distinct INSTR barrier: rows_in=~w rows_out=~w seen_size=~w" ++ "~n", [length(Buf), length(element(1, IterCount)), map_size(element(2, IterCount))]),
    IterCount.

emit_transition(Row, Old, New, Acc) when Old =< 0, New > 0 -> [{1, Row} | Acc];
emit_transition(Row, Old, New, Acc) when Old > 0, New =< 0 -> [{-1, Row} | Acc];
emit_transition(_, _, _, Acc) -> Acc.
