%%%-------------------------------------------------------------------
%%% @doc Compiler test suite — YAML fixture-driven.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_circuit.hrl").
-include("gdbsp_parse.hrl").
-include("gdbsp_type.hrl").

-export([all/0]).
-export([init_per_suite/1, end_per_suite/1]).

-export([simple_filter/1, simple_map/1, join/1, aggregate/1, plus_multi/1,
         incrementalize_filter/1, incrementalize_join/1, cycle_error/1,
         missing_fn/1, duplicate_node/1,
         delay_inputs_not_empty_for_chain/1, delay_ordering_independent/1,
         inline_fn_map/1,
         inline_plus_in_distinct/1, map_output_schema_from_fn_return/1,
         join_renamed_key/1,
         map_row_type_preserves_concrete_type/1,
         join_merged_fields_preserve_concrete_types/1,
         stdlib_parse_ok/1, stdlib_has_arithmetic/1,
         stdlib_typespec_correct/1, stdlib_agg_overloads/1,
         stdlib_missing_file/1, stdlib_operator_tvar/1]).

-define(FIXTURE_DIR, "parse_fixtures").

all() ->
    [simple_filter, simple_map, join, aggregate, plus_multi,
     incrementalize_filter, incrementalize_join, cycle_error,
     missing_fn, duplicate_node,
     delay_inputs_not_empty_for_chain, delay_ordering_independent,
     inline_fn_map,
     inline_plus_in_distinct, map_output_schema_from_fn_return, join_renamed_key,
     map_row_type_preserves_concrete_type,
     join_merged_fields_preserve_concrete_types,
     stdlib_parse_ok, stdlib_has_arithmetic,
     stdlib_typespec_correct, stdlib_agg_overloads,
     stdlib_missing_file, stdlib_operator_tvar].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(yamerl),
    AppDir = code:lib_dir(grasp_dbsp),
    Root = filename:join([AppDir, "..", "..", "..", "..", "test", ?FIXTURE_DIR]),
    [{fixture_root, Root} | Config].

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

