%%%-------------------------------------------------------------------
%%% @doc Unit tests for gdbsp_rec_coord state machine (pure functions).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_rec_coord_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    init_empty_scc/1,
    init_sourced_and_sourceless/1,
    reset_clears_epoch_preserves_membership/1,
    begin_epoch_sourceless_starts_immediately/1,
    begin_epoch_sourced_noop/1,
    streaming_started_collects_epochs/1,
    streaming_started_all_reports_triggers_init/1,
    streaming_started_not_sourced_exits/1,
    streaming_started_duplicate_exits/1,
    source_done_all_done_starts_iteration/1,
    source_done_stale_epoch_exits/1,
    source_done_during_iteration_exits/1,
    iter_result_all_empty_fixpoint/1,
    iter_result_mixed_next_round/1,
    fixpoint_advances_epoch/1,
    max_rounds_exceeds_exits/1
]).

all() -> [
    init_empty_scc,
    init_sourced_and_sourceless,
    reset_clears_epoch_preserves_membership,
    begin_epoch_sourceless_starts_immediately,
    begin_epoch_sourced_noop,
    streaming_started_collects_epochs,
    streaming_started_all_reports_triggers_init,
    streaming_started_not_sourced_exits,
    streaming_started_duplicate_exits,
    source_done_all_done_starts_iteration,
    source_done_stale_epoch_exits,
    source_done_during_iteration_exits,
    iter_result_all_empty_fixpoint,
    iter_result_mixed_next_round,
    fixpoint_advances_epoch,
    max_rounds_exceeds_exits
].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.
init_per_testcase(_TestCase, Config) -> Config.
end_per_testcase(_TestCase, _Config) -> ok.

%%====================================================================
%% Helpers
%%====================================================================

rec_pid() ->
    spawn_link(fun() -> rec_stub_loop() end).

rec_stub_loop() ->
    receive
        stop -> ok;
        _ -> rec_stub_loop()
    end.

all_rec_pids(State) ->
    maps:keys(maps:get(sourced, State)) ++ maps:keys(maps:get(sourceless, State)).

%%====================================================================
%% Init
%%====================================================================

init_empty_scc(_Config) ->
    {S, []} = gdbsp_rec_coord:init(#{scc_id => 0, sourced => #{}, sourceless => #{}}),
    0 = maps:get(scc_id, S),
    undefined = maps:get(epoch, S),
    0 = map_size(maps:get(sourced, S)).

init_sourced_and_sourceless(_Config) ->
    R1 = rec_pid(), R2 = rec_pid(),
    {S, []} = gdbsp_rec_coord:init(#{
        scc_id => 1,
        sourced => #{R1 => #{name => <<"r1">>}},
        sourceless => #{R2 => #{name => <<"r2">>}}
    }),
    <<"r1">> = maps:get(R1, maps:get(sourced, S)),
    <<"r2">> = maps:get(R2, maps:get(sourceless, S)).

