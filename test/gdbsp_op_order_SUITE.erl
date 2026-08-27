%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_order (barrier-aware ORDER BY with rank and
%%% row_number columns, occurrence expansion).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_order_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

%% Pure
-export([merge_metas_trivial/1]).

%% Proc
-export([asc_order/1,
         desc_order/1,
         multi_key/1,
         ties_share_rank/1,
         retraction_cascades/1,
         no_output_between_barriers/1,
         barrier_tag_preserved/1,
          state_reset/1,
          multiplicity_expansion/1,
          numeric_key/1,
          emission_in_row_number_order/1]).

all() ->
    [{group, pure}, {group, proc}].

groups() ->
    [{pure, [parallel], [merge_metas_trivial]},
     {proc, [parallel], [
        asc_order,
        desc_order,
        multi_key,
        ties_share_rank,
        retraction_cascades,
        no_output_between_barriers,
        barrier_tag_preserved,
         state_reset,
         multiplicity_expansion,
         numeric_key,
         emission_in_row_number_order
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

%% Build a struct row from a list of {Field, Type, Value}.
mk_row(FieldList) ->
    Fields = maps:from_list([{F, T} || {F, T, _} <- FieldList]),
    TypedVals = maps:from_list([{F, {value, T, V}} || {F, T, V} <- FieldList]),
    {value, {struct, Fields, exact}, TypedVals}.

mk_num_row(V) ->
    mk_row([{<<"v">>, numeric, V}]).

order_spec(By) ->
    #{by => By,
      rank_col => <<"rank">>,
      row_number_col => <<"row_number">>}.

start_order(Spec) ->
    Up = start_collector(),
    Down = start_collector(),
    {ok, Op} = gdbsp_op_proc:start_link(gdbsp_op_order, Spec),
    Op ! {wiring_update, #{Up => [default]}, #{default => Down}},
    {Op, Up, Down}.

mk_delta(Epoch, Deltas, From) ->
    {delta, #{epoch => Epoch}, Deltas, From}.

mk_barrier_delta(Epoch, Tag, Deltas, From) ->
    {delta, #{epoch => Epoch, barrier => Tag}, Deltas, From}.

%% Extract the current (weight > 0) output rows as plain maps of raw values.
out_maps(Output) ->
    [gdbsp_value:struct_to_map(Row) || {W, Row} <- Output, W > 0].

%%==== Pure

merge_metas_trivial(_Config) ->
    #{} = gdbsp_op_order:merge_metas(#{}).

%%==== Proc

asc_order(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"v">>, <<"asc">>]])),
    Op ! mk_delta(0, [{1, mk_row([{<<"v">>, i64, 3}])},
                      {1, mk_row([{<<"v">>, i64, 1}])},
                      {1, mk_row([{<<"v">>, i64, 2}])}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [#{<<"v">> := 1, <<"rank">> := 1, <<"row_number">> := 1},
     #{<<"v">> := 2, <<"rank">> := 2, <<"row_number">> := 2},
     #{<<"v">> := 3, <<"rank">> := 3, <<"row_number">> := 3}] = out_maps(Output),
    ok = cleanup([Op, Up, Down]).

desc_order(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"v">>, <<"desc">>]])),
    Op ! mk_delta(0, [{1, mk_row([{<<"v">>, i64, 1}])},
                      {1, mk_row([{<<"v">>, i64, 3}])},
                      {1, mk_row([{<<"v">>, i64, 2}])}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [#{<<"v">> := 3, <<"row_number">> := 1},
     #{<<"v">> := 2, <<"row_number">> := 2},
     #{<<"v">> := 1, <<"row_number">> := 3}] = out_maps(Output),
    ok = cleanup([Op, Up, Down]).

multi_key(_Config) ->
    {Op, Up, Down} = start_order(
        order_spec([[<<"d">>, <<"asc">>], [<<"s">>, <<"desc">>]])),
    Op ! mk_delta(0, [{1, mk_row([{<<"d">>, i64, 1}, {<<"s">>, i64, 10}])},
                      {1, mk_row([{<<"d">>, i64, 2}, {<<"s">>, i64, 5}])},
                      {1, mk_row([{<<"d">>, i64, 1}, {<<"s">>, i64, 20}])}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [#{<<"d">> := 1, <<"s">> := 20, <<"row_number">> := 1},
     #{<<"d">> := 1, <<"s">> := 10, <<"row_number">> := 2},
     #{<<"d">> := 2, <<"s">> := 5, <<"row_number">> := 3}] = out_maps(Output),
    ok = cleanup([Op, Up, Down]).

ties_share_rank(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"v">>, <<"asc">>]])),
    %% Two distinct rows with equal sort key v=1 → same rank 1, then v=2 → rank 3.
    Op ! mk_delta(0, [{1, mk_row([{<<"v">>, i64, 1}, {<<"x">>, i64, 1}])},
                      {1, mk_row([{<<"v">>, i64, 1}, {<<"x">>, i64, 2}])},
                      {1, mk_row([{<<"v">>, i64, 2}, {<<"x">>, i64, 3}])}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [#{<<"v">> := 1, <<"x">> := 1, <<"rank">> := 1, <<"row_number">> := 1},
     #{<<"v">> := 1, <<"x">> := 2, <<"rank">> := 1, <<"row_number">> := 2},
     #{<<"v">> := 2, <<"x">> := 3, <<"rank">> := 3, <<"row_number">> := 3}] =
        out_maps(Output),
    ok = cleanup([Op, Up, Down]).

retraction_cascades(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"v">>, <<"asc">>]])),
    Op ! mk_delta(0, [{1, mk_row([{<<"v">>, i64, 1}])},
                      {1, mk_row([{<<"v">>, i64, 2}])},
                      {1, mk_row([{<<"v">>, i64, 3}])}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    %% Retract v=1: remaining rows' rank and row_number both shift down.
    Op ! mk_delta(0, [{-1, mk_row([{<<"v">>, i64, 1}])}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [#{<<"v">> := 2, <<"rank">> := 1, <<"row_number">> := 1},
     #{<<"v">> := 3, <<"rank">> := 2, <<"row_number">> := 2}] = out_maps(Output),
    ok = cleanup([Op, Up, Down]).

no_output_between_barriers(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"v">>, <<"asc">>]])),
    Op ! mk_delta(0, [{1, mk_row([{<<"v">>, i64, 1}])}], Up),
    Op ! mk_delta(0, [{1, mk_row([{<<"v">>, i64, 2}])}], Up),
    [] = drain(Down),
    ok = cleanup([Op, Up, Down]).

barrier_tag_preserved(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"v">>, <<"asc">>]])),
    Tag = {iter, 7, 3},
    Op ! mk_delta(0, [{1, mk_row([{<<"v">>, i64, 10}])}], Up),
    Op ! mk_barrier_delta(0, Tag, [], Up),
    [{delta, #{barrier := Tag}, Output, _}] = await(Down, 1),
    [#{<<"v">> := 10, <<"rank">> := 1, <<"row_number">> := 1}] = out_maps(Output),
    ok = cleanup([Op, Up, Down]).

state_reset(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"v">>, <<"asc">>]])),
    Op ! mk_delta(0, [{1, mk_row([{<<"v">>, i64, 1}])}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    _ = await(Down, 1),
    Op ! mk_barrier_delta(0, state_reset, [], Up),
    [{delta, #{barrier := state_reset}, [], _}] = await(Down, 1),
    %% After reset, seen is empty; a new barrier emits nothing.
    Op ! mk_barrier_delta(0, {iter, 0, 1}, [], Up),
    [{delta, #{barrier := {iter, 0, 1}}, [], _}] = await(Down, 1),
    ok = cleanup([Op, Up, Down]).

multiplicity_expansion(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"v">>, <<"asc">>]])),
    %% One distinct row with weight 2 → two occurrences, consecutive row_numbers.
    Op ! mk_delta(0, [{2, mk_row([{<<"v">>, i64, 5}])},
                      {1, mk_row([{<<"v">>, i64, 1}])}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [#{<<"v">> := 1, <<"row_number">> := 1, <<"rank">> := 1},
     #{<<"v">> := 5, <<"row_number">> := 2, <<"rank">> := 2},
     #{<<"v">> := 5, <<"row_number">> := 3, <<"rank">> := 2}] = out_maps(Output),
    ok = cleanup([Op, Up, Down]).

numeric_key(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"v">>, <<"asc">>]])),
    %% {Coeff, Exp}: 1.5 = {15,-1}, 2.0 = {2,0}, 0.5 = {5,-1}.
    Op ! mk_delta(0, [{1, mk_num_row({2, 0})},
                      {1, mk_num_row({15, -1})},
                      {1, mk_num_row({5, -1})}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [#{<<"v">> := {5, -1}, <<"row_number">> := 1},
     #{<<"v">> := {15, -1}, <<"row_number">> := 2},
     #{<<"v">> := {2, 0}, <<"row_number">> := 3}] = out_maps(Output),
    ok = cleanup([Op, Up, Down]).

emission_in_row_number_order(_Config) ->
    {Op, Up, Down} = start_order(order_spec([[<<"k">>, <<"desc">>]])),
    Op ! mk_delta(0, [{1, mk_row([{<<"k">>, i64, 1}, {<<"v">>, i64, 10}])},
                      {1, mk_row([{<<"k">>, i64, 3}, {<<"v">>, i64, 30}])},
                      {1, mk_row([{<<"k">>, i64, 2}, {<<"v">>, i64, 20}])}], Up),
    Op ! mk_barrier_delta(0, {iter, 0, 0}, [], Up),
    [{delta, _, Output, _}] = await(Down, 1),
    [#{<<"k">> := 3, <<"row_number">> := 1},
     #{<<"k">> := 2, <<"row_number">> := 2},
     #{<<"k">> := 1, <<"row_number">> := 3}] = out_maps(Output),
    ok = cleanup([Op, Up, Down]).
