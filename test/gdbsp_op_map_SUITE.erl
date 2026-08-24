%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_map (barrier-aware 1:1 row transform).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_map_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1]).

%% Proc
-export([maps_rows/1,
    expr_init/1,
         head_rename_preserves_refined_dynamic_type/1,
         weight_preserved/1,
         barrier_passthrough/1,
         empty_input_no_output/1,
         empty_barrier_forwarded/1,
         multiple_deltas/1,
         epoch_passthrough/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        maps_rows,
        expr_init,
        head_rename_preserves_refined_dynamic_type,
        weight_preserved,
        barrier_passthrough,
        empty_input_no_output,
        empty_barrier_forwarded,
        multiple_deltas,
        epoch_passthrough
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

start_map(Args) ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_map, Args),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    {Op, Up, Down}.

mk_delta(Epoch, Deltas, From) ->
    {delta, #{epoch => Epoch}, Deltas, From}.

mk_barrier_delta(Epoch, Tag, Deltas, From) ->
    {delta, #{epoch => Epoch, barrier => Tag}, Deltas, From}.

%%==== Pure

merge_metas_trivial(_Config) ->
    #{} = gdbsp_op_map:merge_metas(#{}).

%%==== Proc

maps_rows(_Config) ->
    Args = #{kind => rename, columns => #{<<"x">> => <<"y">>}},
    {Op, Up, Down} = start_map(Args),
    Op ! mk_delta(0, [{1, #{<<"x">> => 5}}], Up),
    [{delta, #{epoch := 0}, [{1, R}], _}] = await(Down, 1),
    5 = maps:get(<<"y">>, R),
    ok = cleanup([Op, Up, Down]).

expr_init(_Config) ->
    CanonicalExpr = {call, <<"+">>, [{call, <<"std.struct_get">>, [{arg, <<"row">>}], #{<<"key">> => {value, string, <<"x">>}}}, {value, i64, 1}], #{}},
    RowType = {struct, #{<<"x">> => i64}, exact},
    TypedRow = gdbsp_value:map_to_struct(#{<<"x">> => 5}, RowType),
    Expected = gdbsp_value:struct_extend(TypedRow, <<"y">>, {value, i64, 6}),
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_map, #{value_mod => gdbsp_value, expr => CanonicalExpr, row_type => RowType, out => <<"y">>, kwarg_order => #{<<"std.struct_get">> => [<<"key">>]}}),
    Op ! {wiring_update, #{Up => default}, #{default => Down}},
    Op ! mk_delta(0, [{1, TypedRow}], Up),
    [{delta, #{epoch := 0}, [{1, Expected}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

%% Regression for the join-derived `:=` bug
%% (gg_compiler/docs/map-expr-after-join-derived-source.md).
%%
%% A join emits its output struct with the declared `merged_fields` type map
%% (all bare `dynamic`) while its VALUES carry a refined runtime tag such as
%% `{dynamic, string}`. head_rename must NOT downgrade a value's own tag to
%% the bare declared field type — doing so makes downstream dynamic-dispatched
%% builtins (concat/comparison) reject the value and silently drop the row.
head_rename_preserves_refined_dynamic_type(_Config) ->
    Args = #{kind => head_rename, columns => #{<<"id">> => #{var => <<"id">>}}},
    {Op, Up, Down} = start_map(Args),
    %% Mimic a join output row: bare-`dynamic` declared field, refined value.
    InRow = {value, {struct, #{<<"id">> => dynamic}, exact},
                    #{<<"id">> => {value, {dynamic, string}, <<"x">>}}},
    Op ! mk_delta(0, [{1, InRow}], Up),
    [{delta, #{epoch := 0}, [{1, OutRow}], _}] = await(Down, 1),
    {value, {struct, _NewFields, _Rest}, NewColVals} = OutRow,
    %% The value's own refined type must survive the rename.
    {value, {dynamic, string}, <<"x">>} = maps:get(<<"id">>, NewColVals),
    ok = cleanup([Op, Up, Down]).

weight_preserved(_Config) ->
    Args = #{kind => rename, columns => #{<<"x">> => <<"y">>}},
    {Op, Up, Down} = start_map(Args),
    Op ! mk_delta(0, [{3, #{<<"x">> => 1}}, {-2, #{<<"x">> => 2}}], Up),
    [{delta, #{epoch := 0}, [{3, R1}, {-2, R2}], _}] = await(Down, 1),
    1 = maps:get(<<"y">>, R1),
    2 = maps:get(<<"y">>, R2),
    ok = cleanup([Op, Up, Down]).

barrier_passthrough(_Config) ->
    Args = #{kind => rename, columns => #{<<"x">> => <<"y">>}},
    {Op, Up, Down} = start_map(Args),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [{1, #{<<"x">> => 10}}], Up),
    Op ! mk_barrier_delta(0, Tag, [{1, #{<<"x">> => 20}}], Up),
    Msgs = await(Down, 2),
    [{delta, Meta1, [{1, R1}], _},
     {delta, #{barrier := Tag}, [{1, R2}], _}] = Msgs,
    false = maps:is_key(barrier, Meta1),
    10 = maps:get(<<"y">>, R1),
    20 = maps:get(<<"y">>, R2),
    ok = cleanup([Op, Up, Down]).

empty_input_no_output(_Config) ->
    Args = #{kind => rename, columns => #{}},
    {Op, Up, Down} = start_map(Args),
    Op ! mk_delta(0, [], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

empty_barrier_forwarded(_Config) ->
    Args = #{kind => rename, columns => #{}},
    {Op, Up, Down} = start_map(Args),
    Tag = {iter, 0, 0},
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

multiple_deltas(_Config) ->
    Args = #{kind => rename, columns => #{<<"x">> => <<"y">>}},
    {Op, Up, Down} = start_map(Args),
    Op ! mk_delta(0, [{1, #{<<"x">> => 3}}], Up),
    Op ! mk_delta(0, [{2, #{<<"x">> => 4}}], Up),
    Msgs = await(Down, 2),
    [{delta, _, [{1, R1}], _}, {delta, _, [{2, R2}], _}] = Msgs,
    3 = maps:get(<<"y">>, R1),
    4 = maps:get(<<"y">>, R2),
    ok = cleanup([Op, Up, Down]).

epoch_passthrough(_Config) ->
    Args = #{kind => rename, columns => #{<<"x">> => <<"y">>}},
    {Op, Up, Down} = start_map(Args),
    Op ! mk_delta(5, [{1, #{<<"x">> => 7}}], Up),
    [{delta, #{epoch := 5}, [{1, R}], _}] = await(Down, 1),
    7 = maps:get(<<"y">>, R),
    ok = cleanup([Op, Up, Down]).