reset_clears_epoch_preserves_membership(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{R1 => #{name => <<"r1">>}}, sourceless => #{}}),
    S2 = S#{epoch => 5, round => 3, sourced_epochs => #{R1 => 5}},
    S3 = gdbsp_rec_coord:reset_state(S2),
    undefined = maps:get(epoch, S3),
    undefined = maps:get(round, S3),
    <<"r1">> = maps:get(R1, maps:get(sourced, S3)).

%%====================================================================
%% begin_epoch
%%====================================================================

begin_epoch_sourceless_starts_immediately(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{}, sourceless => #{R1 => #{name => <<"r1">>}}}),
    {S2, Actions} = gdbsp_rec_coord:begin_epoch(S),
    0 = maps:get(epoch, S2),
    0 = maps:get(round, S2),
    true = length(Actions) >= 2.

begin_epoch_sourced_noop(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{R1 => #{name => <<"r1">>}}, sourceless => #{}}),
    {S2, []} = gdbsp_rec_coord:begin_epoch(S),
    undefined = maps:get(epoch, S2).

%%====================================================================
%% streaming_started
%%====================================================================

streaming_started_collects_epochs(_Config) ->
    R1 = rec_pid(), R2 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{R1 => #{name => <<"r1">>}, R2 => #{name => <<"r2">>}},
        sourceless => #{}}),
    {S2, []} = gdbsp_rec_coord:handle_streaming_started(S, R1, 5),
    1 = map_size(maps:get(sourced_epochs, S2)),
    5 = maps:get(R1, maps:get(sourced_epochs, S2)).

streaming_started_all_reports_triggers_init(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{R1 => #{name => <<"r1">>}}, sourceless => #{}}),
    {S2, Actions} = gdbsp_rec_coord:handle_streaming_started(S, R1, 5),
    5 = maps:get(epoch, S2),
    true = length(Actions) > 0,
    HasEpochDone = lists:any(
        fun({send, _, {delta, #{barrier := epoch_done}, _, _}}) -> true;
           (_) -> false end, Actions),
    true = HasEpochDone.

streaming_started_not_sourced_exits(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{scc_id => 1, sourced => #{}, sourceless => #{}}),
    {_, [{exit, {not_sourced_rec, _}}]} = gdbsp_rec_coord:handle_streaming_started(S, R1, 5).

streaming_started_duplicate_exits(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{R1 => #{name => <<"r1">>}}, sourceless => #{}}),
    {S2, _} = gdbsp_rec_coord:handle_streaming_started(S, R1, 5),
    {_, [{exit, {duplicate_streaming_started, _}}]} =
        gdbsp_rec_coord:handle_streaming_started(S2, R1, 5).

%%====================================================================
%% source_done
%%====================================================================

source_done_all_done_starts_iteration(_Config) ->
    R1 = rec_pid(), R2 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1,
        sourced => #{R1 => #{name => <<"r1">>}, R2 => #{name => <<"r2">>}},
        sourceless => #{}}),
    {S2, _} = gdbsp_rec_coord:handle_streaming_started(S, R1, 5),
    {S3, _} = gdbsp_rec_coord:handle_streaming_started(S2, R2, 5),
    {S5, []} = gdbsp_rec_coord:handle_source_done(S3, R1, 5, false),
    {_S6, IterActions} = gdbsp_rec_coord:handle_source_done(S5, R2, 5, false),
    true = length(IterActions) > 0.

source_done_stale_epoch_exits(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{R1 => #{name => <<"r1">>}}, sourceless => #{}}),
    S2 = S#{epoch := 5},
    {_, [{exit, {stale_epoch, _, _, _}}]} = gdbsp_rec_coord:handle_source_done(S2, R1, 3, false).

source_done_during_iteration_exits(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{R1 => #{name => <<"r1">>}}, sourceless => #{}}),
    S2 = S#{epoch := 5, round := 3},
    {_, [{exit, {source_done_during_iteration, _}}]} =
        gdbsp_rec_coord:handle_source_done(S2, R1, 5, false).

%%====================================================================
%% iter_result
%%====================================================================

iter_result_all_empty_fixpoint(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{}, sourceless => #{R1 => #{name => <<"r1">>}}}),
    S2 = S#{epoch := 5, round := 0},
    {S3, _} = gdbsp_rec_coord:handle_iter_result(S2, R1, 5, 0, empty),
    %% sourceless-only: fixpoint advances epoch and starts new iteration
    true = maps:get(epoch, S3) > 5,
    %% round is set to 0 by start_iteration in handle_fixpoint
    true = maps:get(round, S3) =/= undefined.

iter_result_mixed_next_round(_Config) ->
    R1 = rec_pid(), R2 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{}, sourceless => #{
            R1 => #{name => <<"r1">>}, R2 => #{name => <<"r2">>}}}),
    S2 = S#{epoch := 5, round := 0, round_reports => #{R1 => empty}},
    {S3, _Actions} = gdbsp_rec_coord:handle_iter_result(S2, R2, 5, 0, non_empty),
    %% After non-empty report from all → next round (since R2 was non_empty,
    %% the round advances to 1 even though R1 was empty)
    1 = maps:get(round, S3).

fixpoint_advances_epoch(_Config) ->
    R1 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{}, sourceless => #{R1 => #{name => <<"r1">>}}}),
    S2 = S#{epoch := 5, round := 0, round_reports => #{}},
    {S3, _Actions} = gdbsp_rec_coord:handle_iter_result(S2, R1, 5, 0, empty),
    %% sourceless-only: epoch advances to 6 and new iteration starts at round 0
    6 = maps:get(epoch, S3),
    0 = maps:get(round, S3).

max_rounds_exceeds_exits(_Config) ->
    R1 = rec_pid(), R2 = rec_pid(),
    {S, _} = gdbsp_rec_coord:init(#{
        scc_id => 1, sourced => #{}, sourceless => #{
            R1 => #{name => <<"r1">>}, R2 => #{name => <<"r2">>}}}),
    S2 = S#{epoch := 5, round := 10000, round_reports => #{R1 => non_empty}},
    {_, [{exit, {max_iterations_exceeded, _, _, _}}]} =
        gdbsp_rec_coord:handle_iter_result(S2, R2, 5, 10000, non_empty).
