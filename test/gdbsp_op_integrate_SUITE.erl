%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_integrate (barrier-aware integrator).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_integrate_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1]).

%% Proc
-export([no_output_between_barriers/1,
          barriered_deltas_emitted/1,
          empty_barrier_forwards_tag/1,
          internal_state_preserved/1,
          barrier_tag_preserved/1,
          multiple_barriers/1,
           deltas_with_zero_weight_removed/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        no_output_between_barriers,
        barriered_deltas_emitted,
        empty_barrier_forwards_tag,
        internal_state_preserved,
        barrier_tag_preserved,
        multiple_barriers,
        deltas_with_zero_weight_removed
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

start_integrate() ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_integrate, #{
        downstream => Down
    }),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    {Op, Up, Down}.

mk_delta(Epoch, Deltas, From) ->
    {delta, #{epoch => Epoch}, Deltas, From}.

mk_barrier_delta(Epoch, Tag, Deltas, From) ->
    {delta, #{epoch => Epoch, barrier => Tag}, Deltas, From}.

%%==== Pure

merge_metas_trivial(_Config) ->
    #{} = gdbsp_op_integrate:merge_metas(#{}).

%%==== Proc

no_output_between_barriers(_Config) ->
    {Op, Up, Down} = start_integrate(),
    Op ! mk_delta(0, [{1, a}, {2, b}], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

barriered_deltas_emitted(_Config) ->
    {Op, Up, Down} = start_integrate(),
    Op ! mk_delta(0, [{3, a}], Up),
    Op ! mk_delta(0, [{-1, b}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{-1, b}, {3, a}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

empty_barrier_forwards_tag(_Config) ->
    {Op, Up, Down} = start_integrate(),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, #{barrier := {iter, 0, 0}}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

internal_state_preserved(_Config) ->
    {Op, Up, Down} = start_integrate(),
    %% First window: adds a=3 to internal state
    Op ! mk_delta(0, [{3, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    %% Second window: adds a=-2 → internal state should be a=1
    Op ! mk_delta(0, [{-2, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, [{-2, a}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

barrier_tag_preserved(_Config) ->
    {Op, Up, Down} = start_integrate(),
    Tag = {iter, 3, 7},
    Op ! mk_delta(0, [{1, x}], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [{1, x}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

multiple_barriers(_Config) ->
    {Op, Up, Down} = start_integrate(),
    Tag0 = {iter, 0, 0},
    Tag1 = {iter, 0, 1},
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_barrier_delta(0, Tag0, [], Up),
    Op ! mk_delta(0, [{2, b}], Up),
    Op ! mk_barrier_delta(0, Tag1, [], Up),
    Msgs = await(Down, 2),
    [{delta, #{barrier := Tag0}, [{1, a}], _},
     {delta, #{barrier := Tag1}, [{2, b}], _}] = Msgs,
    ok = cleanup([Op, Up, Down]).

deltas_with_zero_weight_removed(_Config) ->
    {Op, Up, Down} = start_integrate(),
    Op ! mk_delta(0, [{1, a}, {-1, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{-1, a}, {1, a}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).


