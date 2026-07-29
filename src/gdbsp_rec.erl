%%%-------------------------------------------------------------------
%%% @doc Pure functions for the Rec process.
%%%
%%% One Rec per recursive relation. Receives from source (optional),
%%% coordinator, and body. Maintains three cumulative state fields:
%%%
%%%   consolidated_input_delta — cumulative source data across ALL epochs
%%%   consolidated_body_delta  — input + all body output (relation's full state)
%%%   consolidated_sent_delta  — cumulative consumer-sent deltas (what consumers know)
%%%
%%% Consumer diff is always computed against consolidated_sent_delta.
%%% Epoch starts undefined. Sourced Recs set it on first source delta
%%% and emit {streaming_started, E, RecPid} once. Sourceless Recs set
%%% it via coordinator's epoch-begin (no-barrier delta).
%%%
%%% Coordinator, body_pid, consumer, source_pid are optional at init
%%% (default undefined) and set later via gen_server:call.
%%%
%%% Process wrapper: gdbsp_rec_proc.erl
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_rec).

-include("gdbsp_debug.hrl").

-export([init_state/1]).
-export([reset_state/1]).
-export([handle_source/3, handle_coord/3, handle_body/3]).
-export([drain_source_buf/3]).

-type rec_state() :: #{
    name                    := binary(),
    scc_id                  := non_neg_integer(),
    epoch                   := non_neg_integer() | undefined,
    iter                    := non_neg_integer() | undefined,
    consolidated_input_delta := gdbsp_zset:zset(),
    current_source_delta    := gdbsp_zset:zset() | undefined,
    consolidated_body_delta := gdbsp_zset:zset(),
    consolidated_sent_delta := gdbsp_zset:zset(),
    source_done             := boolean(),
    source_buf              := [{delta, map(), [term()], pid()}],
    has_negatives           := boolean() | undefined,
    deferred_iter           := {delta, map(), [term()], pid()} | undefined,
    coordinator             := pid() | undefined,
    body_input_pids         := [pid()],
    body_output_pid         := pid() | undefined,
    consumers               := [pid()],
    source_pid              := pid() | undefined,
    extra_source_pids       := [pid()]
}.

-type rec_action() ::
    {send, pid(), term()} |
    {report_coord, pid(), term()} |
    {exit, term()}.

-export_type([rec_state/0, rec_action/0]).

%%====================================================================
%% Init
%%====================================================================

-spec init_state(map()) -> rec_state().
init_state(InitArgs) ->
    #{name := Name, scc_id := SccId} = InitArgs,
    #{
        name           => Name,
        scc_id         => SccId,
        epoch          => maps:get(epoch, InitArgs, undefined),
        iter           => undefined,
        consolidated_input_delta => gdbsp_zset:new(),
        current_source_delta     => undefined,
        consolidated_body_delta  => gdbsp_zset:new(),
        consolidated_sent_delta  => gdbsp_zset:new(),
        source_done    => false,
        source_buf     => [],
        has_negatives     => undefined,
        deferred_iter     => undefined,
        coordinator    => maps:get(coordinator, InitArgs, undefined),
        body_input_pids => maps:get(body_input_pids, InitArgs, []),
        body_output_pid => maps:get(body_output_pid, InitArgs, undefined),
        consumers      => maps:get(consumers, InitArgs, []),
        source_pid     => maps:get(source_pid, InitArgs, undefined),
        extra_source_pids => maps:get(extra_source_pids, InitArgs, [])
    }.

%% @doc Reset all data/epoch fields to their init values while preserving
%% every wiring field (name, scc_id, coordinator, body/consumer/source pids).
%% Yields a state identical to a freshly wired Rec awaiting its first epoch.
-spec reset_state(rec_state()) -> rec_state().
reset_state(State) ->
    State#{
        epoch                    := undefined,
        iter                     := undefined,
        consolidated_input_delta := gdbsp_zset:new(),
        current_source_delta     := undefined,
        consolidated_body_delta  := gdbsp_zset:new(),
        consolidated_sent_delta  := gdbsp_zset:new(),
        source_done              := false,
        source_buf               := [],
        has_negatives            := undefined,
        deferred_iter            := undefined
    }.

%%====================================================================
%% Source handler
%%====================================================================
-spec handle_source(rec_state(), {delta, map(), [term()], pid()}, pid()) ->
    {rec_state(), [rec_action()]}.
