%%%-------------------------------------------------------------------
%%% @doc Barrier-aware integrator (LTI).
%%%
%%% Single-upstream stateful. Maintains a private accumulated ZSet
%%% (never emitted). Buffers raw deltas between barriers. On barrier,
%%% emits all buffered deltas with the barrier tag.
%%%
%%% When scc_internal=true, handles state_reset barrier by clearing
%%% accumulated state and flushing the buffer (with barrier), enabling
%%% correct body-state reset during recursive iteration.
%%%
%%% State: #{state => #{Row => Weight}, buffer => [{W,Row}],
%%%          downstream_label => term(), scc_internal => boolean()}
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_integrate).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").
-include("gdbsp_debug.hrl").

-type op_state() :: #{
    state      := #{term() => integer()},
    buffer     := [{integer(), term()}],
    downstream_label := term(),
    scc_internal => boolean()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{scc_internal := _} = Args) ->
    {#{state => #{}, buffer => [],
       downstream_label => default,
       scc_internal => maps:get(scc_internal, Args, false)},
     [default], [default]};
init(_Args) ->
    {#{state => #{}, buffer => [],
       downstream_label => default},
     [default], [default]}.

-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{state := St0, buffer := Buf0,
               downstream_label := Label} = State,
             default, {delta, Meta, Deltas}) ->
    Barrier = maps:get(barrier, Meta, undefined),
    SccInternal = maps:get(scc_internal, State, false),
    case {Barrier, SccInternal} of
        {state_reset, true} ->
            ?DBG("OP gdbsp_op_integrate INSTR state_reset: clearing state_sz=~w buf_sz=~w",
                   [gdbsp_zset:size(St0), length(Buf0)]),
            Combined = Buf0 ++ Deltas,
            Actions = case Combined of
                [] -> [{send, Label, {delta, Meta, []}}];
                _  -> [{send, Label, {delta, Meta, Combined}}]
            end,
            {State#{state := #{}, buffer := []}, Actions};
        _ ->
            St1 = gdbsp_zset:apply_deltas(Deltas, St0),
            NewBuf = Buf0 ++ Deltas,
            case Barrier of
                undefined ->
                    {State#{state := St1, buffer := NewBuf}, []};
                _ ->
                    ?DBG("OP gdbsp_op_integrate INSTR barrier: state_sz=~w buf_sz=~w",
                           [gdbsp_zset:size(St1), length(NewBuf)]),
                    Actions = case NewBuf of
                        [] -> [{send, Label, {delta, Meta, []}}];
                        _  -> [{send, Label, {delta, Meta, NewBuf}}]
                    end,
                    {State#{state := St1, buffer := []}, Actions}
            end
    end.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.
