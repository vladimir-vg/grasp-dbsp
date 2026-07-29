%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_delay (barrier-aware z⁻¹ delay).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_delay_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1]).

%% Proc
-export([first_barrier_emits_empty/1,
          second_barrier_emits_previous/1,
          no_output_between_barriers/1,
          barrier_tag_preserved/1,
          multiple_deltas_per_epoch/1,
          two_delays_in_series_z2/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        first_barrier_emits_empty,
        second_barrier_emits_previous,
        no_output_between_barriers,
        barrier_tag_preserved,
        multiple_deltas_per_epoch,
        two_delays_in_series_z2
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

start_delay() ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_delay, #{
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
    #{} = gdbsp_op_delay:merge_metas(#{}).

%%==== Proc

first_barrier_emits_empty(_Config) ->
    {Op, Up, Down} = start_delay(),
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, #{barrier := {iter, 0, 0}}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

second_barrier_emits_previous(_Config) ->
    {Op, Up, Down} = start_delay(),
    %% First epoch: send a=1, b=2
    Op ! mk_delta(0, [{1, a}, {1, b}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [], _}] = await(Down, 1),
    %% Second epoch: no new data; should emit a=1, b=2
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, #{barrier := {iter, 0, 1}}, Output, _}] = await(Down, 1),
    [{1, a}, {1, b}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

no_output_between_barriers(_Config) ->
    {Op, Up, Down} = start_delay(),
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_delta(0, [{1, b}], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

barrier_tag_preserved(_Config) ->
    {Op, Up, Down} = start_delay(),
    %% Pre-seed with one epoch so prev_deltas is non-empty
    Op ! mk_delta(0, [{1, x}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    Tag = {iter, 5, 3},
    Op ! mk_delta(0, [{1, y}], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [{1, x}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

multiple_deltas_per_epoch(_Config) ->
    {Op, Up, Down} = start_delay(),
    %% Pre-seed first epoch
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    %% Multiple deltas, then second barrier: should emit all of them together
    Op ! mk_delta(0, [{1, b}], Up),
    Op ! mk_delta(0, [{1, c}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    %% Emits first epoch's data: {1,a}
    [{delta, _, [{1, a}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

two_delays_in_series_z2(_Config) ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, D2} = gdbsp_op_proc:start_link(gdbsp_op_delay, #{downstream => Down}),
    {ok, D1} = gdbsp_op_proc:start_link(gdbsp_op_delay, #{downstream => D2}),
    D2 ! {wiring_update, #{D1 => default}, #{default => Down}},
    D1 ! {wiring_update, #{Up => default}, #{default => D2}},
    %% Epoch 0: send a=1 to D1 → D1 emits empty, D2 emits empty (z⁻²)
    D1 ! mk_delta(0, [{1, a}], Up),
    D1 ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, #{barrier := {iter, 0, 0}}, [], _}] = await(Down, 1),
    %% Epoch 1: no new data → D1 emits {1,a}, D2 emits empty (still shifted)
    D1 ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, #{barrier := {iter, 0, 1}}, [], _}] = await(Down, 1),
    %% Epoch 2: no new data → D1 emits empty, D2 emits {1,a} (2-step delay)
    D1 ! mk_barrier_delta(0, {iter, 0, 2}, [], Up),
    [{delta, #{barrier := {iter, 0, 2}}, [{1, a}], _}] = await(Down, 1),
    %% Epoch 3: no new data → both emit empty
    D1 ! mk_barrier_delta(0, {iter, 0, 3}, [], Up),
    [{delta, #{barrier := {iter, 0, 3}}, [], _}] = await(Down, 1),
    ok = cleanup([D1, D2, Up, Down]).
