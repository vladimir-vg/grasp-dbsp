%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_graphviz: DOT generation for
%%% `#lowered_graph{}` and `#circuit_graph{}`.
%%%
%%% Pure unit tests — no processes, [parallel] group.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_graphviz_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_parse.hrl").
-include("gdbsp_lowered.hrl").
-include("gdbsp_circuit.hrl").

-export([all/0, groups/0]).
-export([
    %% Lowered graph
    lg_empty/1,
    lg_simple_chain/1,
    lg_join_on_fields/1,
    lg_aggregate_info/1,
    lg_fixpoint_boundary_nodes/1,
    lg_fixpoint_legend/1,
    lg_multiple_tags/1,
    %% Circuit graph
    cg_empty/1,
    cg_source_map_output/1,
    cg_with_schemas/1,
    cg_rec_nodes/1,
    cg_map_index/1,
    cg_neg_plus/1,
    cg_scc_body_comment/1,
    %% Structural validation
    lg_dot_wrapper/1,
    cg_dot_wrapper/1,
    lg_nodes_have_labels/1,
    cg_nodes_have_labels/1
]).

all() ->
    [{group, graphviz}].

groups() ->
    [{graphviz, [parallel], [
        lg_empty,
        lg_simple_chain,
        lg_join_on_fields,
        lg_aggregate_info,
        lg_fixpoint_boundary_nodes,
        lg_fixpoint_legend,
        lg_multiple_tags,
        cg_empty,
        cg_source_map_output,
        cg_with_schemas,
        cg_rec_nodes,
        cg_map_index,
        cg_neg_plus,
        cg_scc_body_comment,
        lg_dot_wrapper,
        cg_dot_wrapper,
        lg_nodes_have_labels,
        cg_nodes_have_labels
    ]}].

%%====================================================================
%% Lowered graph tests
%%====================================================================

lg_empty(_Config) ->
    LG = #lowered_graph{},
    Dot = lists:flatten(gdbsp_graphviz:lowered_to_dot(LG)),
    true = contains(Dot, "digraph"),
    true = contains(Dot, "Lowered DBSP Graph").

lg_simple_chain(_Config) ->
    Src = <<
        "e := source(\"edge\")\n"
        "e :: stream(struct(\"from\": i64, \"to\": i64))\n"
    >>,
    {ok, LG} = lower(Src),
    Dot = lists:flatten(gdbsp_graphviz:lowered_to_dot(LG)),
    true = contains(Dot, "digraph"),
    true = contains(Dot, "e"),
    true = contains(Dot, "source"),
    true = contains(Dot, "edge"),
    true = contains(Dot, "palegreen").

lg_join_on_fields(_Config) ->
    Src = <<
        "a := source(\"a\")\n"
        "a :: stream(struct(\"id\": i64, \"x\": i64))\n"
        "b := source(\"b\")\n"
        "b :: stream(struct(\"id\": i64, \"y\": i64))\n"
        "joined := join(a, b, on: [\"id\"])\n"
    >>,
    {ok, LG} = lower(Src),
    Dot = lists:flatten(gdbsp_graphviz:lowered_to_dot(LG)),
    true = contains(Dot, "joined"),
    true = contains(Dot, "join"),
    true = contains(Dot, "on:"),
    true = contains(Dot, "id").

lg_aggregate_info(_Config) ->
    Src = <<
        "inp := source(\"t\")\n"
        "inp :: stream(struct(\"g\": i64, \"v\": i64))\n"
        "aggd := aggregate(inp, sum_fn, by: [\"g\"], value: \"v\", as: \"r\")\n"
    >>,
    {ok, LG} = lower(Src),
    Dot = lists:flatten(gdbsp_graphviz:lowered_to_dot(LG)),
    true = contains(Dot, "aggd"),
    true = contains(Dot, "aggregate"),
    true = contains(Dot, "sum_fn"),
    true = contains(Dot, "by: [g]").

lg_fixpoint_boundary_nodes(_Config) ->
    Src = <<
        "s := source(\"s\")\n"
        "s :: stream(struct(\"a\": i64))\n"
        "circuit tc(base: input, result: r):\n"
        "  result := distinct(r)\n"
        "fp := fixpoint(tc(base: s, result: s))\n"
    >>,
    {ok, LG} = lower(Src),
    Dot = lists:flatten(gdbsp_graphviz:lowered_to_dot(LG)),
    true = contains(Dot, "fixpoint_input"),
    true = contains(Dot, "fixpoint_output"),
    true = contains(Dot, "lightblue").

lg_fixpoint_legend(_Config) ->
    Src = <<
        "s := source(\"s\")\n"
        "s :: stream(struct(\"a\": i64))\n"
        "circuit tc(base: input, result: r):\n"
        "  result := distinct(r)\n"
        "fp := fixpoint(tc(base: s, result: s))\n"
    >>,
    {ok, LG} = lower(Src),
    Dot = lists:flatten(gdbsp_graphviz:lowered_to_dot(LG)),
    true = contains(Dot, "// fixpoint:").

lg_multiple_tags(_Config) ->
    Src = <<
        "a := source(\"x\")\n"
        "a :: stream(struct(\"v\": i64))\n"
        "b := plus(a, a)\n"
    >>,
    {ok, LG} = lower(Src),
    Dot = lists:flatten(gdbsp_graphviz:lowered_to_dot(LG)),
    true = contains(Dot, "a"),
    true = contains(Dot, "b"),
    true = contains(Dot, "plus"),
    true = contains(Dot, "->").

%%====================================================================
%% Circuit graph tests
%%====================================================================

