%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_flat_map (1:N row expansion via unnest).
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
    expr_init_one_var/1,
    expr_init_two_var_index/1,
    expr_init_two_var_dict/1,
    expr_init_json_array_one_var/1,
    expr_init_json_array_two_var_index/1,
    expr_init_json_map_two_var/1,
    expr_init_optional_json_array/1,
    expr_init_json_empty_array/1,
         single_to_multi/1,
         single_to_empty/1,
         barrier_passthrough/1,
         weight_preserved/1,
         empty_barrier_forwarded/1,
         multiple_deltas/1,
         empty_input_no_output/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        single_to_single,
        expr_init_one_var,
        expr_init_two_var_index,
        expr_init_two_var_dict,
        expr_init_json_array_one_var,
        expr_init_json_array_two_var_index,
        expr_init_json_map_two_var,
        expr_init_optional_json_array,
        expr_init_json_empty_array,
        single_to_multi,
        single_to_empty,
        barrier_passthrough,
        weight_preserved,
        empty_barrier_forwarded,
        multiple_deltas,
        empty_input_no_output
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
    TypedRow = {value, {struct, #{<<"v">> => {array, i64, varsize}}, exact}, #{<<"v">> => TypedArr}},
    TypedRow.

get_vals(Deltas) ->
    [gdbsp_value:unwrap(maps:get(<<"v">>, gdbsp_value:struct_to_map(R))) || {_, R} <- Deltas].

-define(EXPR, {field, <<"v">>}).
-define(ARGS, #{expr => {field, <<"v">>}, row_type => {struct, #{<<"v">> => {array, i64, varsize}}, exact}, unnest_outs => [<<"v">>]}).

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

expr_init_one_var(_Config) ->
    CanonicalExpr = {field, <<"arr">>},
    RowType = {struct, #{<<"arr">> => {array, i64, varsize}}, exact},
    TypedArr = {value, {array, i64, varsize}, [10, 20, 30]},
    TypedRow = {value, {struct, #{<<"arr">> => {array, i64, varsize}}, exact}, #{<<"arr">> => TypedArr}},
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_flat_map, #{expr => CanonicalExpr, row_type => RowType, unnest_outs => [<<"v">>]}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [10, 20, 30] = [maps:get(<<"v">>, gdbsp_value:struct_to_map(R)) || {_, R} <- Deltas],
    ok = cleanup([Op, Up, Down]).

expr_init_two_var_index(_Config) ->
    CanonicalExpr = {field, <<"arr">>},
    RowType = {struct, #{<<"arr">> => {array, i64, varsize}}, exact},
    TypedArr = {value, {array, i64, varsize}, [10, 20, 30]},
    TypedRow = {value, {struct, #{<<"arr">> => {array, i64, varsize}}, exact}, #{<<"arr">> => TypedArr}},
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_flat_map, #{expr => CanonicalExpr, row_type => RowType, unnest_outs => [<<"i">>, <<"v">>]}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [{0, 10}, {1, 20}, {2, 30}] = [{maps:get(<<"i">>, gdbsp_value:struct_to_map(R)),
                                      maps:get(<<"v">>, gdbsp_value:struct_to_map(R))} || {_, R} <- Deltas],
    ok = cleanup([Op, Up, Down]).

expr_init_two_var_dict(_Config) ->
    CanonicalExpr = {field, <<"dict">>},
    RowType = {struct, #{<<"dict">> => {map, string, i64}}, exact},
    TypedDict = {value, {map, string, i64}, #{
        <<"a">> => {value, i64, 1},
        <<"b">> => {value, i64, 2}
    }},
    TypedRow = {value, {struct, #{<<"dict">> => {map, string, i64}}, exact}, #{<<"dict">> => TypedDict}},
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_flat_map, #{expr => CanonicalExpr, row_type => RowType, unnest_outs => [<<"k">>, <<"v">>]}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [{<<"a">>, 1}, {<<"b">>, 2}] = lists:sort([{maps:get(<<"k">>, gdbsp_value:struct_to_map(R)),
                                                    maps:get(<<"v">>, gdbsp_value:struct_to_map(R))} || {_, R} <- Deltas]),
    ok = cleanup([Op, Up, Down]).

expr_init_json_array_one_var(_Config) ->
    Expr = {field, <<"arr">>},
    RowType = {struct, #{<<"arr">> => json}, exact},
    ArrVal = gdbsp_value_json:jsx_to_json_node([10.0, 20.0]),
    TypedRow = {value, {struct, #{<<"arr">> => json}, exact},
                #{<<"arr">> => ArrVal}},
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_flat_map,
        #{expr => Expr, row_type => RowType, unnest_outs => [<<"v">>]}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [10.0, 20.0] = [gdbsp_value:unwrap(maps:get(<<"v">>, gdbsp_value:struct_to_map(R))) || {_, R} <- Deltas],
    ok = cleanup([Op, Up, Down]).

expr_init_json_array_two_var_index(_Config) ->
    Expr = {field, <<"arr">>},
    RowType = {struct, #{<<"arr">> => json}, exact},
    ArrVal = gdbsp_value_json:jsx_to_json_node([<<"a">>, <<"b">>]),
    TypedRow = {value, {struct, #{<<"arr">> => json}, exact},
                #{<<"arr">> => ArrVal}},
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_flat_map,
        #{expr => Expr, row_type => RowType, unnest_outs => [<<"i">>, <<"v">>]}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [{0, <<"a">>}, {1, <<"b">>}] = [{maps:get(<<"i">>, gdbsp_value:struct_to_map(R)),
                                      gdbsp_value:unwrap(maps:get(<<"v">>, gdbsp_value:struct_to_map(R)))}
                                     || {_, R} <- Deltas],
    ok = cleanup([Op, Up, Down]).

expr_init_json_map_two_var(_Config) ->
    Expr = {field, <<"dict">>},
    RowType = {struct, #{<<"dict">> => json}, exact},
    MapVal = gdbsp_value_json:jsx_to_json_node(#{<<"x">> => 1.0, <<"y">> => 2.0}),
    TypedRow = {value, {struct, #{<<"dict">> => json}, exact},
                #{<<"dict">> => MapVal}},
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_flat_map,
        #{expr => Expr, row_type => RowType, unnest_outs => [<<"k">>, <<"v">>]}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [{<<"x">>, 1.0}, {<<"y">>, 2.0}] = lists:sort([{maps:get(<<"k">>, gdbsp_value:struct_to_map(R)),
                                                  gdbsp_value:unwrap(maps:get(<<"v">>, gdbsp_value:struct_to_map(R)))}
                                                 || {_, R} <- Deltas]),
    ok = cleanup([Op, Up, Down]).

expr_init_optional_json_array(_Config) ->
    Expr = {field, <<"arr">>},
    RowType = {struct, #{<<"arr">> => {optional, json}}, exact},
    ArrVal = gdbsp_value_json:jsx_to_json_node([10.0]),
    TypedRow = {value, {struct, #{<<"arr">> => {optional, json}}, exact},
                #{<<"arr">> => {value, {optional, json}, {value, ArrVal}}}},
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_flat_map,
        #{expr => Expr, row_type => RowType, unnest_outs => [<<"v">>]}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow}], Up),
    [{delta, _, Deltas, _}] = await(Down, 1),
    [10.0] = [gdbsp_value:unwrap(maps:get(<<"v">>, gdbsp_value:struct_to_map(R))) || {_, R} <- Deltas],
    ok = cleanup([Op, Up, Down]).

expr_init_json_empty_array(_Config) ->
    Expr = {field, <<"arr">>},
    RowType = {struct, #{<<"arr">> => json}, exact},
    TypedRow = {value, {struct, #{<<"arr">> => json}, exact},
                #{<<"arr">> => {value, {json, {array, json, varsize}}, []}}},
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_flat_map,
        #{expr => Expr, row_type => RowType, unnest_outs => [<<"v">>]}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow}], Up),
    [] = drain(Down),
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
    [{3, 1}, {3, 1}, {-1, 2}, {-1, 2}] = [{W, V} || {W, R} <- Deltas, V <- [gdbsp_value:unwrap(maps:get(<<"v">>, gdbsp_value:struct_to_map(R)))]],
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
