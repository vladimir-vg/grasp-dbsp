%%%-------------------------------------------------------------------
%%% @doc Unit tests for gdbsp_rec state machine (pure functions, no processes).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_rec_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    init_defaults/1,
    init_preserves_optional_keys/1,
    reset_clears_data_preserves_wiring/1,
    source_first_delta_sets_epoch/1,
    source_streaming_started_once/1,
    source_stale_epoch_exits/1,
    source_future_epoch_buffered/1,
    source_epoch_done_consolidates/1,
    source_epoch_done_with_negative/1,
    coord_epoch_done_no_iter_sets_source_done/1,
    coord_epoch_done_with_iter_sends_diff/1,
    coord_epoch_done_consumer_diff/1,
    coord_iter_barrier_forwards_source/1,
    coord_epoch_begin_for_sourceless/1,
    body_integrates_feedback/1,
    body_empty_reports_empty/1,
    body_non_empty_reports_non_empty/1,
    body_negative_feedback_exits/1,
    drain_source_buf_consolidates/1,
    coord_iter_reset_mode_stores_deferred/1,
    body_state_reset_clears_and_forwards/1,
    body_state_reset_full_roundtrip/1,
    reset_clears_deferred_iter/1
]).

all() -> [
    init_defaults,
    init_preserves_optional_keys,
    reset_clears_data_preserves_wiring,
    source_first_delta_sets_epoch,
    source_streaming_started_once,
    source_stale_epoch_exits,
    source_future_epoch_buffered,
    source_epoch_done_consolidates,
    source_epoch_done_with_negative,
    coord_epoch_done_no_iter_sets_source_done,
    coord_epoch_done_with_iter_sends_diff,
    coord_epoch_done_consumer_diff,
    coord_iter_barrier_forwards_source,
    coord_epoch_begin_for_sourceless,
    body_integrates_feedback,
    body_empty_reports_empty,
    body_non_empty_reports_non_empty,
    body_negative_feedback_exits,
    drain_source_buf_consolidates,
    coord_iter_reset_mode_stores_deferred,
    body_state_reset_clears_and_forwards,
    body_state_reset_full_roundtrip,
    reset_clears_deferred_iter
].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.
init_per_testcase(_TestCase, Config) -> Config.
end_per_testcase(_TestCase, _Config) -> ok.

%%====================================================================
%% Helpers
%%====================================================================

stub_coord() ->
    spawn_link(fun() -> coord_loop() end).

coord_loop() ->
    receive
        {get_reports, Ref, Pid} -> Pid ! {Ref, <<"coord">>};
        _ -> coord_loop()
    end.

stub_source() ->
    spawn_link(fun() -> source_loop() end).

source_loop() ->
    receive _ -> source_loop() end.

body_pid() ->
    spawn_link(fun() -> body_loop() end).

body_loop() ->
    receive _ -> body_loop() end.

consumer_pid() ->
    spawn_link(fun() -> consumer_loop() end).

consumer_loop() ->
    receive _ -> consumer_loop() end.

coord_pid() -> spawn_link(fun() -> coord_loop() end).

src_pid() -> spawn_link(fun() -> source_loop() end).

%%====================================================================
%% Init
%%====================================================================

init_defaults(_Config) ->
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0}),
    <<"r1">> = maps:get(name, State),
    0 = maps:get(scc_id, State),
    undefined = maps:get(epoch, State),
    true = gdbsp_zset:is_empty(maps:get(consolidated_input_delta, State)),
    true = gdbsp_zset:is_empty(maps:get(consolidated_body_delta, State)),
    true = gdbsp_zset:is_empty(maps:get(consolidated_sent_delta, State)),
    undefined = maps:get(current_source_delta, State),
    false = maps:get(source_done, State),
    [] = maps:get(source_buf, State),
    undefined = maps:get(has_negatives, State).

init_preserves_optional_keys(_Config) ->
    C = coord_pid(),
    S = src_pid(),
    State = gdbsp_rec:init_state(#{
        name => <<"r1">>, scc_id => 1,
        coordinator => C, source_pid => S, body_input_pids => [body_pid()],
        consumers => [consumer_pid()]
    }),
    C = maps:get(coordinator, State),
    S = maps:get(source_pid, State).

reset_clears_data_preserves_wiring(_Config) ->
    C = coord_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    S2 = State#{epoch => 5, source_done => true},
    S3 = gdbsp_rec:reset_state(S2),
    undefined = maps:get(epoch, S3),
    C = maps:get(coordinator, S3),
    true = gdbsp_zset:is_empty(maps:get(consolidated_input_delta, S3)),
    false = maps:get(source_done, S3).

