%%%-------------------------------------------------------------------
%%% @doc Lowering stage test suite — tests gdbsp_compile_lower:run/2
%%% in isolation. Verifies #lowered_graph{} structure:
%%%   - Content-addressing & deduplication
%%%   - Fixpoint expansion (trivial & self-referential)
%%%   - Tag assignment
%%%   - Error validation
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_lower_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_parse.hrl").
-include("gdbsp_lowered.hrl").

-export([all/0]).
-export([
    dedup_same_op_same_inputs/1,
    dedup_different_inputs/1,
    dedup_different_args/1,
    dedup_different_ops/1,
    dedup_source_same_table/1,
    dedup_source_different_table/1,
    dedup_none/1,
    dedup_transitive/1,
    circuit_trivial_dedup/1,
    circuit_trivial_different_args/1,
    circuit_trivial_nested_tags/1,
    circuit_trivial_member_access/1,
    fixpoint_selfref_inputs_isolated/1,
    fixpoint_selfref_tags/1,
    fixpoint_selfref_body_wiring/1,
    fixpoint_selfref_metadata/1,
    fixpoint_selfref_distinct_valid/1,
    fixpoint_selfref_distinct_error/1,
    fixpoint_forbidden_operator/1,
    fixpoint_trivial_no_fixpoint_info/1,
    member_access_resolved/1,
    tag_map_completeness/1,
    circuit_macro_kw_substitution/1,
    circuit_macro_multi_kw_substitution/1,
    circuit_macro_kw_alias_substitution/1,
    duplicate_node_error/1,
    cycle_error/1
]).

all() ->
    [
     dedup_same_op_same_inputs,
     dedup_different_inputs,
     dedup_different_args,
     dedup_different_ops,
     dedup_source_same_table,
     dedup_source_different_table,
     dedup_none,
     dedup_transitive,
     circuit_trivial_dedup,
     circuit_trivial_different_args,
     circuit_trivial_member_access,
     fixpoint_selfref_inputs_isolated,
     fixpoint_selfref_tags,
     fixpoint_selfref_body_wiring,
     fixpoint_selfref_metadata,
     fixpoint_selfref_distinct_valid,
     fixpoint_selfref_distinct_error,
     fixpoint_forbidden_operator,
     fixpoint_trivial_no_fixpoint_info,
      member_access_resolved,
      tag_map_completeness,
      circuit_macro_kw_substitution,
      circuit_macro_multi_kw_substitution,
      circuit_macro_kw_alias_substitution,
      duplicate_node_error,
     cycle_error
    ].

%%====================================================================
%% Helpers
%%====================================================================

