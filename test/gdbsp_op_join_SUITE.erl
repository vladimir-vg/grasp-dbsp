%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_join (barrier-aware bilinear join).
%%%
%%% Spawns the operator via gdbsp_op_proc, sends deltas from
%%% lhs/rhs collector processes, asserts barrier-tagged output.
%%%
%%% Label-based — no PIDs in init args. Operator uses labels [lhs,rhs].
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_join_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_all_same/1,
          merge_metas_mismatch_crashes/1,
          merge_metas_epoch_mismatch_crashes/1,
          bilinear_all_three_terms_fire_on_overlap/1]).

%% Proc
-export([no_barrier_no_output/1,
          one_barrier_no_output/1,
          both_barriers_bilinear_output/1,
          empty_deltas_on_both_sides/1,
          consecutive_barriers/1,
          tag_mismatch_crashes/1,
           unknown_sender_crashes/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [
        merge_metas_all_same,
        merge_metas_mismatch_crashes,
        merge_metas_epoch_mismatch_crashes,
        bilinear_all_three_terms_fire_on_overlap
    ]},
     {proc, [parallel], [
        no_barrier_no_output,
        one_barrier_no_output,
        both_barriers_bilinear_output,
        empty_deltas_on_both_sides,
        consecutive_barriers,
        tag_mismatch_crashes,
         unknown_sender_crashes
     ]}].

%%====================================================================
%% CT lifecycle
%%====================================================================

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

start_collector() ->
    Parent = self(),
    spawn_link(fun() -> col_loop(Parent, []) end).

col_loop(Parent, Msgs) ->
    receive
        {drain, Ref} ->
            Parent ! {Ref, lists:reverse(Msgs)},
            col_loop(Parent, []);
        {await, Min, Ref} when length(Msgs) >= Min ->
            Parent ! {Ref, lists:reverse(Msgs)},
            col_loop(Parent, []);
        {await, Min, Ref} ->
            col_loop_await(Parent, Msgs, Min, Ref);
        stop -> ok;
        Msg -> col_loop(Parent, [Msg | Msgs])
    end.

col_loop_await(Parent, Msgs, Min, Ref) ->
    receive
        stop -> Parent ! {Ref, lists:reverse(Msgs)}, ok;
        Msg ->
            Msgs2 = [Msg | Msgs],
            case length(Msgs2) >= Min of
                true  -> Parent ! {Ref, lists:reverse(Msgs2)}, col_loop(Parent, []);
                false -> col_loop_await(Parent, Msgs2, Min, Ref)
            end
    end.

await(Pid, Min) ->
    Ref = make_ref(),
    Pid ! {await, Min, Ref},
    receive {Ref, Msgs} -> Msgs
    after 5000 -> error(await_timeout)
    end.

drain(Pid) ->
    Ref = make_ref(),
    Pid ! {drain, Ref},
    receive {Ref, Msgs} -> Msgs
    after 1000 -> error(timeout)
    end.

cleanup(Pids) ->
    [catch stop(P) || P <- Pids, is_process_alive(P)],
    ok.

stop(Pid) -> Pid ! stop.

%% IndexedZSet helper: {OuterWeight, {Key, [{W, V}, ...]}}
mk_idx(Key, Vals) -> {1, {Key, Vals}}.

%% Simple join fun: {Key, LV, RV} -> Key
join_fun(Key, _LV, _RV) -> Key.

%%====================================================================
%% Pure — merge_metas
%%====================================================================

