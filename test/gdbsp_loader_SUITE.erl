%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_loader — source discovery/merge and the shared
%%% compile pipeline.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_loader_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_parse.hrl").
-include("gdbsp_circuit.hrl").

-export([all/0, groups/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    load_single_file/1,
    load_directory_recursively/1,
    load_merges_multiple_files/1,
    load_order_independent/1,
    load_missing_file/1,
    load_parse_error/1,
    compile_happy_path/1,
    compile_unknown_output/1,
    compile_error_passthrough/1
]).

all() -> [{group, loader}].

groups() ->
    [{loader, [parallel], [
        load_single_file,
        load_directory_recursively,
        load_merges_multiple_files,
        load_order_independent,
        load_missing_file,
        load_parse_error,
        compile_happy_path,
        compile_unknown_output,
        compile_error_passthrough
    ]}].

init_per_testcase(TC, Config) ->
    PrivDir = ?config(priv_dir, Config),
    SubDir = filename:join(PrivDir, atom_to_list(TC)),
    ok = filelib:ensure_dir(filename:join(SubDir, "_")),
    [{sub_dir, SubDir} | Config].

end_per_testcase(_TC, _Config) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

write_source(Dir, Name, Content) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, Content),
    Path.

simple_source(Table) ->
    lists:flatten(io_lib:format(
        "~s := source(\"~s\")\n"
        "~s :: stream(struct(\"v\": i64))\n"
        "out_~s := distinct(~s)\n",
        [Table, Table, Table, Table, Table])).

node_names(#gdbsp_program{nodes = Nodes}) ->
    lists:sort([N || #gdbsp_node_def{name = N} <- Nodes]).

%%====================================================================
%% load_sources
%%====================================================================

load_single_file(Config) ->
    Dir = ?config(sub_dir, Config),
    Path = write_source(Dir, "a.gdbsp", simple_source("src")),
    {ok, Prog} = gdbsp_loader:load_sources([Path]),
    [<<"out_src">>, <<"src">>] = node_names(Prog).

load_directory_recursively(Config) ->
    Dir = ?config(sub_dir, Config),
    Sub = filename:join(Dir, "nested"),
    ok = filelib:ensure_dir(filename:join(Sub, "_")),
    ok = file:write_file(filename:join(Dir, "a.gdbsp"), simple_source("a")),
    ok = file:write_file(filename:join(Sub, "b.gdbsp"), simple_source("b")),
    ok = file:write_file(filename:join(Dir, "ignored.txt"), "not a source"),
    {ok, Prog} = gdbsp_loader:load_sources([Dir]),
    [<<"a">>, <<"b">>, <<"out_a">>, <<"out_b">>] = node_names(Prog).

load_merges_multiple_files(Config) ->
    Dir = ?config(sub_dir, Config),
    A = write_source(Dir, "a.gdbsp", simple_source("a")),
    B = write_source(Dir, "b.gdbsp", simple_source("b")),
    {ok, Prog} = gdbsp_loader:load_sources([A, B]),
    [<<"a">>, <<"b">>, <<"out_a">>, <<"out_b">>] = node_names(Prog).

load_order_independent(Config) ->
    Dir = ?config(sub_dir, Config),
    A = write_source(Dir, "a.gdbsp", simple_source("a")),
    B = write_source(Dir, "b.gdbsp", simple_source("b")),
    {ok, ProgAB} = gdbsp_loader:load_sources([A, B]),
    {ok, ProgBA} = gdbsp_loader:load_sources([B, A]),
    true = (node_names(ProgAB) =:= node_names(ProgBA)).

load_missing_file(_Config) ->
    {error, _} = gdbsp_loader:load_sources(["/definitely/not/here.gdbsp"]).

load_parse_error(Config) ->
    Dir = ?config(sub_dir, Config),
    Path = write_source(Dir, "bad.gdbsp", "src :=\n"),
    {error, {parse_error, Path, _Reason}} = gdbsp_loader:load_sources([Path]).

%%====================================================================
%% compile
%%====================================================================

compile_happy_path(_Config) ->
    Source = <<"src := source(\"data\")\n"
               "src :: stream(struct(\"v\": i64))\n"
               "out := distinct(src)\n">>,
    {ok, Prog} = gdbsp_parse:parse_string(Source, #{}),
    {ok, #{plan := Plan, source_types := SourceTypes,
           output_types := OutputTypes, graph := Graph}} =
        gdbsp_loader:compile(Prog, [<<"out">>], true),

    true = is_map(Plan),
    #{<<"data">> := {<<"src">>, {struct, _, _}}} = SourceTypes,
    #{<<"out">> := _} = OutputTypes,
    true = is_record(Graph, circuit_graph).

compile_unknown_output(_Config) ->
    Source = <<"src := source(\"data\")\n"
               "src :: stream(struct(\"v\": i64))\n"
               "out := distinct(src)\n">>,
    {ok, Prog} = gdbsp_parse:parse_string(Source, #{}),
    {error, {unknown_output, <<"nope">>}} =
        gdbsp_loader:compile(Prog, [<<"nope">>], true).

compile_error_passthrough(_Config) ->
    Source = <<"src := source(\"data\")\n"
               "out := distinct(src)\n">>,
    {ok, Prog} = gdbsp_parse:parse_string(Source, #{}),
    {error, _Reason} = gdbsp_loader:compile(Prog, [<<"out">>], true).
