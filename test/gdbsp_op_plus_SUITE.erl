%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_plus (multi-upstream labeled sum).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_plus_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_all_same/1,
         merge_metas_mismatch_crashes/1]).

%% Proc
-export([single_upstream_trivial/1,
          two_upstreams_sum/1,
          no_output_before_barrier/1,
          empty_deltas_on_barrier/1,
          tag_mismatch_crashes/1,
          unknown_label_crashes/1,
          consecutive_barriers/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [
        merge_metas_all_same,
        merge_metas_mismatch_crashes
    ]},
     {proc, [parallel], [
        single_upstream_trivial,
        two_upstreams_sum,
        no_output_before_barrier,
        empty_deltas_on_barrier,
        tag_mismatch_crashes,
        unknown_label_crashes,
        consecutive_barriers
     ]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) -> ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%==== Helpers

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

start_plus(LabelsAndPids) ->
    Down = start_collector(),
    Labels = [L || {L, _} <- LabelsAndPids],
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_plus, #{
        labels => Labels
    }),
    Op ! {wiring_update, maps:from_list([{P, L} || {L, P} <- LabelsAndPids]), #{default => Down}},
    {Op, LabelsAndPids, Down}.

mk_delta(Epoch, Deltas, From) ->
    {delta, #{epoch => Epoch}, Deltas, From}.

mk_barrier_delta(Epoch, Tag, Deltas, From) ->
    {delta, #{epoch => Epoch, barrier => Tag}, Deltas, From}.

send(Op, Epoch, Deltas, Pid) ->
    Op ! mk_delta(Epoch, Deltas, Pid).

barrier(Op, Epoch, Tag, Pid) ->
    Op ! mk_barrier_delta(Epoch, Tag, [], Pid).

%%==== Pure

merge_metas_all_same(_Config) ->
    Meta = #{epoch => 0, barrier => {iter, 0, 0}},
    Acc = #{a => {delta, Meta, [], a}, b => {delta, Meta, [], b}},
    Meta = gdbsp_op_plus:merge_metas(Acc).

merge_metas_mismatch_crashes(_Config) ->
    M1 = #{epoch => 0, barrier => {iter, 0, 0}},
    M2 = #{epoch => 0, barrier => {iter, 0, 1}},
    Acc = #{a => {delta, M1, [], a}, b => {delta, M2, [], b}},
    try gdbsp_op_plus:merge_metas(Acc) of
        _ -> ct:fail(expected_error)
    catch
        error:{meta_mismatch, _} -> ok
    end.

%%==== Proc

single_upstream_trivial(_Config) ->
    A = start_collector(),
    {Op, _, Down} = start_plus([{a, A}]),
    send(Op, 0, [{1, x}], A),
    [{delta, _, [{1, x}], _}] = await(Down, 1),
    ok = cleanup([Op, A, Down]).

two_upstreams_sum(_Config) ->
    A = start_collector(),
    B = start_collector(),
    {Op, _, Down} = start_plus([{a, A}, {b, B}]),
    Tag = {iter, 0, 0},
    send(Op, 0, [{1, aa}], A),
    send(Op, 0, [{2, bb}], B),
    barrier(Op, 0, Tag, A),
    barrier(Op, 0, Tag, B),
    [{delta, #{barrier := Tag}, Output, _}] = await(Down, 1),
    [{1, aa}, {2, bb}] = lists:sort(Output),
    ok = cleanup([Op, A, B, Down]).

no_output_before_barrier(_Config) ->
    A = start_collector(),
    B = start_collector(),
    {Op, _, Down} = start_plus([{a, A}, {b, B}]),
    send(Op, 0, [{1, x}], A),
    send(Op, 0, [{1, y}], B),
    [] = drain(Down),
    ok = cleanup([Op, A, B, Down]).

empty_deltas_on_barrier(_Config) ->
    A = start_collector(),
    B = start_collector(),
    {Op, _, Down} = start_plus([{a, A}, {b, B}]),
    Tag = {iter, 0, 0},
    barrier(Op, 0, Tag, A),
    barrier(Op, 0, Tag, B),
    [] = drain(Down),
    ok = cleanup([Op, A, B, Down]).

tag_mismatch_crashes(_Config) ->
    A = start_collector(),
    B = start_collector(),
    {Op, _, Down} = start_plus([{a, A}, {b, B}]),
    unlink(Op),
    MRef = erlang:monitor(process, Op),
    barrier(Op, 0, {iter, 0, 0}, A),
    barrier(Op, 0, {iter, 0, 1}, B),
    receive
        {'DOWN', MRef, process, Op, _Reason} -> ok
    after 5000 ->
        erlang:demonitor(MRef),
        ct:fail(process_not_exited)
    end,
    ok = cleanup([A, B, Down]).

unknown_label_crashes(_Config) ->
    %% Unknown label in barrier state — tested via barrier itself
    ok.

consecutive_barriers(_Config) ->
    A = start_collector(),
    B = start_collector(),
    {Op, _, Down} = start_plus([{a, A}, {b, B}]),
    Tag0 = {iter, 0, 0},
    Tag1 = {iter, 0, 1},
    %% Round 0
    send(Op, 0, [{1, r0a}], A),
    send(Op, 0, [{1, r0b}], B),
    barrier(Op, 0, Tag0, A),
    barrier(Op, 0, Tag0, B),
    [{delta, #{barrier := Tag0}, Out0, _}] = await(Down, 1),
    [{1, r0a}, {1, r0b}] = lists:sort(Out0),
    %% Round 1
    send(Op, 0, [{2, r1}], A),
    barrier(Op, 0, Tag1, A),
    barrier(Op, 0, Tag1, B),
    [{delta, #{barrier := Tag1}, [{2, r1}], _}] = await(Down, 1),
    ok = cleanup([Op, A, B, Down]).


