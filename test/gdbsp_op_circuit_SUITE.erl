%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_circuit — barrier-aware composite operator.
%%%
%%% Tests basic internal routing, topological execution, and
%%% external output routing. Uses gdbsp_op_map and gdbsp_op_plus
%%% as sub-operators since they are simple and well-tested.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_circuit_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    init_returns_labels/1,
    linear_chain_passthrough/1,
    diamond_merges_outputs/1,
    merge_metas_passthrough/1,
    unknown_external_label_noop/1
]).

all() ->
    [{group, circuit}].

groups() ->
    [{circuit, [parallel], [
        init_returns_labels,
        linear_chain_passthrough,
        diamond_merges_outputs,
        merge_metas_passthrough,
        unknown_external_label_noop
    ]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

mk_delta(Epoch, Deltas) ->
    {delta, #{epoch => Epoch}, Deltas}.

rename_args(From, To) ->
    #{kind => rename, columns => #{From => #{var => To}}}.

identity_args() ->
    #{kind => rename, columns => #{}}.

%%====================================================================
%% init_returns_labels — verify init returns correct labels
%%====================================================================

init_returns_labels(_Config) ->
    Ops = #{
        map1 => {gdbsp_op_map, identity_args()}
    },
    Wires = [],
    ExtIn = [{in, {map1, default}}],
    ExtOut = [{map1, default, out}],

    {State, InLabels, OutLabels} = gdbsp_op_circuit:init(#{
        operators => Ops, wires => Wires,
        external_inputs => ExtIn, external_outputs => ExtOut
    }),

    [in] = InLabels,
    [out] = OutLabels,
    [map1] = maps:get(order, State),
    true = maps:is_key(map1, maps:get(states, State)),
    true = maps:is_key(map1, maps:get(mods, State)).

%%====================================================================
%% linear_chain_passthrough — ext → map1 → map2 → ext
%%====================================================================

linear_chain_passthrough(_Config) ->
    Ops = #{
        map1 => {gdbsp_op_map, rename_args(<<"x">>, <<"y">>)},
        map2 => {gdbsp_op_map, rename_args(<<"y">>, <<"z">>)}
    },
    Wires = [
        {map1, default, map2, default}
    ],
    ExtIn = [{in, {map1, default}}],
    ExtOut = [{map2, default, out}],

    {State, _In, _Out} = gdbsp_op_circuit:init(#{
        operators => Ops, wires => Wires,
        external_inputs => ExtIn, external_outputs => ExtOut
    }),

    {State2, Actions} = gdbsp_op_circuit:handle_delta(
        State, in, mk_delta(0, [{1, #{<<"x">> => 5}}, {1, #{<<"x">> => 10}}])),

    [{send, out, {delta, #{epoch := 0}, [{1, R1}, {1, R2}]}}] = Actions,
    5 = maps:get(<<"z">>, R1),
    10 = maps:get(<<"z">>, R2),
    true = is_map(State2).

%%====================================================================
%% diamond_merges_outputs — ext → map1, map2 → plus → ext
%%====================================================================

diamond_merges_outputs(_Config) ->
    Ops = #{
        map_a => {gdbsp_op_map, rename_args(<<"x">>, <<"a">>)},
        map_b => {gdbsp_op_map, rename_args(<<"x">>, <<"b">>)},
        plus1 => {gdbsp_op_plus, #{labels => [a_label, b_label]}}
    },
    Wires = [
        {map_a, default, plus1, a_label},
        {map_b, default, plus1, b_label}
    ],
    ExtIn = [
        {in_a, {map_a, default}},
        {in_b, {map_b, default}}
    ],
    ExtOut = [{plus1, default, out}],

    {State, _In, _Out} = gdbsp_op_circuit:init(#{
        operators => Ops, wires => Wires,
        external_inputs => ExtIn, external_outputs => ExtOut
    }),

    {State2, ActionsA} = gdbsp_op_circuit:handle_delta(
        State, in_a, mk_delta(0, [{1, #{<<"x">> => 5}}])),

    {State3, ActionsB} = gdbsp_op_circuit:handle_delta(
        State2, in_b, mk_delta(0, [{1, #{<<"x">> => 10}}])),

    [] = ActionsA,
    [] = ActionsB,
    true = is_map(State3).

%%====================================================================
%% merge_metas_passthrough — trivial merge single meta
%%====================================================================

merge_metas_passthrough(_Config) ->
    Meta = #{epoch => 0},
    Meta = gdbsp_op_circuit:merge_metas(#{k => Meta}).

%%====================================================================
%% unknown_external_label_noop — delta on unknown label is ignored
%%====================================================================

unknown_external_label_noop(_Config) ->
    Ops = #{
        map1 => {gdbsp_op_map, identity_args()}
    },
    Wires = [],
    ExtIn = [{in, {map1, default}}],
    ExtOut = [{map1, default, out}],

    {State, _In, _Out} = gdbsp_op_circuit:init(#{
        operators => Ops, wires => Wires,
        external_inputs => ExtIn, external_outputs => ExtOut
    }),

    {State2, []} = gdbsp_op_circuit:handle_delta(
        State, unknown, mk_delta(0, [{1, 99}])),
    true = is_map(State2).