lower(Source) ->
    {ok, Prog} = gdbsp_parse:parse_string(list_to_binary(Source), #{}),
    gdbsp_compile_lower:run(Prog, #{}, #{}).

lnode_op(#lnode{op = Op}) -> Op.
lnode_tags(#lnode{tags = Tags}) -> Tags.
lnode_inputs(#lnode{inputs = Inputs}) -> Inputs.

find_by_tag(Tag, LG) ->
    case maps:find(Tag, LG#lowered_graph.tag_map) of
        {ok, Id} ->
            case maps:find(Id, LG#lowered_graph.nodes) of
                {ok, Node} -> {Id, Node};
                error -> error
            end;
        error -> error
    end.

assert_has_tag(Tag, LG) ->
    {Id, _} = find_by_tag(Tag, LG),
    Id.

assert_nodes_count(Expected, LG) ->
    Expected = map_size(LG#lowered_graph.nodes),
    ok.

%%====================================================================
%% Deduplication tests
%%====================================================================

dedup_same_op_same_inputs(_Config) ->
    Src = "s := source(\"t\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "a := map(s, fn1)\n"
          "b := map(s, fn1)\n",
    {ok, LG} = lower(Src),
    assert_nodes_count(2, LG),
    %% a and b resolve to same node
    AId = assert_has_tag(<<"a">>, LG),
    BId = assert_has_tag(<<"b">>, LG),
    true = (AId =:= BId),
    MapNode = element(2, find_by_tag(<<"a">>, LG)),
    [<<"a">>, <<"b">>] = lists:sort(lnode_tags(MapNode)),
    ok.

dedup_different_inputs(_Config) ->
    Src = "s1 := source(\"t1\")\n"
          "s1 :: stream(struct(\"x\": i64))\n"
          "s2 := source(\"t2\")\n"
          "s2 :: stream(struct(\"x\": i64))\n"
          "a := map(s1, fn1)\n"
          "b := map(s2, fn1)\n",
    {ok, LG} = lower(Src),
    %% a and b have different inputs → distinct nodes
    AId = assert_has_tag(<<"a">>, LG),
    BId = assert_has_tag(<<"b">>, LG),
    true = (AId =/= BId),
    ok.

dedup_different_args(_Config) ->
    Src = "s := source(\"t\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "a := map(s, fn1)\n"
          "b := map(s, fn2)\n",
    {ok, LG} = lower(Src),
    %% a and b have different fn args → distinct nodes
    AId = assert_has_tag(<<"a">>, LG),
    BId = assert_has_tag(<<"b">>, LG),
    true = (AId =/= BId),
    ok.

dedup_different_ops(_Config) ->
    Src = "s := source(\"t\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "a := filter(s, fn1)\n"
          "b := map(s, fn1)\n",
    {ok, LG} = lower(Src),
    AId = assert_has_tag(<<"a">>, LG),
    BId = assert_has_tag(<<"b">>, LG),
    true = (AId =/= BId),
    ok.

dedup_source_same_table(_Config) ->
    Src = "a := source(\"t\")\n"
          "a :: stream(struct(\"x\": i64))\n"
          "b := source(\"t\")\n"
          "b :: stream(struct(\"x\": i64))\n",
    {ok, LG} = lower(Src),
    assert_nodes_count(1, LG),
    AId = assert_has_tag(<<"a">>, LG),
    BId = assert_has_tag(<<"b">>, LG),
    true = (AId =:= BId),
    Node = element(2, find_by_tag(<<"a">>, LG)),
    [<<"a">>, <<"b">>] = lists:sort(lnode_tags(Node)),
    ok.

dedup_source_different_table(_Config) ->
    Src = "a := source(\"t1\")\n"
          "a :: stream(struct(\"x\": i64))\n"
          "b := source(\"t2\")\n"
          "b :: stream(struct(\"x\": i64))\n",
    {ok, LG} = lower(Src),
    assert_nodes_count(2, LG),
    AId = assert_has_tag(<<"a">>, LG),
    BId = assert_has_tag(<<"b">>, LG),
    true = (AId =/= BId),
    ok.

dedup_none(_Config) ->
    Src = "a := source(\"t\")\n"
          "a :: stream(struct(\"x\": i64))\n"
          "b := map(a, fn1)\n"
          "c := map(b, fn2)\n",
    {ok, LG} = lower(Src),
    assert_nodes_count(3, LG),
    ok.

dedup_transitive(_Config) ->
    Src = "s := source(\"t\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "a := map(s, fn1)\n"
          "b := map(a, fn2)\n"
          "c := map(s, fn1)\n"
          "d := map(c, fn2)\n",
    {ok, LG} = lower(Src),
    %% a and c deduplicate; b and d deduplicate because they have same input chain.
    %% s is separate. Total: 3 unique nodes.
    assert_nodes_count(3, LG),
    ok.

%%====================================================================
%% Trivial fixpoint tests
%%====================================================================

circuit_trivial_dedup(_Config) ->
    Src = "circuit pass(x: v):\n"
          "    result := map(v, fn1)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "fp1 := fixpoint(pass(x: s))\n"
          "fp2 := fixpoint(pass(x: s))\n"
          "out1 := fp1.result\n"
          "out2 := fp2.result\n",
    {ok, LG} = lower(Src),
    %% fp1.result and fp2.result should be the SAME lowered node
    FP1Id = assert_has_tag(<<"fp1.result">>, LG),
    FP2Id = assert_has_tag(<<"fp2.result">>, LG),
    true = (FP1Id =:= FP2Id),
    %% No fixpoint metadata entries (trivial circuit)
    0 = map_size(LG#lowered_graph.fixpoints),
    ok.

circuit_trivial_different_args(_Config) ->
    Src = "circuit pass(x: v):\n"
          "    result := map(v, fn1)\n"
          "s1 := source(\"data1\")\n"
          "s1 :: stream(struct(\"x\": i64))\n"
          "s2 := source(\"data2\")\n"
          "s2 :: stream(struct(\"x\": i64))\n"
          "fp1 := fixpoint(pass(x: s1))\n"
          "fp2 := fixpoint(pass(x: s2))\n"
          "out1 := fp1.result\n"
          "out2 := fp2.result\n",
    {ok, LG} = lower(Src),
    FP1Id = assert_has_tag(<<"fp1.result">>, LG),
    FP2Id = assert_has_tag(<<"fp2.result">>, LG),
    true = (FP1Id =/= FP2Id),
    ok.

circuit_trivial_nested_tags(_Config) ->
    Src = "circuit inner(x: v):\n"
          "    result := map(v, fn1)\n"
          "circuit outer(x: v):\n"
          "    inner_fp := fixpoint(inner(x: v))\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "fp := fixpoint(outer(x: s))\n"
          "out := fp.inner_fp.result\n",
    {ok, LG} = lower(Src),
    %% Tags should include nested path like "fp.inner_fp.result"
    assert_has_tag(<<"fp.inner_fp.result">>, LG),
    ok.

circuit_trivial_member_access(_Config) ->
    Src = "circuit pass(x: v):\n"
          "    result := map(v, fn1)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "fp := fixpoint(pass(x: s))\n"
          "out := fp.result\n",
    {ok, LG} = lower(Src),
    %% member_access "fp.result" should resolve to the body output tag
    %% "out" is a plus wrapper around fp.result
    {_, OutNode} = find_by_tag(<<"out">>, LG),
    FpOutId = assert_has_tag(<<"fp.result">>, LG),
    [FpOutId] = lnode_inputs(OutNode),
    plus = lnode_op(OutNode),
    ok.

%%====================================================================
%% Self-referential fixpoint tests
%%====================================================================

fixpoint_selfref_inputs_isolated(_Config) ->
    Src = "circuit acc(base: input, result: r):\n"
          "    result := distinct(r)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"v\": i64))\n"
          "fp := fixpoint(acc(base: s, result: s))\n"
          "out := fp.result\n",
    {ok, LG} = lower(Src),
    %% Both base and result params map to same source "s",
    %% but fixpoint_input nodes must be distinct (different param names).
    %% Find fixpoint_input nodes
    FinNodes = [N || {_, N} <- maps:to_list(LG#lowered_graph.nodes),
                      lnode_op(N) =:= fixpoint_input],
    2 = length(FinNodes),
    %% They must have different IDs (different param names in args)
    [FinId1, FinId2] = [Id || #lnode{id = Id} <- FinNodes],
    true = (FinId1 =/= FinId2),
    ok.

fixpoint_selfref_tags(_Config) ->
    Src = "circuit acc(base: input, result: r):\n"
          "    result := distinct(r)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"v\": i64))\n"
          "fp := fixpoint(acc(base: s, result: s))\n"
          "out := fp.result\n",
    {ok, LG} = lower(Src),
    %% fixpoint_output has tag "fp.result", fixpoint_input does NOT
    assert_has_tag(<<"fp.result">>, LG),
    FpOutNode = element(2, find_by_tag(<<"fp.result">>, LG)),
    fixpoint_output = lnode_op(FpOutNode),
    %% Verify fixpoint_input nodes have NO tags (they're internal)
    FinNodes = [N || {_, N} <- maps:to_list(LG#lowered_graph.nodes),
                      lnode_op(N) =:= fixpoint_input],
    [true = (lnode_tags(N) =:= []) || N <- FinNodes],
    ok.

fixpoint_selfref_body_wiring(_Config) ->
    Src = "circuit acc(base: input, result: r):\n"
          "    result := distinct(r)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"v\": i64))\n"
          "fp := fixpoint(acc(base: s, result: s))\n"
          "out := fp.result\n",
    {ok, LG} = lower(Src),
    %% The body distinct node should consume a fixpoint_input (self-ref),
    %% NOT the external source directly.
    FinNodes = [N || {_, N} <- maps:to_list(LG#lowered_graph.nodes),
                      lnode_op(N) =:= fixpoint_input],
    FinIds = [Id || #lnode{id = Id} <- FinNodes],
    DistinctNode = hd([N || {_, N} <- maps:to_list(LG#lowered_graph.nodes),
                             lnode_op(N) =:= distinct]),
    [DistinctInput] = lnode_inputs(DistinctNode),
    true = lists:member(DistinctInput, FinIds),
    ok.

fixpoint_selfref_metadata(_Config) ->
    Src = "circuit acc(base: input, result: r):\n"
          "    result := distinct(r)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"v\": i64))\n"
          "fp := fixpoint(acc(base: s, result: s))\n"
          "out := fp.result\n",
    {ok, LG} = lower(Src),
    1 = map_size(LG#lowered_graph.fixpoints),
    [_FpHmac | _] = maps:keys(LG#lowered_graph.fixpoints),
    [FixInfo] = maps:values(LG#lowered_graph.fixpoints),
    <<"acc">> = maps:get(circuit_name, FixInfo),
    [<<"fp">>] = maps:get(tags, FixInfo),
    Params = maps:get(params, FixInfo),
    2 = map_size(Params),
    %% base param
    #{<<"base">> := #{kind := base,
                       label := LblBase,
                       input := InpBase}} = Params,
    <<"fp.base">> = LblBase,
    %% result param (self-ref)
    #{<<"result">> := #{kind := self_ref,
                          label := LblResult,
                          input := InpResult,
                          body_out := BodyOut}} = Params,
    <<"fp.result">> = LblResult,
    true = (InpBase =/= InpResult),
    true = is_binary(BodyOut),
    ok.

fixpoint_selfref_distinct_valid(_Config) ->
    Src = "circuit ok(base: input, result: r):\n"
          "    result := distinct(r)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"v\": i64))\n"
          "fp := fixpoint(ok(base: s, result: s))\n"
          "out := fp.result\n",
    {ok, _LG} = lower(Src),
    ok.

fixpoint_selfref_distinct_error(_Config) ->
    Src = "circuit bad(base: input, result: r):\n"
          "    result := map(r, fn1)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"v\": i64))\n"
          "fp := fixpoint(bad(base: s, result: s))\n"
          "out := fp.result\n",
    {error, {fixpoint_error, {_Line, Msg}}} = lower(Src),
    true = (binary:match(Msg, <<"distinct">>) =/= nomatch),
    ok.

fixpoint_forbidden_operator(_Config) ->
    Src = "circuit bad(base: input, result: r):\n"
          "    result := distinct(r)\n"
          "    agg := aggregate(r, sum_v, by: [\"v\"])\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"v\": i64))\n"
          "sum_v :: aggregate_function((struct(\"v\": i64)) -> struct(\"total\": i64))\n"
          "sum_v := function((row) -> struct(\"total\": std.agg_sum_i64(row.v)))\n"
          "fp := fixpoint(bad(base: s, result: s))\n"
          "out := fp.result\n",
    {error, {fixpoint_error, {_Line, Msg}}} = lower(Src),
    true = (binary:match(Msg, <<"aggregate">>) =/= nomatch),
    ok.

fixpoint_trivial_no_fixpoint_info(_Config) ->
    Src = "circuit pass(x: v):\n"
          "    result := map(v, fn1)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "fp := fixpoint(pass(x: s))\n"
          "out := fp.result\n",
    {ok, LG} = lower(Src),
    0 = map_size(LG#lowered_graph.fixpoints),
    ok.

%%====================================================================
%% member_access tests
%%====================================================================

member_access_resolved(_Config) ->
    Src = "circuit pass(x: v):\n"
          "    result := map(v, fn1)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "fp := fixpoint(pass(x: s))\n"
          "out := fp.result\n",
    {ok, LG} = lower(Src),
    %% "out" should exist and be a plus wrapping the body output
    OutId = assert_has_tag(<<"out">>, LG),
    {_, OutNode} = find_by_tag(<<"out">>, LG),
    plus = lnode_op(OutNode),
    FpOutId = assert_has_tag(<<"fp.result">>, LG),
    [FpOutId] = lnode_inputs(OutNode),
    ok.

tag_map_completeness(_Config) ->
    Src = "circuit pass(x: v):\n"
          "    result := map(v, fn1)\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"x\": i64))\n"
          "fp := fixpoint(pass(x: s))\n"
          "out := fp.result\n",
    {ok, LG} = lower(Src),
    %% Every source-level name should be in tag_map
    assert_has_tag(<<"s">>, LG),
    assert_has_tag(<<"fp.result">>, LG),
    assert_has_tag(<<"out">>, LG),
    ok.

circuit_macro_kw_substitution(_Config) ->
    Src = "circuit double(x: v):\n"
          "    result := plus(v, v)\n"
          "circuit call_double(src: val):\n"
          "    c := double(x: val)\n"
          "    result := c.result\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"v\": i64))\n"
          "w := call_double(src: s)\n"
          "out := w.result\n",
    {ok, LG} = lower(Src),
    %% The inner plus node under w.c.result must have source s as both inputs
    CResultNode = element(2, find_by_tag(<<"w.c.result">>, LG)),
    SrcId = assert_has_tag(<<"s">>, LG),
    [SrcId, SrcId] = lnode_inputs(CResultNode),
    ok.

circuit_macro_multi_kw_substitution(_Config) ->
    Src = "circuit combine(a: x, b: y):\n"
          "    result := plus(x, y)\n"
          "circuit gather(p: v, q: w):\n"
          "    c := combine(a: v, b: w)\n"
          "    result := c.result\n"
          "s := source(\"data\")\n"
          "s :: stream(struct(\"v\": i64))\n"
          "g := gather(p: s, q: s)\n"
          "out := g.result\n",
    {ok, LG} = lower(Src),
    %% The plus node under g.c.result must have source s as both inputs
    GCombNode = element(2, find_by_tag(<<"g.c.result">>, LG)),
    SrcId = assert_has_tag(<<"s">>, LG),
    [SrcId, SrcId] = lnode_inputs(GCombNode),
    ok.

circuit_macro_kw_alias_substitution(_Config) ->
    Src = "circuit pass(x: v):\n"
          "    result := v\n"
          "circuit wrap(s: val):\n"
          "    c := pass(x: val)\n"
          "    result := c.result\n"
          "src := source(\"data\")\n"
          "src :: stream(struct(\"v\": i64))\n"
          "w := wrap(s: src)\n"
          "out := w.result\n",
    {ok, LG} = lower(Src),
    %% The pass alias node under w.c.result must have src as input
    CResultNode = element(2, find_by_tag(<<"w.c.result">>, LG)),
    SrcId = assert_has_tag(<<"src">>, LG),
    [SrcId] = lnode_inputs(CResultNode),
    ok.

%%====================================================================
%% Error tests
%%====================================================================

duplicate_node_error(_Config) ->
    Src = "a := source(\"t\")\n"
          "a :: stream(struct(\"x\": i64))\n"
          "a := source(\"s\")\n",
    {error, {duplicate_node, _}} = lower(Src),
    ok.

cycle_error(_Config) ->
    Src = "a := source(\"t\")\n"
          "a :: stream(struct(\"x\": i64))\n"
          "b := map(a, f1)\n"
          "a := map(b, f2)\n",
    case lower(Src) of
        {error, cycle_in_graph} -> ok;
        {error, {duplicate_node, _}} -> ok;
        Other -> ct:fail("expected error, got ~p", [Other])
    end.