%%====================================================================
%% Source handler
%%====================================================================

source_first_delta_sets_epoch(_Config) ->
    C = coord_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    {S2, Actions} = gdbsp_rec:handle_source(State,
        {delta, #{epoch => 3}, [{1, <<"a">>}], src_pid()}, self()),
    3 = maps:get(epoch, S2),
    [{report_coord, C, {streaming_started, 3, _}}] = Actions.

source_streaming_started_once(_Config) ->
    C = coord_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    {S2, _} = gdbsp_rec:handle_source(State,
        {delta, #{epoch => 3}, [{1, <<"a">>}], src_pid()}, self()),
    {_, A2} = gdbsp_rec:handle_source(S2,
        {delta, #{epoch => 4}, [{1, <<"b">>}], src_pid()}, self()),
    [] = A2.

source_stale_epoch_exits(_Config) ->
    C = coord_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    {S2, _} = gdbsp_rec:handle_source(State,
        {delta, #{epoch => 5}, [{1, <<"a">>}], src_pid()}, self()),
    {_, [{exit, {stale_epoch, 3, 5}}]} = gdbsp_rec:handle_source(S2,
        {delta, #{epoch => 3}, [{1, <<"b">>}], src_pid()}, self()).

source_future_epoch_buffered(_Config) ->
    C = coord_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    {S2, _} = gdbsp_rec:handle_source(State,
        {delta, #{epoch => 5}, [{1, <<"a">>}], src_pid()}, self()),
    {S3, []} = gdbsp_rec:handle_source(S2,
        {delta, #{epoch => 7}, [{1, <<"b">>}], src_pid()}, self()),
    5 = maps:get(epoch, S3),
    2 = length(maps:get(source_buf, S3)).

source_epoch_done_consolidates(_Config) ->
    C = coord_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    {S2, _} = gdbsp_rec:handle_source(State,
        {delta, #{epoch => 5}, [{1, <<"a">>}], src_pid()}, self()),
    {S3, Actions} = gdbsp_rec:handle_source(S2,
        {delta, #{epoch => 5, barrier => epoch_done}, [{2, <<"a">>}], src_pid()}, self()),
    true = maps:get(source_done, S3),
    not gdbsp_zset:is_empty(maps:get(current_source_delta, S3)),
    [{report_coord, C, {source_done, 5, HasNeg, _}} | _] = Actions,
    false = HasNeg.

source_epoch_done_with_negative(_Config) ->
    C = coord_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    {S2, _} = gdbsp_rec:handle_source(State,
        {delta, #{epoch => 5}, [{1, <<"a">>}], src_pid()}, self()),
    {S3, Actions} = gdbsp_rec:handle_source(S2,
        {delta, #{epoch => 5, barrier => epoch_done}, [{-2, <<"a">>}], src_pid()}, self()),
    [{report_coord, C, {source_done, 5, HasNeg, _}} | _] = Actions,
    true = HasNeg.

%%====================================================================
%% Coordinator handler
%%====================================================================

coord_epoch_done_no_iter_sets_source_done(_Config) ->
    C = coord_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    {S2, []} = gdbsp_rec:handle_coord(State,
        {delta, #{epoch => 5, barrier => epoch_done}, [], C}, self()),
    5 = maps:get(epoch, S2),
    true = maps:get(source_done, S2),
    undefined = maps:get(iter, S2).

coord_epoch_done_with_iter_sends_diff(_Config) ->
    C = coord_pid(), Consumer = consumer_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C,
                                     consumers => [Consumer]}),
    State = State0#{epoch => 5, iter => 0,
                    consolidated_body_delta => gdbsp_zset:from_list([{1, <<"b">>}]),
                    consolidated_sent_delta => gdbsp_zset:new(),
                    source_done => true, current_source_delta => undefined},
    {S2, Actions} = gdbsp_rec:handle_coord(State,
        {delta, #{epoch => 5, barrier => epoch_done}, [], C}, self()),
    6 = maps:get(epoch, S2),
    undefined = maps:get(iter, S2),
    SendAction = hd([A || A = {send, P, _} <- Actions, P =:= Consumer]),
    {send, Consumer, {delta, #{epoch := 5}, [{1, <<"b">>}], _}} = SendAction,
    TermAction = lists:last([A || A = {send, P, _} <- Actions, P =:= Consumer]),
    {send, Consumer, {delta, Meta, [], _}} = TermAction,
    epoch_done = maps:get(barrier, Meta).

coord_epoch_done_consumer_diff(_Config) ->
    C = coord_pid(), Consumer = consumer_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C,
                                     consumers => [Consumer]}),
    BodyDelta = gdbsp_zset:from_list([{1, <<"b">>}]),
    State = State0#{epoch => 5, iter => 0,
                    consolidated_body_delta => BodyDelta,
                    consolidated_sent_delta => BodyDelta,
                    source_done => true, current_source_delta => undefined},
    {S2, Actions} = gdbsp_rec:handle_coord(State,
        {delta, #{epoch => 5, barrier => epoch_done}, [], C}, self()),
    BodyDelta = maps:get(consolidated_sent_delta, S2),
    ConsumerDataActions = [A || A = {send, P, {delta, _, Ds, _}} <- Actions, P =:= Consumer],
    [] = [D || {send, _, {delta, _, D, _}} <- ConsumerDataActions, D =/= []],
    ConsumerTermActions = [A || A = {send, P, {delta, _, [], _}} <- Actions, P =:= Consumer],
    true = length(ConsumerTermActions) >= 1.

coord_iter_barrier_forwards_source(_Config) ->
    C = coord_pid(), Body = body_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C,
                                     body_input_pids => [Body]}),
    CSD = gdbsp_zset:from_list([{1, <<"a">>}]),
    State = State0#{epoch => 5, current_source_delta => CSD},
    {S2, Actions} = gdbsp_rec:handle_coord(State,
        {delta, #{epoch => 5, barrier => {iter, 5, 0}}, [], C}, self()),
    0 = maps:get(iter, S2),
    undefined = maps:get(current_source_delta, S2),
    [{send, Body, {delta, _, [{1, <<"a">>}], _}}] = Actions.

coord_epoch_begin_for_sourceless(_Config) ->
    C = coord_pid(), Body = body_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C,
                                    body_input_pids => [Body]}),
    {S2, Actions} = gdbsp_rec:handle_coord(State,
        {delta, #{epoch => 0}, [], C}, self()),
    0 = maps:get(epoch, S2),
    [{send, Body, {delta, _, [], _}}] = Actions.

%%====================================================================
%% Body handler
%%====================================================================

body_integrates_feedback(_Config) ->
    C = coord_pid(), Body = body_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C,
                                     body_input_pids => [Body]}),
    State = State0#{epoch => 5},
    {S2, Actions} = gdbsp_rec:handle_body(State,
        {delta, #{epoch => 5}, [{1, <<"a">>}], body_pid()}, self()),
    not gdbsp_zset:is_empty(maps:get(consolidated_body_delta, S2)),
    [{send, Body, {delta, _, [{1, <<"a">>}], _}}] = Actions.

body_empty_reports_empty(_Config) ->
    C = coord_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    State = State0#{epoch => 5, iter => 0},
    {S2, Actions} = gdbsp_rec:handle_body(State,
        {delta, #{epoch => 5, barrier => {iter, 5, 0}}, [], body_pid()}, self()),
    [{report_coord, C, {iter_result, 5, 0, empty, _}}] = Actions,
    gdbsp_zset:is_empty(maps:get(consolidated_body_delta, S2)).

body_non_empty_reports_non_empty(_Config) ->
    C = coord_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    State = State0#{epoch => 5, iter => 1},
    {_S2, Actions} = gdbsp_rec:handle_body(State,
        {delta, #{epoch => 5, barrier => {iter, 5, 1}}, [{1, <<"b">>}], body_pid()}, self()),
    [{report_coord, C, {iter_result, 5, 1, non_empty, _}} | _] = Actions.

body_negative_feedback_exits(_Config) ->
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0}),
    State = State0#{epoch => 5},
    try gdbsp_rec:handle_body(State,
        {delta, #{epoch => 5}, [{-1, <<"a">>}], body_pid()}, self()) of
        _ -> ct:fail(expected_exit)
    catch
        exit:{negative_body_feedback, _, _} -> ok
    end.

%%====================================================================
%% Drain
%%====================================================================

drain_source_buf_consolidates(_Config) ->
    C = coord_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    {S1, _} = gdbsp_rec:handle_source(State0,
        {delta, #{epoch => 5}, [{1, <<"a">>}], src_pid()}, self()),
    {S2, Actions} = gdbsp_rec:drain_source_buf(S1, self(), C),
    not gdbsp_zset:is_empty(maps:get(current_source_delta, S2)),
    1 = gdbsp_zset:size(maps:get(consolidated_input_delta, S2)),
    [] = Actions.

%%====================================================================
%% state_reset — coordinator handler
%%====================================================================

coord_iter_reset_mode_stores_deferred(_Config) ->
    C = coord_pid(), Body = body_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C,
                                     body_input_pids => [Body]}),
    CSD = gdbsp_zset:from_list([{-1, <<"a">>}]),
    State = State0#{epoch => 5, current_source_delta => CSD},
    {S2, Actions} = gdbsp_rec:handle_coord(State,
        {delta, #{epoch => 5, barrier => {iter, 5, 0}, mode => reset}, [], C}, self()),
    0 = maps:get(iter, S2),
    CSD = maps:get(current_source_delta, S2),
    {delta, #{barrier := {iter, 5, 0}, mode := reset}, [], _} = maps:get(deferred_iter, S2),
    true = is_tuple(maps:get(deferred_iter, S2)),
    [{send, Body, {delta, #{barrier := state_reset}, [], _}}] = Actions.

%%====================================================================
%% state_reset — body handler
%%====================================================================

body_state_reset_clears_and_forwards(_Config) ->
    C = coord_pid(), Body = body_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C,
                                     body_input_pids => [Body]}),
    CID = gdbsp_zset:from_list([{1, <<"a">>}]),
    State = State0#{epoch => 5, consolidated_input_delta => CID,
                    consolidated_body_delta => gdbsp_zset:from_list([{1, <<"old">>}]),
                    deferred_iter => {delta, #{epoch => 5, barrier => {iter, 5, 0}},
                                      [], self()}},
    {S2, Actions} = gdbsp_rec:handle_body(State,
        {delta, #{epoch => 5, barrier => state_reset}, [], body_pid()}, self()),
    undefined = maps:get(deferred_iter, S2),
    true = gdbsp_zset:is_empty(maps:get(consolidated_body_delta, S2)),
    undefined = maps:get(current_source_delta, S2),
    [{send, Body, {delta, #{barrier := {iter, 5, 0}}, [{1, <<"a">>}], _}}] = Actions.

body_state_reset_full_roundtrip(_Config) ->
    C = coord_pid(), Body = body_pid(),
    State0 = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C,
                                     body_input_pids => [Body]}),
    State = State0#{epoch => 5, iter => 0,
                    consolidated_input_delta => gdbsp_zset:from_list([{1, <<"x">>}]),
                    consolidated_body_delta => gdbsp_zset:from_list([{1, <<"stale">>}]),
                    consolidated_sent_delta => gdbsp_zset:new(),
                    current_source_delta => gdbsp_zset:from_list([{-1, <<"a">>}]),
                    deferred_iter => {delta, #{epoch => 5, barrier => {iter, 5, 0}}, [], self()}},

    {S2, Actions1} = gdbsp_rec:handle_body(State,
        {delta, #{epoch => 5, barrier => state_reset}, [], self()}, self()),

    undefined = maps:get(deferred_iter, S2),
    true = gdbsp_zset:is_empty(maps:get(consolidated_body_delta, S2)),
    [{send, Body, {delta, #{barrier := {iter, 5, 0}}, [{1, <<"x">>}], _}}] = Actions1,

    BodyN = body_pid(),
    BeforeIter = maps:get(consolidated_body_delta, S2),
    true = gdbsp_zset:is_empty(BeforeIter),

    {S3, Actions2} = gdbsp_rec:handle_body(S2,
        {delta, #{epoch => 5, barrier => {iter, 5, 0}}, [{1, <<"x">>}], BodyN}, self()),

    not gdbsp_zset:is_empty(maps:get(consolidated_body_delta, S3)),
    ReportAction = lists:keyfind(report_coord, 1, Actions2),
    {report_coord, C2, {iter_result, 5, 0, non_empty, _}} = ReportAction,
    C2 = C.

reset_clears_deferred_iter(_Config) ->
    C = coord_pid(),
    State = gdbsp_rec:init_state(#{name => <<"r1">>, scc_id => 0, coordinator => C}),
    Deferred = {delta, #{epoch => 5, barrier => {iter, 5, 0}, mode => reset}, [], C},
    S1 = State#{epoch => 5, deferred_iter => Deferred},
    {delta, _, _, _} = maps:get(deferred_iter, S1),
    S2 = gdbsp_rec:reset_state(S1),
    undefined = maps:get(deferred_iter, S2),
    undefined = maps:get(epoch, S2).