handle_source(#{name := Name, scc_id := SccId,
                epoch := Epoch, coordinator := Coord,
                consolidated_input_delta := CID,
                source_buf := SB} = State,
              {delta, Meta, Deltas, _From} = Msg, RecPid) ->
    #{epoch := E} = Meta,
    Barrier = maps:get(barrier, Meta, undefined),
    ?DBG("REC ~s(scc:~w) SOURCE: epoch=~w cur_epoch=~w barrier=~p deltas=~w",
           [Name, SccId, E, Epoch, Barrier, length(Deltas)]),
    if
        Epoch =/= undefined, E < Epoch ->
            ?DBG("REC ~s SOURCE: stale_epoch ~w < ~w", [Name, E, Epoch]),
            {State, [{exit, {stale_epoch, E, Epoch}}]};
        Epoch =/= undefined, E > Epoch ->
            ?DBG("REC ~s SOURCE: future_epoch ~w > ~w, buffering", [Name, E, Epoch]),
            {State#{source_buf := SB ++ [Msg]}, []};
        true ->
            State2 = State#{source_buf := SB ++ [Msg], epoch := E},
            StreamingActions = case Epoch of
                undefined ->
                    ?DBG("REC ~s SOURCE: reporting streaming_started epoch=~w", [Name, E]),
                    [{report_coord, Coord, {streaming_started, E, RecPid}}];
                _ -> []
            end,
            case Barrier of
                epoch_done ->
                    {Consolidated, KeepBuf} = consolidate_source_buf(State2, E),
                    HasNeg = gdbsp_zset:has_negative_weight(Consolidated),
                    ?DBG("REC ~s SOURCE: epoch_done consolidated=~w has_negatives=~w keep_buf=~w",
                           [Name, gdbsp_zset:size(Consolidated), HasNeg, length(KeepBuf)]),
                    CID2 = gdbsp_zset:merge(CID, Consolidated),
                    ?DBG("REC ~s SOURCE: cumulative_input_delta size=~w",
                           [Name, gdbsp_zset:size(CID2)]),
                    State3 = State2#{source_buf := KeepBuf,
                                     consolidated_input_delta := CID2,
                                     current_source_delta := Consolidated,
                                     has_negatives := HasNeg,
                                     source_done := true},
                    DoneReport = {report_coord, Coord, {source_done, E, HasNeg, RecPid}},
                    {State3, StreamingActions ++ [DoneReport]};
                _ ->
                    {State2, StreamingActions}
            end
    end.

%%====================================================================
%% Coordinator handler
%%====================================================================

-spec handle_coord(rec_state(), {delta, map(), [term()], pid()}, pid()) ->
    {rec_state(), [rec_action()]}.
