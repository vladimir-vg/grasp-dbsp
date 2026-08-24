%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_flat_map (1:N row expansion via array return).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_flat_map_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1]).

%% Proc
-export([single_to_single/1,
         single_to_multi/1,
         single_to_empty/1,
         barrier_passthrough/1,
         weight_preserved/1,
         multiple_deltas/1,
         empty_input_no_output/1,
         empty_barrier_forwarded/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        single_to_single,
        single_to_multi,
        single_to_empty,
        barrier_passthrough,
        weight_preserved,
        multiple_deltas,
        empty_input_no_output,
        empty_barrier_forwarded
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

start_flat_map(Args) ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_flat_map, Args),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    {Op, Up, Down}.

mk_delta(Epoch, Deltas, From) ->
    {delta, #{epoch => Epoch}, Deltas, From}.

mk_barrier_delta(Epoch, Tag, Deltas, From) ->
    {delta, #{epoch => Epoch, barrier => Tag}, Deltas, From}.

-define(ROW_TYPE, {struct, #{<<"v">> => {array, i64, varsize}}, exact}).

mk_arr_row(Vals) when is_list(Vals) ->
    Arr = [{value, i64, V} || V <- Vals],
    TypedArr = {value, {array, i64, varsize}, Arr},
    {value, {struct, #{<<"v">> => {array, i64, varsize}}, exact},
     #{<<"v">> => TypedArr}}.

get_vals(Deltas) ->
    [gdbsp_value:unwrap(R) || {_, R} <- Deltas].

-define(EXPR, {call, <<"std.struct_get">>, [{arg, <<"row">>}], #{<<"key">> => {value, string, <<"v">>}}}).
-define(KWARG_ORDER, #{<<"std.struct_get">> => [<<"key">>]}).
-define(ARGS, #{expr => ?EXPR, row_type => {struct, #{<<"v">> => {array, i64, varsize}}, exact},
                kwarg_order => ?KWARG_ORDER}).

%%==== Pure

merge_metas_trivial(_Config) ->
    #{} = gdbsp_op_flat_map:merge_metas(#{}).

%%==== Proc

single_to_single(_Config) ->
    {Op, Up, Down} = start_flat_map(?ARGS),
    Op ! mk_delta(0, [{1, mk_arr_row([6])}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [6] = get_vals(Deltas),
    ok = cleanup([Op, Up, Down]).

single_to_multi(_Config) ->
    {Op, Up, Down} = start_flat_map(?ARGS),
    Op ! mk_delta(0, [{2, mk_arr_row([3, 13])}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [3, 13] = get_vals(Deltas),
    ok = cleanup([Op, Up, Down]).

single_to_empty(_Config) ->
    {Op, Up, Down} = start_flat_map(?ARGS),
    Op ! mk_delta(0, [{1, mk_arr_row([])}], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

barrier_passthrough(_Config) ->
    {Op, Up, Down} = start_flat_map(?ARGS),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [{1, mk_arr_row([10])}], Up),
    Op ! mk_barrier_delta(0, Tag, [{1, mk_arr_row([14])}], Up),
    Msgs = await(Down, 2),
    [{delta, Meta1, D1, _}, {delta, #{barrier := Tag}, D2, _}] = Msgs,
    false = maps:is_key(barrier, Meta1),
    [10] = get_vals(D1),
    [14] = get_vals(D2),
    ok = cleanup([Op, Up, Down]).

weight_preserved(_Config) ->
    {Op, Up, Down} = start_flat_map(?ARGS),
    Op ! mk_delta(0, [{3, mk_arr_row([1, 1])}, {-1, mk_arr_row([2, 2])}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [{3, 1}, {3, 1}, {-1, 2}, {-1, 2}] = [{W, V} || {W, R} <- Deltas, V <- [gdbsp_value:unwrap(R)]],
    ok = cleanup([Op, Up, Down]).

multiple_deltas(_Config) ->
    {Op, Up, Down} = start_flat_map(?ARGS),
    Op ! mk_delta(0, [{1, mk_arr_row([10])}], Up),
    Op ! mk_delta(0, [{2, mk_arr_row([20])}], Up),
    Msgs = await(Down, 2),
    [{delta, _, D1, _}, {delta, _, D2, _}] = Msgs,
    [10] = get_vals(D1),
    [20] = get_vals(D2),
    ok = cleanup([Op, Up, Down]).

empty_input_no_output(_Config) ->
    {Op, Up, Down} = start_flat_map(?ARGS),
    Op ! mk_delta(0, [], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

empty_barrier_forwarded(_Config) ->
    {Op, Up, Down} = start_flat_map(?ARGS),
    Tag = {iter, 0, 0},
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).