cg_empty(_Config) ->
    CG = #circuit_graph{},
    Dot = lists:flatten(gdbsp_graphviz:circuit_to_dot(CG)),
    true = contains(Dot, "digraph"),
    true = contains(Dot, "Circuit Graph").

cg_source_map_output(_Config) ->
    {ok, CG, _} = compile_minimal(<<
        "a := source(\"t\")\n"
        "a :: stream(struct(\"v\": i64))\n"
        "b := source(\"u\")\n"
        "b :: stream(struct(\"v\": i64))\n"
        "c := plus(a, b)\n"
    >>),
    Dot = lists:flatten(gdbsp_graphviz:circuit_to_dot(CG)),
    true = contains(Dot, "digraph"),
    true = contains(Dot, "source"),
    true = contains(Dot, "t"),
    true = contains(Dot, "plus"),
    true = contains(Dot, "->").

cg_with_schemas(_Config) ->
    {ok, CG, _} = compile_minimal(<<
        "inp := source(\"people\")\n"
        "inp :: stream(struct(\"name\": string(\"UTF-8\"), \"age\": i64))\n"
    >>),
    Dot = lists:flatten(gdbsp_graphviz:circuit_to_dot(CG)),
    true = contains(Dot, "people"),
    true = contains(Dot, "name"),
    true = contains(Dot, "age").

cg_rec_nodes(_Config) ->
    Src = <<
        "s := source(\"e\")\n"
        "s :: stream(struct(\"from\": i64, \"to\": i64))\n"
        "circuit tc(base: input, result: r):\n"
        "  result := distinct(r)\n"
        "fp := fixpoint(tc(base: s, result: s))\n"
    >>,
    {ok, CG, _} = compile_minimal(Src),
    Dot = lists:flatten(gdbsp_graphviz:circuit_to_dot(CG)),
    true = contains(Dot, "rec("),
    true = contains(Dot, "rec_out("),
    true = contains(Dot, "scc:").

cg_map_index(_Config) ->
    Src = <<
        "a := source(\"a\")\n"
        "a :: stream(struct(\"id\": i64, \"x\": i64))\n"
        "b := source(\"b\")\n"
        "b :: stream(struct(\"id\": i64, \"y\": i64))\n"
        "j := join(a, b, on: [\"id\"])\n"
    >>,
    {ok, CG, _} = compile_minimal(Src),
    Dot = lists:flatten(gdbsp_graphviz:circuit_to_dot(CG)),
    true = contains(Dot, "map_index"),
    true = contains(Dot, "key:"),
    true = contains(Dot, "join").

cg_neg_plus(_Config) ->
    Src = <<
        "a := source(\"a\")\n"
        "a :: stream(struct(\"v\": i64))\n"
        "b := source(\"b\")\n"
        "b :: stream(struct(\"v\": i64))\n"
        "nb := neg(b)\n"
        "p := plus(a, nb)\n"
    >>,
    {ok, CG, _} = compile_minimal(Src),
    Dot = lists:flatten(gdbsp_graphviz:circuit_to_dot(CG)),
    true = contains(Dot, "neg"),
    true = contains(Dot, "plus").

cg_scc_body_comment(_Config) ->
    Src = <<
        "s := source(\"e\")\n"
        "s :: stream(struct(\"from\": i64, \"to\": i64))\n"
        "circuit tc(base: input, result: r):\n"
        "  result := distinct(r)\n"
        "fp := fixpoint(tc(base: s, result: s))\n"
    >>,
    {ok, CG, _} = compile_minimal(Src),
    Dot = lists:flatten(gdbsp_graphviz:circuit_to_dot(CG)),
    true = contains(Dot, "scc_body").

%%====================================================================
%% Structural validation tests
%%====================================================================

lg_dot_wrapper(_Config) ->
    LG = #lowered_graph{},
    Dot = lists:flatten(gdbsp_graphviz:lowered_to_dot(LG)),
    true = starts_with(Dot, "digraph"),
    true = lists:last(Dot) =:= $\n,
    true = contains(Dot, "}").

cg_dot_wrapper(_Config) ->
    CG = #circuit_graph{},
    Dot = lists:flatten(gdbsp_graphviz:circuit_to_dot(CG)),
    true = starts_with(Dot, "digraph"),
    true = lists:last(Dot) =:= $\n,
    true = contains(Dot, "}").

lg_nodes_have_labels(_Config) ->
    Src = <<
        "x := source(\"t\")\n"
        "x :: stream(struct(\"v\": i64))\n"
    >>,
    {ok, LG} = lower(Src),
    Dot = lists:flatten(gdbsp_graphviz:lowered_to_dot(LG)),
    true = contains(Dot, "[label=").

cg_nodes_have_labels(_Config) ->
    {ok, CG, _} = compile_minimal(<<
        "x := source(\"t\")\n"
        "x :: stream(struct(\"v\": i64))\n"
    >>),
    Dot = lists:flatten(gdbsp_graphviz:circuit_to_dot(CG)),
    true = contains(Dot, "[label=").

%%====================================================================
%% Helpers
%%====================================================================

lower(Source) ->
    {ok, Prog} = gdbsp_parse:parse_string(Source, #{}),
    gdbsp_compile_lower:run(Prog, #{}).

compile_minimal(Source) ->
    {ok, Prog} = gdbsp_parse:parse_string(Source, #{}),
    {ok, LG} = gdbsp_compile_lower:run(Prog, #{}),
    gdbsp_compile_graph:build_from_lowered(LG, #{}).

contains(String, Sub) ->
    string:str(String, Sub) > 0.

starts_with(String, Prefix) ->
    lists:prefix(Prefix, String).
