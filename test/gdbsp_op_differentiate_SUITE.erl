%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_differentiate (barrier-aware diff).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_differentiate_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1,
         second_barrier_empty_when_state_unchanged/1]).

%% Proc
-export([first_epoch_emits_full_state/1,
          second_epoch_emits_diff/1,
          no_change_emits_empty/1,
          no_output_between_barriers/1,
          barrier_tag_preserved/1,
          multiple_deltas_per_epoch/1,
          epoch_transition_clears_buffer/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial,
                        second_barrier_empty_when_state_unchanged]},
     {proc, [parallel], [
        first_epoch_emits_full_state,
        second_epoch_emits_diff,
        no_change_emits_empty,
        no_output_between_barriers,
        barrier_tag_preserved,
        multiple_deltas_per_epoch,
        epoch_transition_clears_buffer
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

start_differentiate() ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_differentiate, #{
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
    #{} = gdbsp_op_differentiate:merge_metas(#{}).

second_barrier_empty_when_state_unchanged(_Config) ->
    {St0, _, _} = gdbsp_op_differentiate:init(#{}),
    {St1, [{send, default, {delta, #{barrier := {iter,0,0}}, [{1,a},{1,b}]}}]} =
        gdbsp_op_differentiate:handle_delta(
            St0, default, {delta, #{barrier => {iter,0,0}}, [{1,a},{1,b}]}),
    {_St2, [{send, default, {delta, #{barrier := {iter,0,1}}, []}}]} =
        gdbsp_op_differentiate:handle_delta(
            St1, default, {delta, #{barrier => {iter,0,1}}, []}),
    ok.

%%==== Proc

first_epoch_emits_full_state(_Config) ->
    {Op, Up, Down} = start_differentiate(),
    Op ! mk_delta(0, [{3, a}, {-1, b}], Up),
    Op ! mk_barrier_delta(0, epoch_done, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{-1, b}, {3, a}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

second_epoch_emits_diff(_Config) ->
    {Op, Up, Down} = start_differentiate(),
    %% First epoch: a=3, b=-1
    Op ! mk_delta(0, [{3, a}, {-1, b}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    %% Second epoch: a += 2 (now 5), b canceled (+1 from -1 → 0)
    Op ! mk_delta(0, [{2, a}, {1, b}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{1, b}, {2, a}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

no_change_emits_empty(_Config) ->
    {Op, Up, Down} = start_differentiate(),
    %% First epoch
    Op ! mk_delta(0, [{5, x}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    %% Second epoch: same 5 on x → no diff, but barrier still forwarded
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, #{barrier := {iter, 0, 1}}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

no_output_between_barriers(_Config) ->
    {Op, Up, Down} = start_differentiate(),
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_delta(0, [{1, b}], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

barrier_tag_preserved(_Config) ->
    {Op, Up, Down} = start_differentiate(),
    Tag = {iter, 5, 3},
    Op ! mk_delta(0, [{1, z}], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [{1, z}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

multiple_deltas_per_epoch(_Config) ->
    {Op, Up, Down} = start_differentiate(),
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_delta(0, [{2, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{3, a}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

epoch_transition_clears_buffer(_Config) ->
    {Op, Up, Down} = start_differentiate(),
    Op ! mk_delta(0, [{1, a}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    Op ! mk_delta(1, [{-1, a}], Up),
    Op ! mk_barrier_delta(1, {iter, 1, 0}, [], Up),
    [{delta, #{epoch := 1}, [{-1, a}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).


