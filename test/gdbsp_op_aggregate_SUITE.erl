%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_aggregate (barrier-aware per-key fold).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_aggregate_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1]).

%% Proc
-export([key_appears/1,
         key_disappears/1,
         key_changes/1,
         no_output_when_unchanged/1,
         no_output_between_barriers/1,
         barrier_tag_preserved/1,
         multiple_keys/1,
         consecutive_barriers/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        key_appears,
        key_disappears,
        key_changes,
        no_output_when_unchanged,
        no_output_between_barriers,
        barrier_tag_preserved,
        multiple_keys,
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

start_aggregate() ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_aggregate, #{
        init_fn => fun(V, W) -> V * W end,
        update_fn => fun(Acc, V, W) -> Acc + V * W end,
        result_fn => fun(V) -> V end
    }),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    {Op, Up, Down}.

%% IndexedZSet helper: {OuterW, {Key, [{W, V}]}} where V must be numeric for sum agg

mk_idx(Key, Vals) -> {1, {Key, Vals}}.

mk_delta(Epoch, Deltas, From) ->
    {delta, #{epoch => Epoch}, Deltas, From}.

mk_barrier_delta(Epoch, Tag, Deltas, From) ->
    {delta, #{epoch => Epoch, barrier => Tag}, Deltas, From}.

%%==== Pure

merge_metas_trivial(_Config) ->
    #{} = gdbsp_op_aggregate:merge_metas(#{}).

%%==== Proc

key_appears(_Config) ->
    {Op, Up, Down} = start_aggregate(),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [mk_idx(k1, [{3, 2}])], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, Output, _}] = await(Down, 1),
    %% 2 * 3 = 6
    [{1, {k1, 6}}] = Output,
    ok = cleanup([Op, Up, Down]).

key_disappears(_Config) ->
    {Op, Up, Down} = start_aggregate(),
    Op ! mk_delta(0, [mk_idx(k1, [{5, 2}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, _}}], _}] = await(Down, 1),
    Op ! mk_delta(0, [{1, {k1, [{-5, 2}]}}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, [{-1, {k1, _}}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

key_changes(_Config) ->
    {Op, Up, Down} = start_aggregate(),
    Op ! mk_delta(0, [mk_idx(k1, [{2, 3}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    Op ! mk_delta(0, [mk_idx(k1, [{3, 3}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{-1, {k1, _}}, {1, {k1, _}}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

no_output_when_unchanged(_Config) ->
    {Op, Up, Down} = start_aggregate(),
    Op ! mk_delta(0, [mk_idx(k1, [{2, 3}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, #{barrier := {iter, 0, 1}}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

no_output_between_barriers(_Config) ->
    {Op, Up, Down} = start_aggregate(),
    Op ! mk_delta(0, [mk_idx(k1, [{1, 5}])], Up),
    Op ! mk_delta(0, [mk_idx(k2, [{1, 7}])], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

barrier_tag_preserved(_Config) ->
    {Op, Up, Down} = start_aggregate(),
    Tag = {iter, 7, 3},
    Op ! mk_delta(0, [mk_idx(kz, [{1, 10}])], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [{1, {kz, _}}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

multiple_keys(_Config) ->
    {Op, Up, Down} = start_aggregate(),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [mk_idx(k1, [{2, 3}]), mk_idx(k2, [{3, 4}])], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    %% k1: 3*2=6, k2: 4*3=12
    [{1, {k1, 6}}, {1, {k2, 12}}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

consecutive_barriers(_Config) ->
    {Op, Up, Down} = start_aggregate(),
    Op ! mk_delta(0, [mk_idx(k1, [{2, 3}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    Op ! mk_delta(0, [{1, {k1, [{-2, 3}]}}, mk_idx(k2, [{3, 4}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    %% k1: removed, k2: 4*3=12
    [{-1, {k1, _}}, {1, {k2, _}}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).