simple_filter(_Config) ->
    {ok, Prog} = parse_prog(
        "emp_src := source(\"emp\")\n"
        "emp_src :: stream(struct(\"name\": string(\"UTF-8\"), \"dept\": integer, \"sal\": integer))\n"
        "salary_ge_150 := function((row) -> row.sal >= 150)\n"
        "salary_ge_150 :: function((struct(\"name\": string(\"UTF-8\"), \"dept\": integer, \"sal\": integer)) -> enum(\"false\",\"true\"))\n"
        "filtered := filter(emp_src, salary_ge_150)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    2 = length(Nodes),
    %% Verify source node exists
    SrcNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= source]),
    {source, <<"emp">>} = SrcNode#circuit_node.op,
    FilNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= filter]),
    {filter, #{expr := {call, <<">=">>, _, _}}} = FilNode#circuit_node.op,
    ok.

simple_map(_Config) ->
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"a\": i64, \"b\": i64))\n"
        "passthrough := function((row) -> struct(\"x\": row.a, \"y\": row.b))\n"
        "passthrough :: function((struct(\"a\": i64, \"b\": i64)) -> struct(\"x\": i64, \"y\": i64))\n"
        "mapped := map(src, passthrough)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    2 = length(Nodes),
    MapNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= map]),
    {map, #{expr := {call, <<"struct">>, _, _}}} = MapNode#circuit_node.op,
    ok.

join(_Config) ->
    {ok, Prog} = parse_prog(
        "left := source(\"L\")\n"
        "left :: stream(struct(\"k\": i64, \"a\": i64))\n"
        "right := source(\"R\")\n"
        "right :: stream(struct(\"k\": i64, \"b\": i64))\n"
        "joined := join(left, right, on: [\"k\"])\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    5 = length(Nodes),
    %% Verify both map_index sub-nodes exist (one per join input)
    IdxNodes = [N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= map_index],
    2 = length(IdxNodes),
    {JoinId, JoinNode} = hd([{Id, N} || {Id, N} <- Nodes, element(1, N#circuit_node.op) =:= join]),
    JoinedSchema = maps:get(JoinId, G#circuit_graph.schemas),
    [<<"a">>, <<"b">>, <<"k">>] = lists:sort(JoinedSchema),
    ok.

aggregate(_Config) ->
    {ok, Prog} = parse_prog(
        "emp_src := source(\"emp\")\n"
        "emp_src :: stream(struct(\"dept\": i64, \"sal\": i64))\n"
        "sum_fn :: aggregate_function((struct(\"dept\": i64, \"sal\": i64)) -> struct(\"total\": i64))\n"
        "sum_fn := function((row) -> struct(\"total\": std.agg_sum_i64(row.sal)))\n"
        "agg := aggregate(emp_src, sum_fn, by: [\"dept\"])\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    4 = length(Nodes),
    AggSchema = maps:get(4, G#circuit_graph.schemas),
    [<<"dept">>, <<"total">>] = lists:sort(AggSchema),
    ok.

plus_multi(_Config) ->
    {ok, Prog} = parse_prog(
        "a := source(\"A\")\n"
        "a :: stream(struct(\"x\": i64))\n"
        "b := source(\"B\")\n"
        "b :: stream(struct(\"x\": i64))\n"
        "c := source(\"C\")\n"
        "c :: stream(struct(\"x\": i64))\n"
        "merged := plus(a, b, c)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    4 = length(Nodes),
    PlusNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= plus]),
    3 = length(PlusNode#circuit_node.inputs),
    ok.

incrementalize_filter(_Config) ->
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"sal\": integer))\n"
        "f := function((row) -> row.sal >= 100)\n"
        "f :: function((struct(\"sal\": integer)) -> enum(\"false\",\"true\"))\n"
        "filtered := filter(src, f)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => true}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    2 = length(Nodes),
    ok.

incrementalize_join(_Config) ->
    {ok, Prog} = parse_prog(
        "left := source(\"L\")\n"
        "left :: stream(struct(\"k\": i64, \"a\": i64))\n"
        "right := source(\"R\")\n"
        "right :: stream(struct(\"k\": i64, \"b\": i64))\n"
        "joined := join(left, right, on: [\"k\"])\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => true}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    true = (length(Nodes) >= 5),
    ok.

cycle_error(_Config) ->
    {ok, Prog} = parse_prog(
        "a := source(\"t\")\n"
        "a :: stream(struct(\"x\": i64))\n"
        "b := map(a, f)\n"
        "a := map(b, g)\n"
    ),
    case gdbsp_compile:compile(Prog, #{incrementalize => false}) of
        {error, cycle_in_graph} -> ok;
        {error, {duplicate_node, _}} -> ok;
        {error, duplicate_node} -> ok;
        Other -> ct:fail("expected error, got ~p", [Other])
    end.

missing_fn(_Config) ->
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"x\": i64))\n"
        "mapped := map(src, nonexistent)\n"
    ),
    case gdbsp_compile:compile(Prog, #{incrementalize => false}) of
        {error, _} -> ok;
        Other -> ct:fail("expected error, got ~p", [Other])
    end.

duplicate_node(_Config) ->
    case gdbsp_parse:parse_string(
           list_to_binary(
               "a := source(\"t\")\n"
               "a :: stream(struct(\"x\": i64))\n"
               "a := source(\"s\")\n"), #{}) of
        {ok, Prog} ->
            case gdbsp_compile:compile(Prog, #{incrementalize => false}) of
                {error, {duplicate_node, _}} -> ok;
                {error, duplicate_node} -> ok;
                Other -> ct:fail("expected duplicate error, got ~p", [Other])
            end;
        {error, _} -> ok
    end.

delay_inputs_not_empty_for_chain(_Config) ->
    {ok, Prog} = parse_prog(
        "s := source(\"data\")\n"
        "s :: stream(struct(\"x\": i64))\n"
        "d := delay(s)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = G#circuit_graph.nodes,
    DelayNode = hd([N || {_, N} <- maps:to_list(Nodes),
                          element(1, N#circuit_node.op) =:= delay]),
    [_ | _] = DelayNode#circuit_node.inputs,
    ok.

delay_ordering_independent(_Config) ->
    {ok, Prog} = parse_prog(
        "aaa := delay(zzz)\n"
        "zzz := source(\"t\")\n"
        "zzz :: stream(struct(\"x\": i64))\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = G#circuit_graph.nodes,
    SourceId = hd([Id || {Id, N} <- maps:to_list(Nodes),
                          element(1, N#circuit_node.op) =:= source]),
    DelayNode = hd([N || {_, N} <- maps:to_list(Nodes),
                          element(1, N#circuit_node.op) =:= delay]),
    [SourceId] = DelayNode#circuit_node.inputs,
    ok.

%%--------------------------------------------------------------------
%% Inline function compilation tests
%%--------------------------------------------------------------------

inline_fn_map(_Config) ->
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"x\": i64))\n"
        "id := function((row) -> row)\n"
        "id :: function((struct(\"x\": i64)) -> struct(\"x\": i64))\n"
        "mapped := map(src, id)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    2 = length(Nodes),
    MapNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= map]),
    %% Identity function body is just the arg reference
    {map, #{expr := {arg, <<"row">>}}} = MapNode#circuit_node.op,
    ok.

%%--------------------------------------------------------------------
%% Inline operator expression tests (Bug A + Bug B)
%%--------------------------------------------------------------------

inline_plus_in_distinct(_Config) ->
    {ok, Prog} = parse_prog(
        "a := source(\"A\")\n"
        "a :: stream(struct(\"x\": i64))\n"
        "b := source(\"B\")\n"
        "b :: stream(struct(\"x\": i64))\n"
        "r := distinct(plus(a, b))\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = G#circuit_graph.nodes,
    DistinctNode = hd([N || {_, N} <- maps:to_list(Nodes),
                              element(1, N#circuit_node.op) =:= distinct]),
    [PlusId] = DistinctNode#circuit_node.inputs,
    PlusNode = maps:get(PlusId, Nodes),
    {plus} = PlusNode#circuit_node.op,
    2 = length(PlusNode#circuit_node.inputs),
    ok.

map_output_schema_from_fn_return(_Config) ->
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"f\": i64, \"t\": i64))\n"
        "rename :: function((struct(\"f\": i64, \"t\": i64)) -> struct(\"key\": i64, \"f\": i64))\n"
        "rename := function((row) -> struct(\"key\": row.t, \"f\": row.f))\n"
        "mapped := map(src, rename)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = G#circuit_graph.nodes,
    {MapId, _} = hd([{Id, N} || {Id, N} <- maps:to_list(Nodes),
                                 element(1, N#circuit_node.op) =:= map]),
    Schema = maps:get(MapId, G#circuit_graph.schemas),
    [<<"f">>, <<"key">>] = lists:sort(Schema),
    ok.

join_renamed_key(_Config) ->
    {ok, Prog} = parse_prog(
        "left := source(\"L\")\n"
        "left :: stream(struct(\"k\": i64, \"a\": i64))\n"
        "right := source(\"R\")\n"
        "right :: stream(struct(\"k\": i64, \"b\": i64))\n"
        "to_key_l :: function((struct(\"k\": i64, \"a\": i64)) -> struct(\"key\": i64, \"a\": i64))\n"
        "to_key_l := function((row) -> struct(\"key\": row.k, \"a\": row.a))\n"
        "to_key_r :: function((struct(\"k\": i64, \"b\": i64)) -> struct(\"key\": i64, \"b\": i64))\n"
        "to_key_r := function((row) -> struct(\"key\": row.k, \"b\": row.b))\n"
        "l := map(left, to_key_l)\n"
        "r := map(right, to_key_r)\n"
        "joined := join(l, r, on: [\"key\"])\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    Nodes = G#circuit_graph.nodes,
    IdxNodes = [N || {_, N} <- maps:to_list(Nodes),
                       element(1, N#circuit_node.op) =:= map_index],
    2 = length(IdxNodes),
    lists:foreach(fun(N) ->
        {map_index, Spec} = N#circuit_node.op,
        [<<"key">>] = maps:get(key_vars, Spec)
    end, IdxNodes),
    {_, JoinNode} = hd([{Id, N} || {Id, N} <- maps:to_list(Nodes),
                                    element(1, N#circuit_node.op) =:= join]),
    {join, JoinSpec} = JoinNode#circuit_node.op,
    [<<"key">>] = maps:get(shared_vars, JoinSpec),
    ok.

%%--------------------------------------------------------------------
%% Bug A — compile-graph preserves inferred concrete types
%%--------------------------------------------------------------------

map_row_type_preserves_concrete_type(_Config) ->
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"f\": i64, \"t\": i64))\n"
        "id := function((row) -> row)\n"
        "id :: function((struct(\"f\": i64, \"t\": i64)) -> struct(\"f\": i64, \"t\": i64))\n"
        "mapped := map(src, id)\n"),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    MapNode = hd([N || {_, N} <- maps:to_list(G#circuit_graph.nodes),
                       element(1, N#circuit_node.op) =:= map]),
    {map, #{row_type := {struct, #{<<"f">> := i64, <<"t">> := i64}, _}}} =
        MapNode#circuit_node.op,
    ok.

join_merged_fields_preserve_concrete_types(_Config) ->
    {ok, Prog} = parse_prog(
        "left := source(\"L\")\n"
        "left :: stream(struct(\"k\": i64, \"a\": i64))\n"
        "right := source(\"R\")\n"
        "right :: stream(struct(\"k\": i64, \"b\": i64))\n"
        "joined := join(left, right, on: [\"k\"])\n"),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    {_, JoinNode} = hd([{Id, N} || {Id, N} <- maps:to_list(G#circuit_graph.nodes),
                                    element(1, N#circuit_node.op) =:= join]),
    {join, #{merged_fields := #{<<"k">> := i64, <<"a">> := i64, <<"b">> := i64}}} =
        JoinNode#circuit_node.op,
    ok.

%%--------------------------------------------------------------------
%% stdlib loading tests (Phase A)
%%--------------------------------------------------------------------

stdlib_parse_ok(_Config) ->
    case gdbsp_builtins:load_stdlib() of
        {ok, StdlibMap} when is_map(StdlibMap) -> ok;
        {error, Reason} -> ct:fail("load_stdlib failed: ~p", [Reason])
    end.

stdlib_has_arithmetic(_Config) ->
    {ok, StdlibMap} = gdbsp_builtins:load_stdlib(),
    true = maps:is_key(<<"std.add_i64">>, StdlibMap),
    true = maps:is_key(<<"std.add_numeric">>, StdlibMap),
    true = maps:is_key(<<"std.mul_f64">>, StdlibMap),
    true = maps:is_key(<<"std.neg_i64">>, StdlibMap).

stdlib_typespec_correct(_Config) ->
    {ok, StdlibMap} = gdbsp_builtins:load_stdlib(),
    [TS] = maps:get(<<"std.add_i64">>, StdlibMap),
    {function, [i64, i64], #{}, i64} = TS#gdbsp_typespec.spec.

stdlib_agg_overloads(_Config) ->
    {ok, StdlibMap} = gdbsp_builtins:load_stdlib(),
    %% With per-type naming, each specialization is a separate entry.
    TSListI64 = maps:get(<<"std.agg_sum_i64">>, StdlibMap),
    true = (length(TSListI64) >= 1),
    true = lists:any(
        fun(#gdbsp_typespec{spec = {aggregate_function, [i64], #{}, i64}}) -> true;
           (_) -> false
        end, TSListI64),
    TSListInteger = maps:get(<<"std.agg_sum_integer">>, StdlibMap),
    true = (length(TSListInteger) >= 1),
    true = lists:any(
        fun(#gdbsp_typespec{spec = {aggregate_function, [integer], #{}, integer}}) -> true;
           (_) -> false
        end, TSListInteger),
    TSListNumeric = maps:get(<<"std.agg_sum_numeric">>, StdlibMap),
    true = (length(TSListNumeric) >= 1),
    true = lists:any(
        fun(#gdbsp_typespec{spec = {aggregate_function, [numeric], #{}, numeric}}) -> true;
           (_) -> false
        end, TSListNumeric).

stdlib_missing_file(_Config) ->
    %% Test that loading a non-existent path returns error
    Result = load_stdlib_at("/nonexistent/path/stdlib.gdbsp"),
    {error, _} = Result.

stdlib_operator_tvar(_Config) ->
    {ok, StdlibMap} = gdbsp_builtins:load_stdlib(),
    %% Operator entries not in Phase A's stdlib yet, but verify the map works
    %% (this test prepares for Phase E when operator TVars are added)
    true = is_map(StdlibMap).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

parse_prog(Str) ->
    gdbsp_parse:parse_string(list_to_binary(Str), #{}).

load_stdlib_at(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            {ok, Prog} = gdbsp_parse:parse_string(Bin, #{}),
            {ok, gdbsp_builtins:build_stdlib_map(Prog#gdbsp_program.typespecs)};
        {error, _} = E -> E
    end.
