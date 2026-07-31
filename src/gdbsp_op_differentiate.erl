%%%-------------------------------------------------------------------
%%% @doc Barrier-aware discrete differentiator (LTI).
%%%
%%% Single-upstream stateful. Converts accumulated state back to
%%% deltas. Buffers deltas between barriers. On barrier:
%%%   - First epoch: emits full accumulated state
%%%   - Subsequent: emits diff vs previous state
%%%
%%% State: #{prev => zset(), buffer => [{W,Row}],
%%%          first => bool, downstream_label => term}
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_differentiate).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").
-include("gdbsp_debug.hrl").

-type op_state() :: #{
    prev       := gdbsp_zset:zset(),
    buffer     := [{integer(), term()}],
    first      := boolean(),
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(_Args) ->
    {#{prev => #{}, buffer => [], first => true,
       downstream_label => default},
     [default], [default]}.


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{buffer := Buf, prev := Prev, first := First,
               downstream_label := Label} = St, default, {delta, Meta, Deltas}) ->
    NewBuf = Buf ++ Deltas,
    case maps:find(barrier, Meta) of
        {ok, state_reset} ->
            {St#{prev := #{}, buffer := [], first := true},
             [{send, Label, {delta, Meta, []}}]};
        {ok, _} ->
            NewPrev = gdbsp_zset:merge(Prev, gdbsp_zset:from_list(NewBuf)),
            Diff = case First of
                true  -> gdbsp_zset:to_list(NewPrev);
                false -> gdbsp_zset:to_list(
                            gdbsp_zset:subtract_weights(NewPrev, Prev))
            end,
            ?DBG("OP gdbsp_op_differentiate INSTR barrier: first=~w buf_sz=~w prev_sz=~w new_prev_sz=~w output_sz=~w output_first=~P" ++ "~n",
                      [First, length(NewBuf), gdbsp_zset:size(Prev), gdbsp_zset:size(NewPrev),
                       length(Diff), lists:sublist(Diff, 3), 80]),
            Actions = case Diff of
                [] -> [{send, Label, {delta, Meta, []}}];
                _  -> [{send, Label, {delta, Meta, Diff}}]
            end,
            {#{prev => NewPrev, buffer => [], first => false, downstream_label => Label}, Actions};
        error ->
            {St#{buffer := NewBuf}, []}
    end.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.