handle_coord(#{name := Name, scc_id := SccId, body_input_pids := BodyPids, consumers := Consumers,
               epoch := Epoch, iter := Iter,
               consolidated_body_delta := BodyDelta,
               consolidated_sent_delta := _SentDelta,
               consolidated_input_delta := _CID} = State,
             {delta, Meta, _Deltas, _From}, RecPid) ->
    #{epoch := E} = Meta,
    Barrier = maps:get(barrier, Meta, undefined),
    ?DBG("REC ~s(scc:~w) COORD: barrier=~p epoch=~w cur_epoch=~w body_pids=~w",
           [Name, SccId, Barrier, E, Epoch, length(BodyPids)]),
    case maps:find(barrier, Meta) of
        {ok, epoch_done} ->
            case Iter of
                undefined ->
                    ?DBG("REC ~s COORD: epoch_done at start → setting epoch=~w source_done",
                           [Name, E]),
                    State2 = State#{epoch := E, source_done := true},
                    {State2, []};
                _ ->
                    E = Epoch,
                    NextEpoch = E + 1,
                    ?DBG("REC ~s COORD: epoch_done → advancing to epoch ~w", [Name, NextEpoch]),
                    ConsumerDiff = gdbsp_zset:subtract_weights(BodyDelta, maps:get(consolidated_sent_delta, State)),
                    ?DBG("REC ~s COORD: consumer_diff=~w body_delta=~w sent_delta=~w",
                           [Name, gdbsp_zset:size(ConsumerDiff),
                            gdbsp_zset:size(BodyDelta),
                            gdbsp_zset:size(maps:get(consolidated_sent_delta, State))]),
                    ConsumerActions = case gdbsp_zset:is_empty(ConsumerDiff) of
                        true -> [];
                        false ->
                            Deltas = gdbsp_zset:to_list(ConsumerDiff),
                            [{send, C, {delta, #{epoch => E}, Deltas, RecPid}} || C <- Consumers]
                    end,
                    TermActions = [{send, C, {delta, Meta, [], RecPid}} || C <- Consumers],
                    State2 = State#{consolidated_sent_delta := BodyDelta,
                                    iter := undefined},
                    {State3, DrainActions} = drain_source_buf(
                        State2#{epoch := NextEpoch}, RecPid,
                        maps:get(coordinator, State)),
                    ?DBG("REC ~s COORD: epoch_done drain_actions=~w",
                           [Name, length(DrainActions)]),
                    {State3, ConsumerActions ++ TermActions ++ DrainActions}
            end;
        {ok, {iter, E, N}} ->
            E = Epoch,
            ?DBG("REC ~s COORD: iter epoch=~w round=~w body_pids=~w",
                   [Name, E, N, length(BodyPids)]),
            State2 = State#{epoch := E, iter := N},
            case maps:get(mode, Meta, undefined) of
                reset ->
                    ?DBG("REC ~s COORD: reset mode iter ~w → storing deferred_iter, sending state_reset",
                           [Name, N]),
                    DeferredMsg = {delta, Meta, [], _From},
                    State3 = State2#{deferred_iter := DeferredMsg},
                    ResetMeta = #{epoch => E, barrier => state_reset},
                    {State3, [{send, P, {delta, ResetMeta, [], RecPid}} || P <- BodyPids]};
                _ ->
                    {State3, DeltasOut} = case maps:get(current_source_delta, State2) of
                        undefined ->
                            {State2, []};
                        CSD ->
                            CSDList = gdbsp_zset:to_list(CSD),
                            ?DBG("REC ~s COORD: iter forwarding current_source_delta=~w",
                                   [Name, CSDList]),
                            {State2#{current_source_delta := undefined}, CSDList}
                    end,
                    ?DBG("REC ~s COORD: iter epoch=~w round=~w diff=~w to ~w body_pids",
                           [Name, E, N, length(DeltasOut), length(BodyPids)]),
                    {State3, [{send, P, {delta, Meta, DeltasOut, RecPid}} || P <- BodyPids]}
            end;
        error ->
            true = (Epoch =:= undefined orelse E >= Epoch),
            State2 = State#{epoch := E},
            ?DBG("REC ~s COORD: epoch_begin epoch=~w (no barrier)", [Name, E]),
            {State2, [{send, P, {delta, Meta, [], RecPid}} || P <- BodyPids]}
    end.

%%====================================================================
%% Body handler
%%====================================================================

-spec handle_body(rec_state(), {delta, map(), [term()], pid()}, pid()) ->
    {rec_state(), [rec_action()]}.
handle_body(#{name := Name, scc_id := SccId,
                epoch := Epoch, iter := Iter,
                consolidated_body_delta := BodyDelta,
                consolidated_sent_delta := SentDelta,
                body_input_pids := BodyPids,
                coordinator := Coord} = State,
              {delta, Meta, Deltas, _From}, RecPid) ->
    Barrier = maps:get(barrier, Meta, undefined),
    ?DBG("REC ~s(scc:~w) BODY: barrier=~p epoch=~w iter=~w deltas=~w body_delta_sz=~w sent_delta_sz=~w body_delta_head=~P",
           [Name, SccId, Barrier, Epoch, Iter, length(Deltas),
            gdbsp_zset:size(BodyDelta), gdbsp_zset:size(SentDelta),
            lists:sublist(gdbsp_zset:to_list(BodyDelta), 5), 80]),
    case Barrier of
        state_reset ->
            handle_body_state_reset(State#{name := Name, scc_id := SccId,
                                            epoch := Epoch, body_input_pids := BodyPids}, RecPid);
        _ ->
            NewZ = gdbsp_zset:from_list(Deltas),
            BodyDelta2 = gdbsp_zset:merge(BodyDelta, NewZ),
            State2 = State#{consolidated_body_delta := BodyDelta2},
            ?DBG("REC ~s BODY: ~s body_delta_sz=~w new_delta_sz=~w feedback_sz=~w new_head=~P",
                   [Name, barrier_label(Barrier), gdbsp_zset:size(BodyDelta2),
                    gdbsp_zset:size(NewZ), length(Deltas),
                    lists:sublist(Deltas, 5), 80]),
            FeedbackActions = case gdbsp_zset:is_empty(NewZ) of
                true -> [];
                false ->
                    check_no_negative_feedback(NewZ, Name),
                    DeltasOut = gdbsp_zset:to_list(NewZ),
                    [{send, P, {delta, #{epoch => Epoch}, DeltasOut, RecPid}} || P <- BodyPids]
            end,
            Report = case Barrier of
                {iter, E, N} ->
                    E = Epoch,
                    N = Iter,
                    Result = case gdbsp_zset:is_empty(NewZ) of
                        true -> empty;
                        false -> non_empty
                    end,
                    ?DBG("REC ~s BODY: result=~w round=~w feedback_actions=~w",
                           [Name, Result, N, length(FeedbackActions)]),
                    [{report_coord, Coord, {iter_result, E, N, Result, RecPid}}];
                _ -> []
            end,
            {State2, FeedbackActions ++ Report}
    end.

%%--------------------------------------------------------------------
%% state_reset handler
%%--------------------------------------------------------------------

handle_body_state_reset(#{name := Name,
                           body_input_pids := BodyPids,
                           consolidated_input_delta := CID,
                           source_pid := SrcPid} = State, RecPid) ->
    ?DBG("REC ~s BODY: state_reset → clearing consolidated_body_delta, sending consolidated_input_delta=~w",
           [Name, gdbsp_zset:size(CID)]),
    CIDList = case {SrcPid, gdbsp_zset:is_empty(CID)} of
        {undefined, _} -> [];
        {_, true} -> [];
        {_, false} -> gdbsp_zset:to_list(CID)
    end,
    #{deferred_iter := Deferred} = State,
    {delta, DefMeta, _, _} = Deferred,
    DefMeta2 = maps:remove(mode, DefMeta),
    IterDeltas = CIDList,
    IterActions = [{send, P, {delta, DefMeta2, IterDeltas, RecPid}} || P <- BodyPids],
    State2 = State#{deferred_iter := undefined,
                    consolidated_body_delta := gdbsp_zset:new(),
                    current_source_delta := undefined},
    ?DBG("REC ~s BODY: state_reset done, consolidated_body_delta cleared", [Name]),
    {State2, IterActions}.

%%--------------------------------------------------------------------
%% barrier label helper
%%--------------------------------------------------------------------

barrier_label(undefined) -> "no_barrier";
barrier_label(epoch_done) -> "epoch_done";
barrier_label({iter, _E, N}) -> lists:flatten(io_lib:format("iter=~w", [N]));
barrier_label(state_reset) -> "state_reset".

%%====================================================================
%% Internal — source buffer drain (called at epoch transition)
%%====================================================================

-spec drain_source_buf(rec_state(), pid(), pid()) -> {rec_state(), [rec_action()]}.
drain_source_buf(#{epoch := Epoch, source_buf := Buf,
                   consolidated_input_delta := CID} = State, RecPid, Coord) ->
    {Match, Keep} = lists:partition(
        fun({delta, Meta, _, _}) -> maps:get(epoch, Meta) =:= Epoch end,
        Buf),
    Z = lists:foldl(
        fun({delta, _Meta, Deltas, _From}, Acc) ->
            gdbsp_zset:merge(Acc, gdbsp_zset:from_list(Deltas))
        end,
        gdbsp_zset:new(),
        Match),
    HasNeg = gdbsp_zset:has_negative_weight(Z),
    EpochDoneReceived = lists:any(
        fun({delta, Meta, _, _}) ->
            maps:get(barrier, Meta, undefined) =:= epoch_done
        end, Match),
    ?DBG("REC drain_source_buf: epoch=~w consolidated=~w has_negatives=~w keep=~w epoch_done_received=~w",
           [Epoch, gdbsp_zset:size(Z), HasNeg, length(Keep), EpochDoneReceived]),
    CID2 = gdbsp_zset:merge(CID, Z),
    ?DBG("REC drain_source_buf: cumulative_input_delta size=~w (was ~w)",
           [gdbsp_zset:size(CID2), gdbsp_zset:size(CID)]),
    State2 = State#{source_buf := Keep,
                    consolidated_input_delta := CID2,
                    current_source_delta := Z,
                    has_negatives := HasNeg,
                    source_done := EpochDoneReceived},
    Report = case EpochDoneReceived of
        true -> [{report_coord, Coord, {source_done, Epoch, HasNeg, RecPid}}];
        false -> []
    end,
    {State2, Report}.

%%====================================================================
%% Internal — source buffer consolidation + negative detection
%%====================================================================

-spec consolidate_source_buf(rec_state(), non_neg_integer()) ->
    {gdbsp_zset:zset(), [{delta, map(), [term()], pid()}]}.
consolidate_source_buf(#{source_buf := Buf}, Epoch) ->
    {Match, Keep} = lists:partition(
        fun({delta, Meta, _, _}) -> maps:get(epoch, Meta) =:= Epoch end,
        Buf),
    Z = lists:foldl(
        fun({delta, _Meta, Deltas, _From}, Acc) ->
            gdbsp_zset:merge(Acc, gdbsp_zset:from_list(Deltas))
        end,
        gdbsp_zset:new(),
        Match),
    {Z, Keep}.

check_no_negative_feedback(NewZ, RecName) ->
    HasNeg = gdbsp_zset:has_negative_weight(NewZ),
    case HasNeg of
        true ->
            ?DBG("REC ~s FATAL: negative body feedback weights ~P",
                   [RecName, lists:sublist(gdbsp_zset:to_list(NewZ), 10), 20]),
            exit({negative_body_feedback, RecName, gdbsp_zset:to_list(NewZ)});
        false -> ok
    end.
