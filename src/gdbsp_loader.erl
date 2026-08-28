%%%-------------------------------------------------------------------
%%% @doc Source discovery/merge and shared compile logic for the CLI
%%% and the end-to-end suite.
%%%
%%% load_sources/1 scans files and directories for *.gdbsp, parses each
%%% separately, and concatenates the programs. compile/3 runs the full
%%% compilation pipeline for a set of output node names and produces a
%%% deploy plan plus the source/output type maps.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_loader).

-include("gdbsp_parse.hrl").
-include("gdbsp_circuit.hrl").

-export([load_sources/1, compile/3]).

-type compile_result() :: #{
    plan         => map(),
    source_types => #{binary() => {binary(), term()}},
    output_types => #{binary() => term()},
    empty_types  => #{binary() => term()},
    graph        => #circuit_graph{}
}.

%%====================================================================
%% Source discovery + merge
%%====================================================================

%% @doc Load one or more .gdbsp sources. Each argument is a file or a
%% directory; directories are scanned recursively for *.gdbsp files.
%% Files are parsed separately and the programs are concatenated.
-spec load_sources([file:filename()]) ->
    {ok, #gdbsp_program{}} | {error, term()}.
load_sources(Paths) ->
    Files = discover_files(Paths, []),
    case parse_files(Files, []) of
        {ok, Programs} ->
            {ok, merge_programs(Programs)};
        {error, _} = Err ->
            Err
    end.

discover_files([], Acc) ->
    lists:usort(Acc);
discover_files([Path | Rest], Acc) ->
    case filelib:is_dir(Path) of
        true ->
            Found = filelib:fold_files(
                Path, "\\.gdbsp$", true,
                fun(F, A) -> [F | A] end, []),
            discover_files(Rest, Found ++ Acc);
        false ->
            discover_files(Rest, [Path | Acc])
    end.

parse_files([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_files([File | Rest], Acc) ->
    case gdbsp_parse:parse(File, #{}) of
        {ok, Prog} ->
            parse_files(Rest, [Prog | Acc]);
        {error, {_Line, _Msg} = Reason} ->
            {error, {parse_error, File, Reason}};
        {error, Reason} ->
            {error, {read_error, File, Reason}}
    end.

merge_programs([]) ->
    #gdbsp_program{nodes = [], typespecs = [], circuits = [], fn_defs = []};
merge_programs([Prog | Rest]) ->
    lists:foldl(fun merge_program/2, Prog, Rest).

merge_program(Prog, Acc) ->
    Acc#gdbsp_program{
        nodes     = Acc#gdbsp_program.nodes     ++ Prog#gdbsp_program.nodes,
        typespecs = Acc#gdbsp_program.typespecs ++ Prog#gdbsp_program.typespecs,
        circuits  = Acc#gdbsp_program.circuits  ++ Prog#gdbsp_program.circuits,
        fn_defs   = Acc#gdbsp_program.fn_defs   ++ Prog#gdbsp_program.fn_defs
    }.

%%====================================================================
%% Compilation
%%====================================================================

%% @doc Compile a program for the given output node names. Returns the
%% deploy plan, source type map, output type map, and the pre-incremental
%% circuit graph (for diagnostics). Unknown output names and compilation
%% errors are reported as {error, ...}.
-spec compile(#gdbsp_program{}, [binary()], boolean()) ->
    {ok, compile_result()} | {error, term()}.
compile(Program, OutputNames, Incr) ->
    SourceTypeMap = build_source_type_map(Program),
    case gdbsp_compile:compile_with_names(
           Program, #{incrementalize => false}) of
        {ok, Graph0, NameToId} ->
            case find_unknown_outputs(OutputNames, NameToId) of
                [Unknown | _] ->
                    {error, {unknown_output, Unknown}};
                [] ->
                    Graph1 = add_output_nodes(Graph0, OutputNames, NameToId),
                    OutTypes = output_types_from_graph(
                        Graph1, NameToId, OutputNames, SourceTypeMap),
                    Graph2 = case Incr of
                        true  -> gdbsp_compile_incremental:run(Graph1);
                        false -> Graph1
                    end,
                    Plan = gdbsp_deploy:plan(Graph2),
                    EmptyTypes = empty_types_from_graph(Graph1),
                    {ok, #{plan => Plan,
                           source_types => SourceTypeMap,
                           output_types => OutTypes,
                           empty_types => EmptyTypes,
                           graph => Graph1}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

find_unknown_outputs(OutputNames, NameToId) ->
    [N || N <- OutputNames, not maps:is_key(N, NameToId)].

%%====================================================================
%% Empty stream discovery (top-level feeders only)
%%====================================================================

empty_types_from_graph(Graph) ->
    maps:fold(
        fun(Id, #circuit_node{op = {empty, Name}, meta = Meta}, Acc) ->
            case maps:is_key(scc_id, Meta) of
                true -> Acc;
                false ->
                    Type = maps:get(Id, Graph#circuit_graph.types, dynamic),
                    Acc#{Name => Type}
            end;
           (_, _, Acc) -> Acc
        end, #{}, Graph#circuit_graph.nodes).

%%====================================================================
%% Output type derivation
%%====================================================================

output_types_from_graph(Graph, NameToId, OutputNames, SourceTypeMap) ->
    SrcSchemata = build_source_schemata(Graph, NameToId, SourceTypeMap),
    maps:fold(
        fun(OutName, _NodeId, Acc) ->
            case maps:find(OutName, NameToId) of
                {ok, CId} ->
                    Type = case maps:find(CId, Graph#circuit_graph.types) of
                        {ok, T} when T =/= undefined, T =/= dynamic -> T;
                        _ ->
                            Schema = maps:get(CId, Graph#circuit_graph.schemas, []),
                            build_struct_type(Schema, CId, SrcSchemata, Graph, #{})
                    end,
                    Acc#{OutName => Type};
                error -> Acc
            end
        end,
        #{},
        maps:with(OutputNames, NameToId)).

build_source_schemata(_Graph, NameToId, SourceTypeMap) ->
    maps:fold(
        fun(_TableName, {NodeName, {struct, _Fields, _} = Type}, Acc) ->
            case maps:find(NodeName, NameToId) of
                {ok, CId} -> Acc#{CId => Type};
                error -> Acc
            end;
           (_TableName, {_NodeName, _Type}, Acc) -> Acc
        end, #{}, SourceTypeMap).

build_struct_type(Cols, CId, SrcSchemata, Graph, Visited) when map_size(Visited) < 100 ->
    case maps:find(CId, SrcSchemata) of
        {ok, {struct, Fields, _}} ->
            Merged = maps:merge(
                maps:from_list([{Col, dynamic} || Col <- Cols]),
                maps:with(Cols, Fields)),
            {struct, Merged, exact};
        error ->
            case maps:find(CId, Graph#circuit_graph.nodes) of
                {ok, #circuit_node{inputs = [InId | _]}} ->
                    case maps:is_key(CId, Visited) of
                        true ->
                            Fields = maps:from_list([{Col, dynamic} || Col <- Cols]),
                            {struct, Fields, exact};
                        false ->
                            build_struct_type(Cols, InId, SrcSchemata, Graph,
                                maps:put(CId, true, Visited))
                    end;
                _ ->
                    Fields = maps:from_list([{Col, dynamic} || Col <- Cols]),
                    {struct, Fields, exact}
            end
    end;
build_struct_type(Cols, _CId, _SrcSchemata, _Graph, _Visited) ->
    Fields = maps:from_list([{Col, dynamic} || Col <- Cols]),
    {struct, Fields, exact}.

%%====================================================================
%% Source type map
%%====================================================================

build_source_type_map(#gdbsp_program{nodes = Nodes, typespecs = TSs}) ->
    TSMap = lists:foldl(
        fun(#gdbsp_typespec{name = N, spec = {type, {stream, Inner}}}, Acc) ->
                Acc#{N => Inner};
           (#gdbsp_typespec{name = N, spec = {type, T}}, Acc) ->
                Acc#{N => T};
           (_, Acc) -> Acc
        end, #{}, TSs),
    lists:foldl(
        fun(#gdbsp_node_def{name = N, op = source, args = Args}, Acc) ->
            TableName = case Args of
                [{string, B}] -> B;
                _ -> undefined
            end,
            case maps:find(N, TSMap) of
                {ok, Type} -> Acc#{TableName => {N, Type}};
                error -> Acc
            end;
           (_, Acc) -> Acc
        end, #{}, Nodes).

%%====================================================================
%% Output node injection
%%====================================================================

add_output_nodes(Graph, OutputNames, NameToId) ->
    #circuit_graph{next_id = NextId0, schemas = Schemas0} = Graph,
    {G, _} = lists:foldl(
        fun(OutName, {GAcc, AccNextId}) ->
            case maps:find(OutName, NameToId) of
                {ok, NodeId} ->
                    OutputNode = #circuit_node{
                        id = AccNextId,
                        op = {output, OutName},
                        inputs = [NodeId],
                        meta = #{}
                    },
                    OutSchema = maps:get(NodeId, Schemas0, []),
                    GAcc2 = GAcc#circuit_graph{
                        nodes = maps:put(AccNextId, OutputNode,
                                         GAcc#circuit_graph.nodes),
                        schemas = maps:put(AccNextId, OutSchema,
                                           GAcc#circuit_graph.schemas),
                        next_id = AccNextId + 1
                    },
                    {GAcc2, AccNextId + 1};
                error ->
                    {GAcc, AccNextId}
            end
        end,
        {Graph, NextId0},
        OutputNames
    ),
    G.
