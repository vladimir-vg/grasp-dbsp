%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_neg (weight-sign flip).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_neg_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1]).

%% Proc
-export([flips_positive/1,
         flips_negative/1,
         flips_zero/1,
         barrier_passthrough/1,
         empty_input_no_output/1,
         empty_barrier_forwarded/1,
         multiple_deltas/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        flips_positive,
        flips_negative,
        flips_zero,
        barrier_passthrough,
        empty_input_no_output,
        empty_barrier_forwarded,
        multiple_deltas
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

start_neg() ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_neg, #{
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
    #{} = gdbsp_op_neg:merge_metas(#{}).

%%==== Proc

flips_positive(_Config) ->
    {Op, Up, Down} = start_neg(),
    Op ! mk_delta(0, [{3, a}], Up),
    [{delta, _, [{-3, a}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

flips_negative(_Config) ->
    {Op, Up, Down} = start_neg(),
    Op ! mk_delta(0, [{-2, b}], Up),
    [{delta, _, [{2, b}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

flips_zero(_Config) ->
    {Op, Up, Down} = start_neg(),
    Op ! mk_delta(0, [{0, c}], Up),
    [{delta, _, [{0, c}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

barrier_passthrough(_Config) ->
    {Op, Up, Down} = start_neg(),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [{1, x}], Up),
    Op ! mk_barrier_delta(0, Tag, [{2, y}], Up),
    Msgs = await(Down, 2),
    [{delta, Meta1, [{-1, x}], _}, {delta, #{barrier := Tag}, [{-2, y}], _}] = Msgs,
    false = maps:is_key(barrier, Meta1),
    ok = cleanup([Op, Up, Down]).

empty_input_no_output(_Config) ->
    {Op, Up, Down} = start_neg(),
    Op ! mk_delta(0, [], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

empty_barrier_forwarded(_Config) ->
    {Op, Up, Down} = start_neg(),
    Tag = {iter, 0, 0},
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

multiple_deltas(_Config) ->
    {Op, Up, Down} = start_neg(),
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_delta(0, [{-3, b}], Up),
    Msgs = await(Down, 2),
    [{delta, _, [{-1, a}], _}, {delta, _, [{3, b}], _}] = Msgs,
    ok = cleanup([Op, Up, Down]).
