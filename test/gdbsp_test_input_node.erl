%%%-------------------------------------------------------------------
%%% @doc Input node — relays external deltas to downstream operators.
%%%
%%% Accepts {delta, Meta, Deltas, From} from dynamic sender and forwards
%%% to all wired downstream PIDs. Also accepts {feed, Deltas, PartitionInfo}
%%% from the consumer-manager — buffers until the next begin_epoch.
%%% Uses the same wiring_update protocol
%%% as gdbsp_op_proc: no-FromEpoch variant for initial wiring,
%%% FromEpoch variant for deferred (migration) wiring.
%%%
%%% Tracks current_epoch for stale-epoch detection and deferred-wiring
%%% application at epoch boundaries.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_test_input_node).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link(?MODULE, {}, []).

init({}) ->
    {ok, #{
        downstream_pids   => [],
        integrator        => undefined,
        ic_pid            => undefined,
        current_epoch     => undefined,
        pending_wiring    => #{},
        paused            => false,
        paused_buffer     => [],
        feed_buffer       => [],
        partition_offsets => #{}
    }}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

handle_call(_Call, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info({wiring_update, _Upstream, Downstream},
            #{current_epoch := CurE} = State) ->
    case CurE of
        undefined ->
            {noreply, apply_wiring(Downstream, State)};
        _ ->
            exit({wiring_after_epoch_started})
    end;
handle_info({wiring_update, _Upstream, Downstream, FromEpoch},
            #{current_epoch := CurE} = State) ->
    case CurE of
        _ when FromEpoch =< CurE ->
            {noreply, apply_wiring(Downstream, State)};
        _ ->
            PW = maps:get(pending_wiring, State),
            {noreply, State#{pending_wiring := PW#{FromEpoch => Downstream}}}
    end;
handle_info({delta, Meta, Deltas, _From}, State) ->
    #{epoch := E} = Meta,
    State1 = handle_epoch_msg(E, Meta, State),
    #{downstream_pids := Pids} = State1,
    case maps:get(paused, State1) of
        true ->
            State2 = buffer_deltas(Deltas, State1),
            {noreply, State2};
        false ->
            lists:foreach(fun(Pid) -> Pid ! {delta, Meta, Deltas, self()} end, Pids),
            notify_integrator(State1, Meta, Deltas),
            {noreply, State1}
    end;
handle_info({feed, Deltas, #{partition := P, max_offset := M}}, State) ->
    State1 = buffer_feed(Deltas, P, M, State),
    {noreply, State1};
handle_info({begin_epoch, E}, State) ->
    State1 = flush_feed_buffer(E, State),
    {noreply, State1#{current_epoch => E}};
handle_info({begin_paused_epoch, E}, State) ->
    {noreply, State#{current_epoch => E, paused => true}};
handle_info({resume_epoch, E}, #{paused_buffer := PausedB, feed_buffer := FeedB,
                                  downstream_pids := Pids} = State) ->
    lists:foreach(
        fun({Meta, Deltas}) ->
            lists:foreach(fun(Pid) -> Pid ! {delta, Meta, Deltas, self()} end, Pids),
            notify_integrator(State, Meta, Deltas)
        end, PausedB),
    FeedRows = feed_rows(FeedB),
    case FeedRows of
        [] -> ok;
        _ ->
            Batch = lists:reverse(FeedRows),
            FeedMeta = #{epoch => E, barrier => epoch_done},
            lists:foreach(fun(Pid) -> Pid ! {delta, FeedMeta, Batch, self()} end, Pids),
            notify_integrator(State, FeedMeta, Batch)
    end,
    {noreply, State#{current_epoch => E, paused => false, paused_buffer => [],
                     feed_buffer => [], partition_offsets => #{}}};
handle_info({set_integrator, Pid}, State) ->
    {noreply, State#{integrator => Pid}};
handle_info({set_ic, Pid}, State) ->
    {noreply, State#{ic_pid => Pid}};
handle_info(stop, State) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% Internal — feed buffering
%%====================================================================

buffer_feed(Deltas, P, M, #{feed_buffer := FB, partition_offsets := PO} = State) ->
    Entries = [{Row, W, P, M} || {Row, W} <- Deltas],
    NewFB = Entries ++ FB,
    State1 = State#{feed_buffer => NewFB,
                    partition_offsets => max_offset(P, M, PO)},
    case FB of
        [] -> signal_feed_arrived(State1);
        _  -> State1
    end.

signal_feed_arrived(#{ic_pid := ICPid} = State) when ICPid =/= undefined ->
    ICPid ! {feed_arrived},
    State;
signal_feed_arrived(State) ->
    State.

max_offset(P, M, PO) ->
    case maps:find(P, PO) of
        {ok, Old} when M > Old -> PO#{P => M};
        {ok, _} -> PO;
        error -> PO#{P => M}
    end.

flush_feed_buffer(E, #{downstream_pids := Pids, feed_buffer := FB} = State) ->
    Batch = case feed_rows(FB) of
        [] -> [];
        Rows -> lists:reverse(Rows)
    end,
    Meta = #{epoch => E, barrier => epoch_done},
    lists:foreach(fun(Pid) ->
        Pid ! {delta, Meta, Batch, self()}
    end, Pids),
    notify_integrator(State, Meta, Batch),
    State#{feed_buffer => [], partition_offsets => #{}}.

feed_rows([]) -> [];
feed_rows([{Row, W, _P, _M} | Rest]) ->
    [{W, Row} | feed_rows(Rest)].

%%====================================================================
%% Internal — epoch handling
%%====================================================================

handle_epoch_msg(E, _Meta, State) ->
    advance_epoch(E, State).

%%====================================================================
%% Internal — paused buffering
%%====================================================================

buffer_deltas(Deltas, #{paused_buffer := Buf} = State) ->
    Meta = #{epoch => maps:get(current_epoch, State)},
    State#{paused_buffer => [{Meta, Deltas} | Buf]}.

%%====================================================================
%% Internal — wiring
%%====================================================================

apply_wiring(Downstream, #{downstream_pids := OldPids} = State) ->
    NewPids = lists:usort(flatten_map_values(maps:values(Downstream))),
    State#{downstream_pids := lists:usort(OldPids ++ NewPids)}.

%%====================================================================
%% Internal — epoch advance + pending wiring
%%====================================================================

advance_epoch(E, #{current_epoch := CurE} = State)
  when CurE =:= undefined; E > CurE ->
    State1 = State#{current_epoch := E},
    PW = maps:get(pending_wiring, State1),
    {ToApply, Remaining} =
        lists:partition(fun({FE, _}) -> FE =< E end, maps:to_list(PW)),
    lists:foldl(
        fun({_FE, Ds}, Acc) ->
            apply_wiring(Ds, Acc)
        end,
        State1#{pending_wiring := maps:from_list(Remaining)},
        ToApply
    );
advance_epoch(E, #{current_epoch := CurE} = _State) when E < CurE ->
    exit({stale_epoch, {got, E}, {expected, CurE}});
advance_epoch(_E, State) ->
    State.

%%====================================================================
%% Internal
%%====================================================================

flatten_map_values(Vals) ->
    lists:flatmap(fun(L) when is_list(L) -> L; (P) -> [P] end, Vals).

notify_integrator(#{integrator := undefined}, _Meta, _Deltas) -> ok;
notify_integrator(#{integrator := IntPid}, Meta, Deltas) ->
    IntPid ! {delta, Meta, Deltas, self()},
    ok.