merge_metas_all_same(_Config) ->
    Meta = #{epoch => 0, barrier => {iter, 0, 0}},
    Result = gdbsp_op_join:merge_metas(#{lhs => Meta, rhs => Meta}),
    Meta = Result.

merge_metas_mismatch_crashes(_Config) ->
    MetaA = #{epoch => 0, barrier => {iter, 0, 0}},
    MetaB = #{epoch => 0, barrier => {iter, 0, 1}},
    try gdbsp_op_join:merge_metas(#{lhs => MetaA, rhs => MetaB}) of
        _ -> ct:fail(expected_error)
    catch
        error:{meta_mismatch, _} -> ok
    end.

merge_metas_epoch_mismatch_crashes(_Config) ->
    MetaA = #{epoch => 0, barrier => epoch_done},
    MetaB = #{epoch => 1, barrier => epoch_done},
    try gdbsp_op_join:merge_metas(#{lhs => MetaA, rhs => MetaB}) of
        _ -> ct:fail(expected_error)
    catch
        error:{meta_mismatch, _} -> ok
    end.

bilinear_all_three_terms_fire_on_overlap(_Config) ->
    {St0, _, _} = gdbsp_op_join:init(
        #{'fun' => fun join_fun/3, lhs_label => lhs, rhs_label => rhs}),
    DeltaA = [mk_idx(a, [{1, 1}])],
    DeltaB = [mk_idx(a, [{1, 2}])],
    Meta0 = #{epoch => 0, barrier => {iter, 0, 0}},
    Meta1 = #{epoch => 0, barrier => {iter, 0, 1}},
    %% Round 0: ΔL=[a], L_prev={}; ΔR=[b], R_prev={} → only t1 fires
    {St1, []} = gdbsp_op_join:handle_delta(
        St0, lhs, {delta, Meta0, DeltaA}),
    {St2, [{send, default, {delta, Meta0, [{1, a}]}}]} =
        gdbsp_op_join:handle_delta(
            St1, rhs, {delta, Meta0, DeltaB}),
    %% Round 1: send same data → ΔL∩L_prev≠∅, ΔR∩R_prev≠∅
    {St3, []} = gdbsp_op_join:handle_delta(
        St2, lhs, {delta, Meta1, DeltaA}),
    {_St4, [{send, default, {delta, Meta1, [{1, a}, {1, a}, {1, a}]}}]} =
        gdbsp_op_join:handle_delta(
            St3, rhs, {delta, Meta1, DeltaB}),
    ok.

%%====================================================================
%% Proc — start operator with lhs/rhs collectors
%%====================================================================

start_join() ->
    LHS = start_collector(),
    RHS = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_join, #{
        'fun' => fun join_fun/3,
        lhs_label => lhs, rhs_label => rhs
    }),
    Op ! {wiring_update, #{LHS => lhs, RHS => rhs}, #{default => Down}},
    {Op, LHS, RHS, Down}.

mk_delta(Epoch, Deltas, From) ->
    {delta, #{epoch => Epoch}, Deltas, From}.

mk_barrier_delta(Epoch, Tag, Deltas, From) ->
    {delta, #{epoch => Epoch, barrier => Tag}, Deltas, From}.

%%====================================================================
%% Proc — no barrier, no output
%%====================================================================

no_barrier_no_output(_Config) ->
    {Op, LHS, RHS, Down} = start_join(),
    Op ! mk_delta(0, [mk_idx(a, [{1, 1}])], LHS),
    Op ! mk_delta(0, [mk_idx(a, [{1, 2}])], RHS),
    [] = drain(Down),
    ok = cleanup([Op, LHS, RHS, Down]).

%%====================================================================
%% Proc — one barrier, no output
%%====================================================================

one_barrier_no_output(_Config) ->
    {Op, LHS, RHS, Down} = start_join(),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [mk_idx(a, [{1, 1}])], LHS),
    Op ! mk_delta(0, [mk_idx(a, [{1, 2}])], RHS),
    Op ! mk_barrier_delta(0, Tag, [], LHS),
    [] = drain(Down),
    ok = cleanup([Op, LHS, RHS, Down]).

%%====================================================================
%% Proc — both barriers trigger bilinear output
%%====================================================================

both_barriers_bilinear_output(_Config) ->
    {Op, LHS, RHS, Down} = start_join(),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [mk_idx(a, [{1, 1}])], LHS),
    Op ! mk_delta(0, [mk_idx(a, [{1, 2}])], RHS),
    Op ! mk_barrier_delta(0, Tag, [], LHS),
    Op ! mk_barrier_delta(0, Tag, [], RHS),
    Msgs = await(Down, 1),
    [{delta, #{barrier := Tag}, Output, _}] = Msgs,
    [{1, a}] = Output,
    ok = cleanup([Op, LHS, RHS, Down]).

%%====================================================================
%% Proc — empty deltas on both sides
%%====================================================================

empty_deltas_on_both_sides(_Config) ->
    {Op, LHS, RHS, Down} = start_join(),
    Tag = {iter, 0, 0},
    Op ! mk_barrier_delta(0, Tag, [], LHS),
    Op ! mk_barrier_delta(0, Tag, [], RHS),
    [] = drain(Down),
    ok = cleanup([Op, LHS, RHS, Down]).

%%====================================================================
%% Proc — consecutive barrier rounds within same epoch
%%====================================================================

consecutive_barriers(_Config) ->
    {Op, LHS, RHS, Down} = start_join(),
    %% Round 0
    Op ! mk_delta(0, [mk_idx(a, [{1, 1}])], LHS),
    Op ! mk_delta(0, [mk_idx(a, [{1, 2}])], RHS),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], LHS),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], RHS),
    Msgs0 = await(Down, 1),
    [{delta, #{barrier := {iter, 0, 0}}, [{1, a}], _}] = Msgs0,
    %% Round 1 — additional data
    Op ! mk_delta(0, [mk_idx(b, [{1, 3}])], LHS),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], LHS),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], RHS),
    [] = drain(Down),
    ok = cleanup([Op, LHS, RHS, Down]).

%%====================================================================
%% Proc — tag mismatch crashes
%%====================================================================

tag_mismatch_crashes(_Config) ->
    {Op, LHS, RHS, Down} = start_join(),
    unlink(Op),
    MRef = erlang:monitor(process, Op),
    Op ! mk_delta(0, [mk_idx(a, [{1, 1}])], LHS),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], LHS),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], RHS),
    receive
        {'DOWN', MRef, process, Op, _Reason} -> ok
    after 5000 ->
        erlang:demonitor(MRef),
        ct:fail(process_not_exited)
    end,
    ok = cleanup([LHS, RHS, Down]).

%%====================================================================
%% Proc — unknown sender crashes
%%====================================================================

unknown_sender_crashes(_Config) ->
    {Op, LHS, RHS, Down} = start_join(),
    unlink(Op),
    MRef = erlang:monitor(process, Op),
    Stranger = start_collector(),
    Op ! {delta, #{epoch => 0}, [{1, {a, [{1, 1}]}}], Stranger},
    receive
        {'DOWN', MRef, process, Op, _Reason} -> ok
    after 5000 ->
        erlang:demonitor(MRef),
        ct:fail(process_not_exited)
    end,
    ok = cleanup([LHS, RHS, Down, Stranger]).


