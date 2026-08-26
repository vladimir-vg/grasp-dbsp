%%%-------------------------------------------------------------------
%%% @doc Input node — production source proc.
%%%
%%% Relays externally-fed deltas to the wired downstream operators.
%%% Shares the wiring_update protocol of gdbsp_op_proc: an immediate
%%% {wiring_update, Up, Down, WiringRef, From} is applied and
%%% acknowledged; delta messages are forwarded unchanged.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_input_node).
-behaviour(gen_server).

-export([start_link/0, pid/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link(?MODULE, #{}, []).

-spec pid(pid()) -> pid().
pid(Pid) -> Pid.

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
handle_info({delta, Meta, Deltas, _From}, #{downstream_pids := Pids} = State) ->
    lists:foreach(
        fun(Pid) -> Pid ! {delta, Meta, Deltas, self()} end,
        Pids),
    {noreply, State};
handle_info(stop, State) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    {noreply, State}.

flatten_map_values(Vals) ->
    lists:flatmap(fun(L) when is_list(L) -> L; (P) -> [P] end, Vals).
