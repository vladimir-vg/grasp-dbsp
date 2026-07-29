%%%-------------------------------------------------------------------
%%% @doc Barrier-aware one-step delay (z⁻¹, LTI).
%%%
%%% Single-upstream stateful. Shifts the delta stream by one barrier:
%%%   z⁻¹(s)[0] = 0          (empty on first barrier)
%%%   z⁻¹(s)[t] = s[t-1]     (t ≥ 1)
%%%
%%% State: #{prev_deltas => [{W,Row}], buffer => [{W,Row}],
%%%          downstream_label => term}
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_delay).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").
-include("gdbsp_debug.hrl").

-type op_state() :: #{
    prev_deltas := [term()],
    buffer      := [term()],
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(_Args) ->
    {#{prev_deltas => [], buffer => [],
       downstream_label => default},
     [default], [default]}.


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{buffer := Buf, prev_deltas := Prev,
               downstream_label := Label} = St,
             default, {delta, Meta, Deltas}) ->
    NewBuf = Buf ++ Deltas,
    case maps:find(barrier, Meta) of
        {ok, _} ->
            ?DBG("OP gdbsp_op_delay INSTR barrier: prev_sz=~w buf_sz=~w first=~P" ++ "~n",
                       [length(Prev), length(NewBuf), lists:sublist(NewBuf, 2), 60]),
            Actions = case Prev of
                [] -> [{send, Label, {delta, Meta, []}}];
                _  -> [{send, Label, {delta, Meta, Prev}}]
            end,
            {#{prev_deltas => NewBuf, buffer => [],
               downstream_label => Label},
             Actions};
        error ->
            {St#{buffer := NewBuf}, []}
    end.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.
