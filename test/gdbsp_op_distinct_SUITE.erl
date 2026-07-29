%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_distinct (barrier-aware dedup).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_distinct_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1]).

%% Proc
-export([row_appears/1,
          row_disappears/1,
          no_change_no_output/1,
          appear_and_disappear_in_same_window/1,
          no_output_between_barriers/1,
          barrier_tag_preserved/1,
           output_weight_always_one/1,
           consecutive_barriers/1,
           state_persists_across_epochs/1,
            state_persists_across_epochs/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        row_appears,
        row_disappears,
        no_change_no_output,
        appear_and_disappear_in_same_window,
        no_output_between_barriers,
        barrier_tag_preserved,
        output_weight_always_one,
        consecutive_barriers,
        state_persists_across_epochs
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

start_distinct() ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_distinct, #{
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
    #{} = gdbsp_op_distinct:merge_metas(#{}).

%%==== Proc

row_appears(_Config) ->
    {Op, Up, Down} = start_distinct(),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [{3, a}], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [{1, a}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

row_disappears(_Config) ->
    {Op, Up, Down} = start_distinct(),
    %% First: a appears
    Op ! mk_delta(0, [{2, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    %% Second: a disappears — emits retraction
    Op ! mk_delta(0, [{-2, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, [{-1, a}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

no_change_no_output(_Config) ->
    {Op, Up, Down} = start_distinct(),
    %% a appears
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    %% a stays present — no distinct delta, but barrier still forwarded
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, #{barrier := {iter, 0, 1}}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

appear_and_disappear_in_same_window(_Config) ->
    {Op, Up, Down} = start_distinct(),
    Tag = {iter, 0, 0},
    %% +5 -2 → net +3, row appears (from 0 to 3)
    Op ! mk_delta(0, [{5, a}, {-2, a}], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, _, [{1, a}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

no_output_between_barriers(_Config) ->
    {Op, Up, Down} = start_distinct(),
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_delta(0, [{2, b}], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

barrier_tag_preserved(_Config) ->
    {Op, Up, Down} = start_distinct(),
    Tag = {iter, 3, 1},
    Op ! mk_delta(0, [{1, z}], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [{1, z}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

output_weight_always_one(_Config) ->
    {Op, Up, Down} = start_distinct(),
    Op ! mk_delta(0, [{7, a}, {-1, b}, {-2, c}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    %% a: 7 > 0 → appears (+1), b: -1 < 0 → appears? No, -1 stays absent, c disappears
    %% Actually: a from 0→7: appears (+1). b from 0→-1: absent (negative). c from 0→-2: absent.
    %% Only a appears. Output should be [{1, a}].
    [{1, a}] = Output,
    ok = cleanup([Op, Up, Down]).

consecutive_barriers(_Config) ->
    {Op, Up, Down} = start_distinct(),
    Tag0 = {iter, 0, 0},
    Tag1 = {iter, 0, 1},
    %% Round 0: a appears
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_barrier_delta(0, Tag0, [], Up),
    [{delta, _, [{1, a}], _}] = await(Down, 1),
    %% Round 1: a disappears (-1), b appears (+1)
    Op ! mk_delta(0, [{-1, a}, {1, b}], Up),
    Op ! mk_barrier_delta(0, Tag1, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{-1, a}, {1, b}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

state_persists_across_epochs(_Config) ->
    {Op, Up, Down} = start_distinct(),
    %% Epoch 0: a and b appear
    Op ! mk_delta(0, [{1, a}, {1, b}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    Got0 = await(Down, 1),
    [{delta, #{barrier := {iter, 0, 0}}, GotRows, _}] = Got0,
    [{1, a}, {1, b}] = lists:sort(GotRows),
    %% Epoch 0 done — state should persist
    Op ! mk_barrier_delta(0, epoch_done, [], Up),
    [{delta, #{barrier := epoch_done}, [], _}] = await(Down, 1),
    %% Epoch 1: retract a — emits retraction
    Op ! mk_delta(1, [{-1, a}], Up),
    Op ! mk_barrier_delta(1, {iter, 1, 0}, [], Up),
    [{delta, #{barrier := {iter, 1, 0}}, [{-1, a}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).


