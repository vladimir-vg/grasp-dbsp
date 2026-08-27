%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_aggregate (barrier-aware per-key fold over
%%% a compiled aggregate plan).
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
         consecutive_barriers/1,
         max_retraction/1,
         min_retraction/1,
         duplicate_value_unchanged/1,
         numeric_sum/1,
         numeric_min/1,
         numeric_max/1,
         xor_distinct/1,
         xor_duplicate_cancels/1,
         xor_retraction/1]).

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
        consecutive_barriers,
         max_retraction,
         min_retraction,
         duplicate_value_unchanged,
         numeric_sum,
         numeric_min,
         numeric_max,
         xor_distinct,
         xor_duplicate_cancels,
         xor_retraction
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

%% Struct row with a single numeric field "v".
mk_row(V) ->
    {value, {struct, #{<<"v">> => i64}, exact}, #{<<"v">> => {value, i64, V}}}.

mk_num_row(V) ->
    {value, {struct, #{<<"v">> => numeric}, exact}, #{<<"v">> => {value, numeric, V}}}.

mk_bytes_row(B) ->
    {value, {struct, #{<<"v">> => bytes}, exact}, #{<<"v">> => {value, bytes, B}}}.

%% Build a minimal single-slot plan whose slot folds the row's "v" field and
%% whose result expression wraps the slot result in struct("total").
agg_plan({M, IF, UF, RF}) -> agg_plan_typed({M, IF, UF, RF}, i64).

agg_plan_typed({M, IF, UF, RF}, SlotType) ->
    {ok, StdlibMap} = gdbsp_builtins:load_stdlib(),
    KwargOrder = gdbsp_builtins:build_kwarg_order(StdlibMap),
    ArgExpr = {call, <<"std.struct_get">>, [{arg, <<"row">>}],
               #{<<"key">> => {value, {string, <<"UTF-8">>}, <<"v">>}}},
    #{slots => [#{name => <<"std.agg_test">>,
                  impl => {{M, IF, 2}, {M, UF, 3}, {M, RF, 1}},
                  arg => ArgExpr,
                  result_type => SlotType}],
      result_expr => {call, <<"struct">>, [],
                      #{<<"total">> => {value, SlotType, {slot, 0}}}},
      result_type => {struct, #{<<"total">> => SlotType}, exact},
      row_arg => <<"row">>,
      kwarg_order => KwargOrder}.

sum_plan() -> agg_plan({gdbsp_agg, agg_op_sum_init, agg_op_sum_update, agg_op_sum_result}).
min_plan() -> agg_plan({gdbsp_agg, agg_op_min_init, agg_op_min_update, agg_op_min_result}).
max_plan() -> agg_plan({gdbsp_agg, agg_op_max_init, agg_op_max_update, agg_op_max_result}).
numeric_sum_plan() -> agg_plan_typed({gdbsp_agg, agg_op_sum_numeric_init, agg_op_sum_numeric_update, agg_op_sum_numeric_result}, numeric).
numeric_min_plan() -> agg_plan_typed({gdbsp_agg, agg_op_min_numeric_init, agg_op_min_numeric_update, agg_op_min_numeric_result}, numeric).
numeric_max_plan() -> agg_plan_typed({gdbsp_agg, agg_op_max_numeric_init, agg_op_max_numeric_update, agg_op_max_numeric_result}, numeric).
xor_plan() -> agg_plan_typed({gdbsp_agg, agg_op_xor_init, agg_op_xor_update, agg_op_xor_result}, bytes).

start_aggregate(Plan) ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_aggregate, Plan),
    Op ! {wiring_update, #{Up => [default]}, #{default => Down}},
    {Op, Up, Down}.

%% IndexedZSet helper: {OuterW, {Key, [{W, Row}]}}
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
    {Op, Up, Down} = start_aggregate(sum_plan()),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [mk_idx(k1, [{3, mk_row(2)}])], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, Output, _}] = await(Down, 1),
    %% 2 * 3 = 6
    [{1, {k1, #{<<"total">> := 6}}}] = Output,
    ok = cleanup([Op, Up, Down]).

key_disappears(_Config) ->
    {Op, Up, Down} = start_aggregate(sum_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{5, mk_row(2)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, _}}], _}] = await(Down, 1),
    Op ! mk_delta(0, [{1, {k1, [{-5, mk_row(2)}]}}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, [{-1, {k1, _}}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

key_changes(_Config) ->
    {Op, Up, Down} = start_aggregate(sum_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{2, mk_row(3)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    Op ! mk_delta(0, [mk_idx(k1, [{3, mk_row(3)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{-1, {k1, _}}, {1, {k1, _}}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

no_output_when_unchanged(_Config) ->
    {Op, Up, Down} = start_aggregate(sum_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{2, mk_row(3)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, #{barrier := {iter, 0, 1}}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

no_output_between_barriers(_Config) ->
    {Op, Up, Down} = start_aggregate(sum_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_row(5)}])], Up),
    Op ! mk_delta(0, [mk_idx(k2, [{1, mk_row(7)}])], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

barrier_tag_preserved(_Config) ->
    {Op, Up, Down} = start_aggregate(sum_plan()),
    Tag = {iter, 7, 3},
    Op ! mk_delta(0, [mk_idx(kz, [{1, mk_row(10)}])], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, [{1, {kz, _}}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

multiple_keys(_Config) ->
    {Op, Up, Down} = start_aggregate(sum_plan()),
    Tag = {iter, 0, 0},
    Op ! mk_delta(0, [mk_idx(k1, [{2, mk_row(3)}]), mk_idx(k2, [{3, mk_row(4)}])], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    %% k1: 3*2=6, k2: 4*3=12
    [{1, {k1, #{<<"total">> := 6}}}, {1, {k2, #{<<"total">> := 12}}}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

consecutive_barriers(_Config) ->
    {Op, Up, Down} = start_aggregate(sum_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{2, mk_row(3)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    Op ! mk_delta(0, [{1, {k1, [{-2, mk_row(3)}]}}, mk_idx(k2, [{3, mk_row(4)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    %% k1: removed, k2: 4*3=12
    [{-1, {k1, _}}, {1, {k2, _}}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

max_retraction(_Config) ->
    {Op, Up, Down} = start_aggregate(max_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_row(10)}]), mk_idx(k1, [{1, mk_row(20)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, #{<<"total">> := 20}}}], _}] = await(Down, 1),
    Op ! mk_delta(0, [{1, {k1, [{-1, mk_row(20)}]}}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{-1, {k1, _}}, {1, {k1, #{<<"total">> := 10}}}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

min_retraction(_Config) ->
    {Op, Up, Down} = start_aggregate(min_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_row(10)}]), mk_idx(k1, [{1, mk_row(20)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, #{<<"total">> := 10}}}], _}] = await(Down, 1),
    Op ! mk_delta(0, [{1, {k1, [{-1, mk_row(10)}]}}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{-1, {k1, _}}, {1, {k1, #{<<"total">> := 20}}}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).

duplicate_value_unchanged(_Config) ->
    {Op, Up, Down} = start_aggregate(max_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_row(30)}]), mk_idx(k1, [{1, mk_row(30)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, #{<<"total">> := 30}}}], _}] = await(Down, 1),
    %% Retract one of the two identical rows: max is still present, no change.
    Op ! mk_delta(0, [{1, {k1, [{-1, mk_row(30)}]}}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, #{barrier := {iter, 0, 1}}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

numeric_sum(_Config) ->
    {Op, Up, Down} = start_aggregate(numeric_sum_plan()),
    %% 10.5 + 20.25 = 30.75 = {3075, -2}
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_num_row({105, -1})}]),
                                  mk_idx(k1, [{1, mk_num_row({2025, -2})}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, #{<<"total">> := {3075, -2}}}}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

numeric_min(_Config) ->
    {Op, Up, Down} = start_aggregate(numeric_min_plan()),
    %% 2.0 vs 1.5: min is 1.5 = {15, -1} (cross-scale comparison)
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_num_row({2, 0})}]),
                                  mk_idx(k1, [{1, mk_num_row({15, -1})}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, #{<<"total">> := {15, -1}}}}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

numeric_max(_Config) ->
    {Op, Up, Down} = start_aggregate(numeric_max_plan()),
    %% 2.0 vs 1.5: max is 2.0 = {2, 0}
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_num_row({2, 0})}]),
                                  mk_idx(k1, [{1, mk_num_row({15, -1})}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, #{<<"total">> := {2, 0}}}}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

xor_distinct(_Config) ->
    {Op, Up, Down} = start_aggregate(xor_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_bytes_row(<<16#0F>>)}]),
                      mk_idx(k1, [{1, mk_bytes_row(<<16#F0>>)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, #{<<"total">> := <<16#FF>>}}}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

xor_duplicate_cancels(_Config) ->
    {Op, Up, Down} = start_aggregate(xor_plan()),
    %% Two identical rows → single seen entry with weight 2 → even → cancels to <<>>
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_bytes_row(<<16#0F>>)}]),
                      mk_idx(k1, [{1, mk_bytes_row(<<16#0F>>)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, #{<<"total">> := <<>>}}}], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

xor_retraction(_Config) ->
    {Op, Up, Down} = start_aggregate(xor_plan()),
    Op ! mk_delta(0, [mk_idx(k1, [{1, mk_bytes_row(<<16#0F>>)}]),
                      mk_idx(k1, [{1, mk_bytes_row(<<16#F0>>)}])], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, [{1, {k1, #{<<"total">> := <<16#FF>>}}}], _}] = await(Down, 1),
    Op ! mk_delta(0, [{1, {k1, [{-1, mk_bytes_row(<<16#F0>>)}]}}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [{-1, {k1, #{<<"total">> := <<16#FF>>}}},
     {1, {k1, #{<<"total">> := <<16#0F>>}}}] = lists:sort(Output),
    ok = cleanup([Op, Up, Down]).
