%%%-------------------------------------------------------------------
%%% @doc Pure functions for the Coordinator process.
%%%
%%% One coordinator per SCC. Manages epoch boundaries, streaming
%%% kick-off, source-done tracking, iteration rounds, and fixpoint
%%% detection. Never touches tuple data.
%%%
%%% Epoch starts undefined. Sourced Recs report streaming_started
%%% (once per Rec). When all sourced have reported, coord epoch is
%%% set to min and epoch-begin is broadcast to sourceless.
%%%
%%% Process wrapper: gdbsp_rec_coord_proc.erl
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_rec_coord).

-include("gdbsp_debug.hrl").

-define(MAX_ITER_ROUNDS, 10000).

-export([init/1, begin_epoch/1]).
-export([reset_state/1]).
-export([handle_streaming_started/3]).
-export([handle_source_done/4]).
-export([handle_iter_result/5]).

-type coord_state() :: #{
    scc_id          := non_neg_integer(),
    epoch           := non_neg_integer() | undefined,
    sourced         := #{pid() => binary()},
    sourceless      := #{pid() => binary()},
    sourced_epochs  := #{pid() => non_neg_integer()},
    has_negatives_reports := #{pid() => boolean()},
    round           := non_neg_integer() | undefined,
    round_done      := #{pid() => boolean()},
    round_reports   := #{pid() => empty | non_empty}
}.

-type coord_action() ::
    {send, pid(), term()} |
    {exit, term()}.

-export_type([coord_state/0, coord_action/0]).

%%====================================================================
%% Init
%%====================================================================

-spec init(map()) -> {coord_state(), [coord_action()]}.
init(#{scc_id := SccId,
       sourced := Sourced, sourceless := Sourceless}) ->
    SourcedMap = maps:fold(fun(Pid, V, Acc) ->
        Acc#{Pid => maps:get(name, V)} end, #{}, Sourced),
    SourcelessMap = maps:fold(fun(Pid, V, Acc) ->
        Acc#{Pid => maps:get(name, V)} end, #{}, Sourceless),
    ?DBG("COORD scc:~w INIT sourced=~w sourceless=~w",
           [SccId, map_size(SourcedMap), map_size(SourcelessMap)]),
    State = #{
        scc_id => SccId,
        epoch => undefined,
        sourced => SourcedMap,
        sourceless => SourcelessMap,
        sourced_epochs => #{},
        has_negatives_reports => #{},
        round => undefined,
        round_done => #{},
        round_reports => #{}
    },
    {State, []}.

%% @doc Reset all epoch/round tracking to init values, preserving the SCC
%% membership wiring (scc_id, sourced, sourceless).
-spec reset_state(coord_state()) -> coord_state().
reset_state(State) ->
    State#{
        epoch                 := undefined,
        sourced_epochs        := #{},
        has_negatives_reports := #{},
        round                 := undefined,
        round_done            := #{},
        round_reports         := #{}
    }.

%% @doc Called after wiring is complete for the SCC. For sourceless-only
%% SCCs, this starts epoch 0 and broadcasts the first iteration barrier.
%% For sourced SCCs, this is a no-op (epoch starts on streaming_started).
-spec begin_epoch(coord_state()) -> {coord_state(), [coord_action()]}.
begin_epoch(#{sourced := Sourced, sourceless := Sourceless} = State) ->
    case {map_size(Sourced), map_size(Sourceless)} of
        {0, N} when N > 0 ->
            Epoch = 0,
            State1 = State#{epoch := Epoch},
            BeginActions = epoch_init_actions(State1, Epoch),
            {State2, IterActions} = start_iteration(State1, Epoch, false),
            {State2, BeginActions ++ IterActions};
        _ ->
            {State, []}
    end.

%%====================================================================
%% streaming_started — sourced Rec reports its epoch (once)
%%====================================================================

-spec handle_streaming_started(coord_state(), pid(), non_neg_integer()) ->
    {coord_state(), [coord_action()]}.
handle_streaming_started(#{scc_id := SccId, sourced_epochs := SE, sourced := Sourced,
                           sourceless := Sourceless} = State, From, E) ->
    case maps:is_key(From, Sourced) of
        false ->
            {State, [{exit, {not_sourced_rec, From}}]};
        true ->
            RecName = maps:get(From, Sourced),
            ?DBG("COORD scc:~w STREAMING_STARTED from ~s pid=~w epoch=~w (~w/~w sourced)",
                   [SccId, RecName, From, E, map_size(SE), map_size(Sourced)]),
            case maps:is_key(From, SE) of
                true ->
                    {State, [{exit, {duplicate_streaming_started, From}}]};
                false ->
                    SE2 = SE#{From => E},
                    State2 = State#{sourced_epochs := SE2},
                    case map_size(SE2) =:= map_size(Sourced) of
                        false ->
                            {State2, []};
                        true ->
                            MinEpoch = lists:min(maps:values(SE2)),
                            State3 = State2#{epoch := MinEpoch},
                            ?DBG("COORD scc:~w ALL_SOURCED epoch=~w broadcasting epoch_init to ~w recs",
                                   [SccId, MinEpoch, map_size(Sourced) + map_size(Sourceless)]),
                            {State3, epoch_init_actions(State3, MinEpoch)}
                    end
            end
    end.

