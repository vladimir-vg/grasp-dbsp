%%%-------------------------------------------------------------------
%%% @doc Empty stream process.
%%%
%%% A nullary feeder that emits zero rows and echoes every barrier it
%%% receives to its wired downstream operators. Implemented as a
%%% standalone gen_server (not a gdbsp_op_proc-wrapped behavior module)
%%% because a nullary operator has no upstream pidmap to resolve.
%%%
%%% Top-level empties are driven by the ingress/harness with
%%% `epoch_done`; body-internal empties are driven by a fixpoint rec's
%%% iteration barriers. Both only ever forward `{delta, Meta, [], …}`.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_empty).
-behaviour(gen_server).

-export([start_link/0, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link(?MODULE, #{}, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

init(#{}) ->
    {ok, #{downstream_pids => []}}.

handle_call(_Call, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info({wiring_update, _Up, Down, WiringRef, From},
            #{downstream_pids := Old} = State) when is_reference(WiringRef) ->
    NewPids = flatten_map_values(maps:values(Down)),
    From ! {wiring_ack, WiringRef, self()},
    {noreply, State#{downstream_pids := Old ++ NewPids}};
handle_info({delta, Meta, _Deltas, _From}, #{downstream_pids := Pids} = State) ->
    lists:foreach(
        fun(Pid) -> Pid ! {delta, Meta, [], self()} end,
        Pids),
    {noreply, State};
handle_info(stop, State) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    {noreply, State}.

flatten_map_values(Vals) ->
    lists:flatmap(fun(L) when is_list(L) -> L; (P) -> [P] end, Vals).
