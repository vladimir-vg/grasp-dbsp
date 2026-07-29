%%%-------------------------------------------------------------------
%%% @doc Polling helpers to replace timer:sleep calls in CT suites.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_ct_sync).

-export([wait_until/2, wait_until/3]).

-export([wait_for_coord_epoch/2,
         wait_for_alive_no_crash/2]).

%%====================================================================
%% Generic polling
%%====================================================================

-spec wait_until(fun(() -> boolean()), pos_integer()) -> ok | no_return().
wait_until(Fun, TimeoutMs) ->
    wait_until(Fun, TimeoutMs, 10).

-spec wait_until(fun(() -> boolean()), pos_integer(), pos_integer()) ->
    ok | no_return().
wait_until(Fun, Timeout, Poll) when Timeout > 0 ->
    case Fun() of
        true  -> ok;
        false ->
            timer:sleep(min(Poll, Timeout)),
            wait_until(Fun, Timeout - Poll, Poll)
    end;
wait_until(_Fun, Timeout, _Poll) ->
    error({wait_until_timeout, Timeout}).

%%====================================================================
%% Coordinator helpers
%%====================================================================

-spec wait_for_coord_epoch(pid(), pos_integer()) -> ok | no_return().
wait_for_coord_epoch(Coord, Timeout) ->
    wait_until(fun() ->
        maps:get(epoch, sys:get_state(Coord)) =/= undefined
    end, Timeout).

%%====================================================================
%% Process lifecycle helpers
%%====================================================================

-spec wait_for_alive_no_crash(pid(), pos_integer()) -> ok | {crashed, term()}.
wait_for_alive_no_crash(Pid, Timeout) ->
    MRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MRef, process, Pid, Reason} ->
            {crashed, Reason}
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        ok
    end.