%%====================================================================
%% source_done — sourced Rec completed source collection for epoch
%%====================================================================

-spec handle_source_done(coord_state(), pid(), non_neg_integer(), boolean()) ->
    {coord_state(), [coord_action()]}.
handle_source_done(#{epoch := Epoch} = State, From, E, _HasNeg)
  when Epoch =/= undefined, E < Epoch ->
    {State, [{exit, {stale_epoch, {got, E}, {expected, Epoch}, {from, From}}}]};
handle_source_done(#{epoch := Epoch} = State, From, E, _HasNeg)
  when Epoch =/= undefined, E > Epoch ->
    {State, [{exit, {future_epoch, {got, E}, {expected, Epoch}, {from, From}}}]};
handle_source_done(#{epoch := Epoch, round := Round} = State, From, _E, _HasNeg)
  when Epoch =/= undefined, Round =/= undefined ->
    {State, [{exit, {source_done_during_iteration, From}}]};
handle_source_done(#{scc_id := SccId, epoch := Epoch, sourced := Sourced,
                     round_done := Done, has_negatives_reports := HNReps} = State,
                   From, _E, HasNeg) ->
    case maps:is_key(From, Sourced) of
        false ->
            {State, [{exit, {not_sourced_rec, From}}]};
        true ->
            RecName = maps:get(From, Sourced),
            ?DBG("COORD scc:~w SOURCE_DONE from ~s pid=~w has_negatives=~w (~w/~w done)",
                   [SccId, RecName, From, HasNeg, map_size(Done), map_size(Sourced)]),
            Done2 = Done#{From => true},
            HNReps2 = HNReps#{From => HasNeg},
            State2 = State#{round_done := Done2, has_negatives_reports := HNReps2},
            case map_size(Done2) =:= map_size(Sourced) of
                true ->
                    AllNeg = lists:any(fun(X) -> X end, maps:values(HNReps2)),
                    ?DBG("COORD scc:~w ALL_SOURCE_DONE → start_iteration epoch=~w reset=~w",
                           [SccId, Epoch, AllNeg]),
                    start_iteration(State2#{round_done := #{}}, Epoch, AllNeg);
                false ->
                    {State2, []}
            end
    end.

%%====================================================================
%% iter_result — Rec reports round result
%%====================================================================

-spec handle_iter_result(coord_state(), pid(), non_neg_integer(),
                          non_neg_integer(), empty | non_empty) ->
    {coord_state(), [coord_action()]}.
handle_iter_result(#{epoch := Epoch, round := Round} = State,
                   From, E, N, Result) ->
    if
        Epoch =/= undefined, E =/= Epoch ->
            {State, [{exit, {wrong_barrier,
                              [{got_epoch, E}, {expected_epoch, Epoch}]}}]};
        Round =:= undefined ->
            {State, [{exit, {not_iterating, From}}]};
        N =/= Round ->
            {State, [{exit, {wrong_barrier,
                              [{got_round, N}, {expected_round, Round}]}}]};
        true ->
            S = maps:get(sourced, State),
            SL = maps:get(sourceless, State),
            case maps:is_key(From, S) orelse maps:is_key(From, SL) of
                false ->
                    {State, [{exit, {unknown_rec, From}}]};
                true ->
                    do_handle_iter_result(State, From, Result)
            end
    end.

%%====================================================================
%% Internal — start iteration (all sourced done)
%%====================================================================

start_iteration(#{scc_id := SccId} = State, Epoch, Reset) ->
    AllPids = all_rec_pids(State),
    Round0 = 0,
    BarrierMsg = make_barrier_delta(Epoch, {iter, Epoch, Round0}, Reset),
    State2 = State#{round := Round0},
    ?DBG("COORD scc:~w START_ITERATION epoch=~w round=~w reset=~w broadcasting {iter,~w,~w} to ~w recs",
           [SccId, Epoch, Round0, Reset, Epoch, Round0, length(AllPids)]),
    Actions = [{send, P, BarrierMsg} || P <- AllPids],
    {State2, Actions}.

%%====================================================================
%% Internal — record iter_result and check completion
%%====================================================================

do_handle_iter_result(#{scc_id := SccId, round_reports := Reports,
                         sourced := Sourced, sourceless := Sourceless} = State, From, Result) ->
    AllRecs = maps:merge(Sourced, Sourceless),
    RecName = maps:get(From, AllRecs),
    Reports2 = Reports#{From => Result},
    State2 = State#{round_reports := Reports2},
    AllPids = all_rec_pids(State2),
    ?DBG("COORD scc:~w ITER_RESULT from ~s result=~w (~w/~w recs)",
           [SccId, RecName, Result, map_size(Reports2), length(AllPids)]),
    case map_size(Reports2) =:= length(AllPids) of
        false ->
            {State2, []};
        true ->
            case lists:all(fun(R) -> R =:= empty end, maps:values(Reports2)) of
                true ->
                    ?DBG("COORD scc:~w FIXPOINT all_empty", [SccId]),
                    handle_fixpoint(State2);
                false ->
                    ?DBG("COORD scc:~w NEXT_ROUND not_all_empty", [SccId]),
                    handle_next_round(State2)
            end
    end.

handle_fixpoint(#{scc_id := SccId, epoch := Epoch, sourced := Sourced} = State) ->
    AllPids = all_rec_pids(State),
    DoneMsg = make_barrier_delta(Epoch, epoch_done),
    DoneActions = [{send, P, DoneMsg} || P <- AllPids],
    NextEpoch = Epoch + 1,
    State2 = State#{epoch := NextEpoch, round := undefined,
                    round_done := #{}, round_reports := #{},
                    has_negatives_reports := #{}},
    {State3, NextIterActions} = case map_size(Sourced) of
        0 ->
            EpochInit = epoch_init_actions(State, NextEpoch),
            {StateIter, IterActs} = start_iteration(State2, NextEpoch, false),
            {StateIter, EpochInit ++ IterActs};
        _ ->
            {State2, []}
    end,
    ?DBG("COORD scc:~w FIXPOINT_reached → epoch_done broadcast, advancing to epoch ~w",
           [SccId, NextEpoch]),
    {State3, DoneActions ++ NextIterActions}.

handle_next_round(#{scc_id := SccId, epoch := Epoch, round := Round} = State) ->
    NextRound = Round + 1,
    if NextRound > ?MAX_ITER_ROUNDS ->
        ?DBG("COORD scc:~w MAX_ITER_ROUNDS exceeded epoch=~w round=~w",
               [SccId, Epoch, NextRound]),
        {State, [{exit, {max_iterations_exceeded, SccId, Epoch, NextRound}}]};
    true ->
        AllPids = all_rec_pids(State),
        BarrierMsg = make_barrier_delta(Epoch, {iter, Epoch, NextRound}),
        Actions = [{send, P, BarrierMsg} || P <- AllPids],
        State2 = State#{round := NextRound, round_reports := #{}},
        ?DBG("COORD scc:~w NEXT_ROUND epoch=~w round=~w broadcasting {iter,~w,~w}",
               [SccId, Epoch, NextRound, Epoch, NextRound]),
        {State2, Actions}
    end.

%%====================================================================
%% Internal — helpers
%%====================================================================

all_rec_pids(#{sourced := S, sourceless := SL}) ->
    maps:keys(S) ++ maps:keys(SL).

epoch_init_actions(State, Epoch) ->
    Msg = {delta, #{epoch => Epoch, barrier => epoch_done}, [], self()},
    [{send, P, Msg} || P <- all_rec_pids(State)].

make_barrier_delta(Epoch, Tag) ->
    {delta, #{epoch => Epoch, barrier => Tag}, [], self()}.

make_barrier_delta(Epoch, Tag, false) ->
    make_barrier_delta(Epoch, Tag);
make_barrier_delta(Epoch, Tag, true) ->
    {delta, #{epoch => Epoch, barrier => Tag, mode => reset}, [], self()}.
