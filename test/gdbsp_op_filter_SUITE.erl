%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_filter (barrier-aware predicate filter).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_filter_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1]).

%% Proc
-export([keeps_matching/1,
    expr_init/1,
         drops_nonmatching/1,
         all_pass/1,
         all_drop/1,
         barrier_passthrough/1,
         empty_input_no_output/1,
         empty_barrier_forwarded/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        keeps_matching,
        expr_init,
        drops_nonmatching,
        all_pass,
        all_drop,
        barrier_passthrough,
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

start_filter(Args) ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_filter, Args),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    {Op, Up, Down}.

mk_delta(Epoch, Deltas, From) ->
    {delta, #{epoch => Epoch}, Deltas, From}.

mk_barrier_delta(Epoch, Tag, Deltas, From) ->
    {delta, #{epoch => Epoch, barrier => Tag}, Deltas, From}.

-define(STR_ROW_TYPE, {struct, #{<<"x">> => string}, exact}).

eq_field(Col, Val) ->
    {call, <<"eq">>, [{field, Col}, {value, string, Val}], #{}}.

always_true() -> {value, {enum, [<<"false">>, <<"true">>]}, true}.
always_false() -> {value, {enum, [<<"false">>, <<"true">>]}, false}.

mk_str_row(Val) ->
    gdbsp_value:map_to_struct(#{<<"x">> => Val}, ?STR_ROW_TYPE).

%%==== Pure

merge_metas_trivial(_Config) ->
    #{} = gdbsp_op_filter:merge_metas(#{}).

%%==== Proc

keeps_matching(_Config) ->
    {Op, Up, Down} = start_filter(#{expr => eq_field(<<"x">>, <<"a">>), row_type => ?STR_ROW_TYPE}),
    Op ! mk_delta(0, [{1, mk_str_row(<<"a">>)}], Up),
    [{delta, _, [{1, _}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

expr_init(_Config) ->
    CanonicalExpr = {call, <<"gt">>, [{field, <<"x">>}, {value, i64, 5}], #{}},
    RowType = {struct, #{<<"x">> => i64}, exact},
    TypedRow10 = gdbsp_value:map_to_struct(#{<<"x">> => 10}, RowType),
    TypedRow3 = gdbsp_value:map_to_struct(#{<<"x">> => 3}, RowType),
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_filter, #{value_mod => gdbsp_value, expr => CanonicalExpr, row_type => RowType}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow10}, {-1, TypedRow3}], Up),
    [{delta, #{epoch := 0}, [{1, TypedRow10}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

drops_nonmatching(_Config) ->
    {Op, Up, Down} = start_filter(#{expr => eq_field(<<"x">>, <<"a">>), row_type => ?STR_ROW_TYPE}),
    Op ! mk_delta(0, [{1, mk_str_row(<<"b">>)}], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

all_pass(_Config) ->
    {Op, Up, Down} = start_filter(#{expr => always_true(), row_type => ?STR_ROW_TYPE}),
    Op ! mk_delta(0, [{1, mk_str_row(<<"x">>)}, {2, mk_str_row(<<"y">>)}], Up),
    [{delta, _, [{1, _}, {2, _}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

all_drop(_Config) ->
    {Op, Up, Down} = start_filter(#{expr => always_false(), row_type => ?STR_ROW_TYPE}),
    Op ! mk_delta(0, [{1, mk_str_row(<<"x">>)}], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

barrier_passthrough(_Config) ->
    {Op, Up, Down} = start_filter(#{expr => always_true(), row_type => ?STR_ROW_TYPE}),
    Tag = {iter, 0, 0},
    RowA = mk_str_row(<<"a">>),
    RowB = mk_str_row(<<"b">>),
    RowC = mk_str_row(<<"c">>),
    Op ! mk_delta(0, [{1, RowA}], Up),
    Op ! mk_barrier_delta(0, Tag, [{1, RowB}], Up),
    Op ! mk_barrier_delta(0, Tag, [{1, RowC}], Up),
    Msgs = await(Down, 2),
    [{delta, Meta1, [{1, _}], _}, {delta, #{barrier := Tag}, [{1, _}], _}] = Msgs,
    false = maps:is_key(barrier, Meta1),
    ok = cleanup([Op, Up, Down]).

empty_input_no_output(_Config) ->
    {Op, Up, Down} = start_filter(#{expr => always_true(), row_type => ?STR_ROW_TYPE}),
    Op ! mk_delta(0, [], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

empty_barrier_forwarded(_Config) ->
    {Op, Up, Down} = start_filter(#{expr => always_false(), row_type => ?STR_ROW_TYPE}),
    Tag = {iter, 0, 0},
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).
