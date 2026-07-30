%%%-------------------------------------------------------------------
%%% @doc Collector process for DBSP operator tests.
%%%
%%% Accumulates delta messages from downstream operators and exposes
%%% them to test code. Each test spawns its own collector, links it
%%% into the graph as the terminal Downstream, and queries results
%%% after the epoch_done barrier propagates.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_test_collector_proc).

-export([start/0, stop/1, get/1, get_by_epoch/2, drain/1, pid/1,
         await_done/3, await_epoch/2]).

-record(state, {
    by_epoch = #{} :: #{non_neg_integer() => [[term()]]},
    ordered = []      :: [[term()]],
    waiters = #{}     :: #{term() => [{pid(), reference()}]},
    done_keys = []    :: [term()]   %% epoch keys that already have IsDone=true
}).

-type collector() :: pid().

%% @doc Spawn a collector process. Returns PID.
-spec start() -> collector().
start() ->
    spawn(fun() -> loop(#state{}) end).

%% @doc Stop the collector.
-spec stop(collector()) -> ok.
stop(Pid) ->
    Pid ! stop.

%% @doc Return accumulated deltas (across all epochs) without clearing.
-spec get(collector()) -> [[term()]].
get(Pid) ->
    Ref = make_ref(),
    Pid ! {get, self(), Ref},
    receive
        {result, Ref, Deltas} -> Deltas
    end.

%% @doc Return accumulated deltas and clear the collector state.
-spec drain(collector()) -> [[term()]].
drain(Pid) ->
    Ref = make_ref(),
    Pid ! {drain, self(), Ref},
    receive
        {result, Ref, Deltas} -> Deltas
    end.

%% @doc Block until barrier=epoch_done arrives for the given epoch,
%% then return accumulated deltas for that epoch. Timeout in milliseconds.
-spec await_done(collector(), non_neg_integer(), timeout()) -> [[term()]].
await_done(Pid, Epoch, Timeout) ->
    Ref = make_ref(),
    Pid ! {await_done, Epoch, self(), Ref},
    receive
        {done, Ref} -> ok
    after Timeout ->
        error({await_done_timeout, {epoch, Epoch}})
    end,
    get_by_epoch(Pid, Epoch).

%% @doc Return accumulated deltas for a specific epoch.
-spec get_by_epoch(collector(), non_neg_integer()) -> [[term()]].
get_by_epoch(Pid, Epoch) ->
    Ref = make_ref(),
    Pid ! {get_by_epoch, Epoch, self(), Ref},
    receive
        {result, Ref, Deltas} -> Deltas
    end.

%% @doc Identity — for readability in test assertions.
-spec pid(collector()) -> pid().
pid(Pid) -> Pid.

%% @doc Block until at least one delta (any epoch) arrives, then return
%% accumulated deltas for that epoch.
-spec await_epoch(collector(), timeout()) ->
    {non_neg_integer(), [[term()]]}.
await_epoch(Pid, Timeout) ->
    Ref = make_ref(),
    Pid ! {await_any, self(), Ref},
    receive
        {any_epoch, Ref, Epoch} ->
            {Epoch, get_by_epoch(Pid, Epoch)}
    after Timeout ->
        error(await_epoch_timeout)
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

loop(State) ->
    receive
        {delta, Meta, Deltas, _From} ->
            Epoch = maps:get(epoch, Meta),
            ByEpoch = State#state.by_epoch,
            PrevDeltas = maps:get(Epoch, ByEpoch, []),
            NewByEpoch = ByEpoch#{Epoch => PrevDeltas ++ Deltas},
            IsDone = maps:get(barrier, Meta, undefined) =:= epoch_done,
            NewState = State#state{
                by_epoch = NewByEpoch,
                ordered = State#state.ordered ++ Deltas
            },
            case IsDone of
                true ->
                    notify_waiters(Epoch, State#state.waiters),
                    loop(NewState#state{done_keys = [Epoch | State#state.done_keys]});
                false ->
                    loop(NewState)
            end;
        {get, From, Ref} ->
            From ! {result, Ref, State#state.ordered},
            loop(State);
        {get_by_epoch, Epoch, From, Ref} ->
            Result = maps:get(Epoch, State#state.by_epoch, []),
            From ! {result, Ref, Result},
            loop(State);
        {drain, From, Ref} ->
            From ! {result, Ref, State#state.ordered},
            loop(#state{});
        {await_done, Epoch, From, Ref} ->
            case lists:member(Epoch, State#state.done_keys) of
                true ->
                    From ! {done, Ref},
                    loop(State);
                false ->
                    Waiters = State#state.waiters,
                    Existing = maps:get(Epoch, Waiters, []),
                    NewWaiters = Waiters#{Epoch => [{From, Ref} | Existing]},
                    loop(State#state{waiters = NewWaiters})
            end;
        {await_any, From, Ref} ->
            Waiters = State#state.waiters,
            NewWaiters = Waiters#{
                any => [{From, Ref} | maps:get(any, Waiters, [])]
            },
            loop(State#state{waiters = NewWaiters});
        stop ->
            ok;
        {wiring_update, _Up, _Down, WiringRef, From} ->
            From ! {wiring_ack, WiringRef, self()},
            loop(State)
    end.

notify_waiters(Epoch, Waiters) ->
    case maps:find(Epoch, Waiters) of
        {ok, List} ->
            [Pid ! {done, Ref} || {Pid, Ref} <- List];
        error ->
            ok
    end,
    case maps:find(any, Waiters) of
        {ok, AnyList} ->
            [Pid ! {any_epoch, Ref, Epoch} || {Pid, Ref} <- AnyList];
        error ->
            ok
    end,
    ok.
