%%%-------------------------------------------------------------------
%%% @doc Compiler test suite — YAML fixture-driven.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_circuit.hrl").

-export([all/0]).
-export([init_per_suite/1, end_per_suite/1]).

-export([simple_filter/1, simple_map/1, join/1, aggregate/1, plus_multi/1,
         incrementalize_filter/1, incrementalize_join/1, cycle_error/1,
         missing_fn/1, duplicate_node/1,
         delay_inputs_not_empty_for_chain/1, delay_ordering_independent/1,
         inline_fn_map/1, inline_fn_overrides_external/1,
         typespec_only_external_fn/1, typespec_only_no_external/1]).

-define(FIXTURE_DIR, "parse_fixtures").

all() ->
    [simple_filter, simple_map, join, aggregate, plus_multi,
     incrementalize_filter, incrementalize_join, cycle_error,
     missing_fn, duplicate_node,
     delay_inputs_not_empty_for_chain, delay_ordering_independent,
     inline_fn_map, inline_fn_overrides_external,
     typespec_only_external_fn, typespec_only_no_external].

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
    FnReg = #{
        <<"salary_ge_150">> =>
            #{<<"call">> => <<"gte">>,
              <<"args">> => [
                  #{<<"call">> => <<"struct:get">>,
                    <<"args">> => [#{<<"arg">> => <<"row">>}],
                    <<"kwargs">> => #{<<"key">> => #{<<"type">> => <<"string">>,
                                                      <<"value">> => <<"sal">>}}},
                  #{<<"type">> => <<"i64">>, <<"value">> => <<"150">>}
              ]}
    },
    {ok, Prog} = parse_prog(
        "emp_src := source(\"emp\")\n"
        "emp_src :: stream(struct(\"name\": string(\"UTF-8\"), \"dept\": i64, \"sal\": i64))\n"
        "filtered := filter(emp_src, salary_ge_150)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => FnReg,
                                              incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    2 = length(Nodes),
    %% Verify source node exists
    SrcNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= source]),
    {source, <<"emp">>} = SrcNode#circuit_node.op,
    FilNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= filter]),
    {filter, #{expr := {call, <<"gte">>, _, _}}} = FilNode#circuit_node.op,
    ok.

simple_map(_Config) ->
    FnReg = #{
        <<"passthrough">> =>
            #{<<"call">> => <<"struct">>,
              <<"kwargs">> =>
                  #{<<"x">> => #{<<"call">> => <<"struct:get">>,
                                 <<"args">> => [#{<<"arg">> => <<"row">>}],
                                 <<"kwargs">> => #{<<"key">> => #{<<"type">> => <<"string">>,
                                                                   <<"value">> => <<"a">>}}},
                    <<"y">> => #{<<"call">> => <<"struct:get">>,
                                 <<"args">> => [#{<<"arg">> => <<"row">>}],
                                 <<"kwargs">> => #{<<"key">> => #{<<"type">> => <<"string">>,
                                                                   <<"value">> => <<"b">>}}}}}
    },
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"a\": i64, \"b\": i64))\n"
        "mapped := map(src, passthrough)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => FnReg,
                                              incrementalize => false}),
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
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => #{},
                                              incrementalize => false}),
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
    FnReg = #{
        <<"sum_sal">> =>
            #{<<"aggregate">> => <<"agg:sum">>}
    },
    {ok, Prog} = parse_prog(
        "emp_src := source(\"emp\")\n"
        "emp_src :: stream(struct(\"dept\": i64, \"sal\": i64))\n"
        "agg := aggregate(emp_src, sum_sal, by: [\"dept\"], value: \"sal\", as: \"total\")\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => FnReg,
                                              incrementalize => false}),
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
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => #{},
                                              incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    4 = length(Nodes),
    PlusNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= plus]),
    3 = length(PlusNode#circuit_node.inputs),
    ok.

incrementalize_filter(_Config) ->
    FnReg = #{
        <<"f">> =>
            #{<<"call">> => <<"gte">>,
              <<"args">> => [
                  #{<<"call">> => <<"struct:get">>,
                    <<"args">> => [#{<<"arg">> => <<"row">>}],
                    <<"kwargs">> => #{<<"key">> => #{<<"type">> => <<"string">>,
                                                      <<"value">> => <<"sal">>}}},
                  #{<<"type">> => <<"i64">>, <<"value">> => <<"100">>}
              ]}
    },
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"sal\": i64))\n"
        "filtered := filter(src, f)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => FnReg,
                                              incrementalize => true}),
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
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => #{},
                                              incrementalize => true}),
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
    FnReg = #{
        <<"f">> => #{<<"call">> => <<"struct:get">>,
                      <<"args">> => [#{<<"arg">> => <<"row">>}],
                      <<"kwargs">> => #{<<"key">> => #{<<"type">> => <<"string">>,
                                                        <<"value">> => <<"x">>}}},
        <<"g">> => #{<<"call">> => <<"struct:get">>,
                      <<"args">> => [#{<<"arg">> => <<"row">>}],
                      <<"kwargs">> => #{<<"key">> => #{<<"type">> => <<"string">>,
                                                        <<"value">> => <<"x">>}}}
    },
    case gdbsp_compile:compile(Prog, #{fn_registry => FnReg, incrementalize => false}) of
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
    case gdbsp_compile:compile(Prog, #{fn_registry => #{}, incrementalize => false}) of
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
            case gdbsp_compile:compile(Prog, #{fn_registry => #{},
                                                incrementalize => false}) of
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
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => #{},
                                              incrementalize => false}),
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
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => #{},
                                              incrementalize => false}),
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
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => #{},
                                              incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    2 = length(Nodes),
    MapNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= map]),
    %% Identity function body is just the arg reference
    {map, #{expr := {arg, <<"row">>}}} = MapNode#circuit_node.op,
    ok.

inline_fn_overrides_external(_Config) ->
    ExternalBody = #{<<"call">> => <<"struct">>,
                     <<"kwargs">> =>
                         #{<<"x">> => #{<<"type">> => <<"i64">>, <<"value">> => <<"0">>}}},
    FnReg = #{<<"id">> => ExternalBody},
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"x\": i64))\n"
        "id := function((row) -> row)\n"
        "id :: function((struct(\"x\": i64)) -> struct(\"x\": i64))\n"
        "mapped := map(src, id)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => FnReg,
                                              incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    MapNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= map]),
    %% Inline body (identity) should win over external (struct)
    {map, #{expr := {arg, <<"row">>}}} = MapNode#circuit_node.op,
    ok.

typespec_only_external_fn(_Config) ->
    FnReg = #{
        <<"inc">> =>
            #{<<"call">> => <<"add">>,
              <<"args">> => [
                  #{<<"call">> => <<"struct:get">>,
                    <<"args">> => [#{<<"arg">> => <<"row">>}],
                    <<"kwargs">> => #{<<"key">> => #{<<"type">> => <<"string">>,
                                                      <<"value">> => <<"x">>}}},
                  #{<<"type">> => <<"i64">>, <<"value">> => <<"1">>}
              ]}
    },
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"x\": i64))\n"
        "inc :: function((struct(\"x\": i64)) -> i64)\n"
        "mapped := map(src, inc)\n"
    ),
    {ok, G} = gdbsp_compile:compile(Prog, #{fn_registry => FnReg,
                                              incrementalize => false}),
    Nodes = maps:to_list(G#circuit_graph.nodes),
    MapNode = hd([N || {_, N} <- Nodes, element(1, N#circuit_node.op) =:= map]),
    {map, #{expr := {call, <<"add">>, _, _}}} = MapNode#circuit_node.op,
    ok.

typespec_only_no_external(_Config) ->
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"x\": i64))\n"
        "inc :: function((struct(\"x\": i64)) -> i64)\n"
        "mapped := map(src, inc)\n"
    ),
    case gdbsp_compile:compile(Prog, #{fn_registry => #{},
                                         incrementalize => false}) of
        {error, _} -> ok;
        Other -> ct:fail("expected error, got ~p", [Other])
    end.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

parse_prog(Str) ->
    gdbsp_parse:parse_string(list_to_binary(Str), #{}).
