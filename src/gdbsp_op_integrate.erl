%%%-------------------------------------------------------------------
%%% @doc Barrier-aware integrator (LTI).
%%%
%%% Single-upstream stateful. Maintains a private accumulated ZSet
%%% (never emitted). Buffers raw deltas between barriers. On barrier,
%%% emits all buffered deltas with the barrier tag.
%%%
%%% State: #{state => #{Row => Weight}, buffer => [{W,Row}],
%%%          downstream => pid}
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
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(_Args) ->
    {#{state => #{}, buffer => [],
       downstream_label => default},
     [default], [default]}.

-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{state := St0, buffer := Buf0,
               downstream_label := Label} = State,
             default, {delta, Meta, Deltas}) ->
    St1 = gdbsp_zset:apply_deltas(Deltas, St0),
    NewBuf = Buf0 ++ Deltas,
    case maps:find(barrier, Meta) of
        {ok, _} ->
            ?DBG("OP gdbsp_op_integrate INSTR barrier: state_sz=~w buf_sz=~w first=~P" ++ "~n", [gdbsp_zset:size(St1), length(NewBuf), lists:sublist(NewBuf, 2), 60]),
            Actions = case NewBuf of
                [] -> [{send, Label, {delta, Meta, []}}];
                _  -> [{send, Label, {delta, Meta, NewBuf}}]
            end,
            {#{state => St1, buffer => [], downstream_label => Label},
             Actions};
        error ->
            {State#{state := St1, buffer := NewBuf}, []}
    end.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.
