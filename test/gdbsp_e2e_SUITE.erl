%%%-------------------------------------------------------------------
%%% @doc Grasp DBSP end-to-end test suite — YAML fixture-driven.
%%%
%%% Each YAML file in gdbsp_e2e_SUITE_data/ contains a list of test
%%% cases. Each case provides .gdbsp source, optional function
%%% definitions, multi-epoch input deltas, and per-epoch expected
%%% output.
%%%
%%% Two matching modes:
%%%   expected:        subset matching — every expected row must be
%%%                    present with exact weight; extra rows are
%%%                    silently ignored.
%%%   expected_exact:  exact matching — expected rows must match
%%%                    exactly; extra rows in actual output cause
%%%                    a failure.
%%%   Exactly one of expected / expected_exact must be provided.
%%%
%%% Row format: [weight, #{<<"col">> => val, ...}]
%%% Values are JSON-encoded (integers as strings, dates as objects, etc.)
%%% as defined by gdbsp_value_json:encode_field/2.
%%% Epoch indexing: 0-based.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_e2e_SUITE).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([fixture_test/1]).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_parse.hrl").
-include("gdbsp_circuit.hrl").
-include("gdbsp_lowered.hrl").
-include("gdbsp_type.hrl").

%%====================================================================
%% CT callbacks
%%====================================================================

all() -> [{group, all_tests}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(yamerl),
    Config.

end_per_suite(_Config) ->
    ok.

groups() ->
    {ok, _} = application:ensure_all_started(yamerl),
    FixtureDefs = discover_and_build_groups(),
    FixtureRefs = [{group, N} || {N, _, _} <- FixtureDefs],
    application:stop(yamerl),
    case FixtureRefs of
        [] -> [];
        _ -> [{all_tests, [parallel], FixtureRefs} | FixtureDefs]
    end.

%%====================================================================
%% YAML discovery
%%====================================================================

discover_and_build_groups() ->
    YamlFiles = discover_yaml_files(),
    lists:flatmap(fun build_fixture_groups/1, YamlFiles).

build_fixture_groups(YamlPath) ->
    BaseName = group_name(YamlPath),
    Fixtures = load_yaml_file(YamlPath),
    [begin
        GroupName = list_to_atom(
            atom_to_list(BaseName) ++ "_" ++ integer_to_list(N)),
        persistent_term:put({?MODULE, GroupName}, [Fixture]),
        {GroupName, [parallel], [fixture_test]}
     end || {Fixture, N} <- lists:zip(Fixtures, lists:seq(1, length(Fixtures)))].

discover_yaml_files() ->
    filelib:fold_files(
        yaml_data_dir(), "\\.yaml$", true,
        fun(P, Acc) -> [P | Acc] end, []).

yaml_data_dir() ->
    filename:join(
        filename:dirname(code:which(?MODULE)), "gdbsp_e2e_SUITE_data").

load_yaml_file(Path) ->
    try
        [YamlDoc] = yamerl_constr:file(Path),
        to_map(YamlDoc)
    catch
        C:E ->
            ct:log("Failed to load YAML file ~s: ~p:~p", [Path, C, E]),
            []
    end.

maybe_to_bin(V) when is_list(V) -> list_to_binary(V);
maybe_to_bin(V) when is_binary(V) -> V;
maybe_to_bin(V) -> V.

deep_binify_vals([]) -> [];
deep_binify_vals(V) when is_map(V) ->
    maps:fold(fun(K, Val, Acc) ->
        Acc#{K => deep_binify_vals(Val)}
    end, #{}, V);
deep_binify_vals(V) when is_list(V) ->
    case is_char_list(V) of
        true -> list_to_binary(V);
        false -> [deep_binify_vals(E) || E <- V]
    end;
deep_binify_vals(V) -> V.

maybe_deep_binify([]) -> [];
maybe_deep_binify(V) -> deep_binify_vals(V).

is_char_list([]) -> true;
is_char_list([H | T]) when is_integer(H), H >= 0, H =< 255 ->
    is_char_list(T);
is_char_list(_) -> false.

group_name(YamlPath) ->
    D = yaml_data_dir(),
    Rel = lists:nthtail(length(D) + 1, YamlPath),
    Parts = string:tokens(filename:rootname(Rel), "/"),
    list_to_atom(string:join(Parts, "_")).

%%====================================================================
%% Test runner
%%====================================================================

fixture_test(Config) ->
    GroupName = proplists:get_value(name, ?config(tc_group_properties, Config)),
    [Fixture] = persistent_term:get({?MODULE, GroupName}),
    run_one_fixture(Fixture, GroupName, Config).

run_one_fixture(Fixture, GroupName, Config) ->
    Source = maybe_to_bin(maps:get(<<"source">>, Fixture)),
    Functions = maps:fold(
        fun(K, V, Acc) ->
            Acc#{K => deep_binify_vals(V)}
        end, #{}, maps:get(<<"functions">>, Fixture, #{})),
    InputEpochs = maybe_deep_binify(maps:get(<<"input">>, Fixture, [])),
    ExpectedEpochs = maybe_deep_binify(maps:get(<<"expected">>, Fixture, [])),
    ExpectedExactEpochs = maybe_deep_binify(maps:get(<<"expected_exact">>, Fixture, [])),

    {ok, Prog0} = gdbsp_parse:parse_string(Source, #{}),

    case maps:find(<<"expected_errors">>, Fixture) of
        {ok, ExpectedErrorsRaw} ->
            ExpectedErrors = deep_binify_vals(ExpectedErrorsRaw),
            run_negative(Prog0, Functions, ExpectedErrors);
        error ->
            EnsureMatchesIncr = maps:get(
                <<"ensure_matches_incremental">>, Fixture, false),
            case EnsureMatchesIncr of
                true ->
                    run_dual(Prog0, GroupName, Functions, InputEpochs,
                             ExpectedEpochs, ExpectedExactEpochs, Config);
                _ ->
                    run_positive(Prog0, GroupName, Functions, InputEpochs,
                                 ExpectedEpochs, ExpectedExactEpochs, Config)
            end
    end.

run_negative(Prog0, Functions, ExpectedErrors) ->
    try
        %% Use a dummy output name — we expect compilation to fail,
        %% so this placeholder never actually runs.
        compile_to_plan(Prog0, Functions, [<<"dummy">>], true),
        ct:fail("expected compilation to fail but it succeeded")
    catch
        Class:Reason:_Stacktrace ->
            Normalized = normalize_compile_error(Class, Reason),
            check_expected_errors(Normalized, ExpectedErrors)
    end.

normalize_compile_error(throw, {fixpoint_error, {_Line, Msg}}) ->
    #{<<"class">> => <<"fixpoint_error">>, <<"message">> => iolist_to_binary(Msg)};
normalize_compile_error(throw, {fixpoint_error, {_Line, Msg, _Args}}) ->
    #{<<"class">> => <<"fixpoint_error">>, <<"message">> => iolist_to_binary(Msg)};
normalize_compile_error(throw, {compile_error, _} = Reason) ->
    #{<<"class">> => <<"compile_error">>, <<"detail">> =>
          list_to_binary(io_lib:format("~p", [Reason]))};
normalize_compile_error(error, Reason) when is_map(Reason) ->
    Reason;
normalize_compile_error(_Class, Reason) ->
    #{<<"class">> => <<"unexpected_error">>,
      <<"detail">> => list_to_binary(io_lib:format("~p:~p", [_Class, Reason]))}.

check_expected_errors(_Actual, []) ->
    ok;
check_expected_errors(Actual, [Expected | Rest]) ->
    case error_subset_match(Expected, Actual) of
        ok -> check_expected_errors(Actual, Rest);
        {mismatch, Key, ExpVal, ActVal} ->
            ct:pal("Error mismatch at key ~p: expected ~p, got ~p",
                   [Key, ExpVal, ActVal]),
            error({error_mismatch, Key, ExpVal, ActVal})
    end.

error_subset_match(Expected, Actual) ->
    maps:fold(
        fun(Key, ExpVal, ok) ->
            case maps:find(Key, Actual) of
                {ok, ActVal} ->
                    case matches(Key, ExpVal, ActVal) of
                        true -> ok;
                        false -> {mismatch, Key, ExpVal, ActVal}
                    end;
                error ->
                    {mismatch, Key, ExpVal, missing}
            end;
           (_Key, _ExpVal, Acc) -> Acc
        end,
        ok,
        Expected).

matches(<<"message">>, Exp, Act) ->
    case binary:match(Act, Exp) of
        {_, _} -> true;
        nomatch -> false
    end;
matches(_Key, Exp, Act) when is_list(Exp), is_list(Act) ->
    lists:sort(Exp) =:= lists:sort(Act);
matches(_Key, Exp, Act) ->
    Exp =:= Act.

run_positive(Prog0, GroupName, Functions, InputEpochs, ExpectedEpochs, ExpectedExactEpochs, Config) ->
    {MatchMode, EpochExpected} = case {ExpectedEpochs, ExpectedExactEpochs} of
        {[], []} -> {subset, []};
        {[_ | _], []} -> {subset, ExpectedEpochs};
        {[], [_ | _]} -> {exact, ExpectedExactEpochs};
        {[_ | _], [_ | _]} ->
            ct:fail("cannot specify both 'expected' and 'expected_exact'")
    end,

    OutputNames = lists:usort(lists:flatmap(
        fun(Epoch) when is_map(Epoch) -> maps:keys(Epoch);
           (_) -> []
        end, EpochExpected)),

    %% Generate lowered graph DOT
    write_e2e_lowered_dot(Prog0, Functions, GroupName, Config),

    {Plan, SourceTypeMap, OutputTypes, Graph1} =
        compile_to_plan(Prog0, Functions, OutputNames, true),

    %% Generate circuit graph DOT
    write_dot_file("e2e", GroupName, "circuit",
                   gdbsp_graphviz:circuit_to_dot(Graph1), Config),

    SourceMap = spawn_inputs(SourceTypeMap),
    OutputCols = spawn_output_collectors(OutputNames),

    {ok, Circuit} = gdbsp_circuit_proc:start_link(),
    Inputs = maps:map(fun(_TableName, {InputPid, _Type}) -> InputPid end, SourceMap),
    Outputs = maps:map(fun(_Name, Col) -> gdbsp_test_collector_proc:pid(Col) end,
                       OutputCols),
    ok = gen_server:call(Circuit, {circuit_update, Plan, Inputs, Outputs}),

    try
        run_epochs(SourceMap, OutputCols, InputEpochs, EpochExpected,
                   OutputTypes, 0, MatchMode)
    after
        catch gen_server:call(Circuit, stop),
        maps:foreach(fun(_Name, Col) ->
            catch gdbsp_test_collector_proc:stop(Col)
        end, OutputCols)
    end.

%%====================================================================
%% Dual-run (incrementalization comparison)
%%====================================================================

run_dual(Prog0, GroupName, Functions, InputEpochs, ExpectedEpochs,
         ExpectedExactEpochs, Config) ->
    {MatchMode, EpochExpected} = case {ExpectedEpochs, ExpectedExactEpochs} of
        {[], []} -> {subset, []};
        {[_ | _], []} -> {subset, ExpectedEpochs};
        {[], [_ | _]} -> {exact, ExpectedExactEpochs};
        {[_ | _], [_ | _]} ->
            ct:fail("cannot specify both 'expected' and 'expected_exact'")
    end,

    OutputNames = lists:usort(lists:flatmap(
        fun(Epoch) when is_map(Epoch) -> maps:keys(Epoch);
           (_) -> []
        end, EpochExpected)),

    %% Generate lowered graph DOT once
    write_e2e_lowered_dot(Prog0, Functions, GroupName, Config),

    ct:pal("=== Dual-run: incrementalize=false ===", []),
    {GotNoIncr, OutputTypes} = run_one_incr_mode(Prog0, GroupName, Functions,
                                                  InputEpochs, OutputNames,
                                                  Config, false),

    ct:pal("=== Dual-run: incrementalize=true ===", []),
    {GotWithIncr, _} = run_one_incr_mode(Prog0, GroupName, Functions, InputEpochs,
                                          OutputNames, Config, true),

    ct:pal("=== Dual-run: comparing results ===", []),
    ok = compare_epoch_results(GotNoIncr, GotWithIncr),

    ct:pal("=== Dual-run: asserting against expected ===", []),
    ok = assert_epochs(GotNoIncr, EpochExpected, OutputTypes, MatchMode).

run_one_incr_mode(Prog0, GroupName, Functions, InputEpochs, OutputNames, Config, Incr) ->
    {Plan, SourceTypeMap, OutputTypes, Graph1} =
        compile_to_plan(Prog0, Functions, OutputNames, Incr),

    %% Generate circuit graph DOT for the incr=true run only
    write_dot_file("e2e", GroupName, "circuit",
                   gdbsp_graphviz:circuit_to_dot(Graph1), Config),

    SourceMap = spawn_inputs(SourceTypeMap),
    OutputCols = spawn_output_collectors(OutputNames),

    {ok, Circuit} = gdbsp_circuit_proc:start_link(),
    Inputs = maps:map(fun(_TableName, {InputPid, _Type}) -> InputPid end, SourceMap),
    Outputs = maps:map(fun(_Name, Col) -> gdbsp_test_collector_proc:pid(Col) end,
                       OutputCols),
    ok = gen_server:call(Circuit, {circuit_update, Plan, Inputs, Outputs}),

    try
        Results = run_epochs_collect(SourceMap, OutputCols, InputEpochs, 0),
        {Results, OutputTypes}
    after
        catch gen_server:call(Circuit, stop),
        maps:foreach(fun(_Name, Col) ->
            catch gdbsp_test_collector_proc:stop(Col)
        end, OutputCols)
    end.

%% Collect epoch deltas without asserting against expected.
%% Returns a list of maps: #{norm_row() => weight()}, one per epoch.
run_epochs_collect(_SourceMap, _OutputCols, [], _Epoch) ->
    [];
run_epochs_collect(SourceMap, OutputCols, [InputEpoch | InputRest], Epoch) ->
    send_epoch_deltas(InputEpoch, SourceMap, Epoch),
    send_epoch_done(SourceMap, Epoch),

    maps:foreach(fun(_Name, Col) ->
        gdbsp_test_collector_proc:await_done(Col, Epoch, 10000)
    end, OutputCols),

    AllGot = collect_and_consolidate(OutputCols, Epoch),
    ct:pal("EPOCH ~w got: ~p", [Epoch, AllGot]),
    [AllGot | run_epochs_collect(SourceMap, OutputCols, InputRest, Epoch + 1)].

%% Compare two result lists epoch by epoch.
compare_epoch_results(GotA, GotB) when length(GotA) =/= length(GotB) ->
    ct:fail("epoch count mismatch: incr=false has ~w epochs, incr=true has ~w",
            [length(GotA), length(GotB)]);
compare_epoch_results([], []) -> ok;
compare_epoch_results([AA | RA], [BB | RB]) ->
    Epoch = length(RA),
    Missing = maps:fold(
        fun(Row, W, Acc) ->
            case maps:find(Row, BB) of
                {ok, W} -> Acc;
                {ok, GotW} ->
                    [{incr_mismatch, {epoch, Epoch}, {row, Row},
                      {no_incr_weight, W}, {with_incr_weight, GotW}} | Acc];
                error ->
                    [{incr_missing_from_with, {epoch, Epoch}, {row, Row},
                      {weight, W}} | Acc]
            end
        end, [], AA),
    Extra = maps:fold(
        fun(Row, W, Acc) ->
            case maps:find(Row, AA) of
                {ok, _} -> Acc;
                error ->
                    [{incr_extra_in_with, {epoch, Epoch}, {row, Row},
                      {weight, W}} | Acc]
            end
        end, [], BB),
    case Missing ++ Extra of
        [] -> compare_epoch_results(RA, RB);
        Errors -> error({incremental_mismatch, Errors})
    end.

%% Assert collected results against expected.
assert_epochs([], [], _OutputTypes, _MatchMode) -> ok;
assert_epochs([], [_ | _], _OutputTypes, _MatchMode) ->
    ok;
assert_epochs([Got | GotRest], [ExpectedEpoch | ExpRest], OutputTypes, MatchMode) ->
    AllExpected = parse_expected_deltas(ExpectedEpoch, OutputTypes),
    Epoch = length(GotRest),
    case MatchMode of
        subset -> ok = subset_match(AllExpected, Got, Epoch);
        exact -> ok = exact_match(AllExpected, Got, Epoch)
    end,
    assert_epochs(GotRest, ExpRest, OutputTypes, MatchMode);
assert_epochs(_Got, [], _OutputTypes, _MatchMode) -> ok.

%%====================================================================
%% Compilation
%%====================================================================

compile_to_plan(Prog0, Functions, OutputNames, Incr) ->
    SourceTypeMap = build_source_type_map(Prog0),

    case gdbsp_compile:compile_with_names(
           Prog0, #{fn_registry => Functions, incrementalize => false}) of
        {ok, Graph0, NameToId} ->
            Graph1 = add_output_nodes(Graph0, OutputNames, NameToId),
            OutTypes = output_types_from_graph(Graph1, NameToId,
                                                OutputNames, SourceTypeMap),
            Graph2 = case Incr of
                true  -> gdbsp_compile_incremental:run(Graph1);
                false -> Graph1
            end,
            Plan = gdbsp_deploy:plan(Graph2),
            {Plan, SourceTypeMap, OutTypes, Graph1};
        {error, {fixpoint_error, _} = FixErr} ->
            throw(FixErr);
        {error, Reason} ->
            throw({compile_error, Reason})
    end.

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
                    ct:pal("WARNING: output node ~p not found in graph", [OutName]),
                    {GAcc, AccNextId}
            end
        end,
        {Graph, NextId0},
        OutputNames
    ),
    G.

%%====================================================================
%% Input / output wiring
%%====================================================================

spawn_inputs(SourceTypeMap) ->
    maps:map(fun(_TableName, {_NodeName, Type}) ->
        {ok, Pid} = gdbsp_test_input_node:start_link(),
        {Pid, Type}
    end, SourceTypeMap).

spawn_output_collectors(OutputNames) ->
    maps:from_list([
        {Name, gdbsp_test_collector_proc:start()}
        || Name <- OutputNames
    ]).

%%====================================================================
%% Epoch execution
%%====================================================================

run_epochs(_SourceMap, _OutputCols, [], [], _OutputTypes, _Epoch, _MatchMode) ->
    ok;
run_epochs(_SourceMap, _OutputCols,
           [], [_ExpectedEpoch | _ExpectedRest],
           _OutputTypes, Epoch, _MatchMode) ->
    ct:fail("expected output for epoch ~w but input exhausted", [Epoch]);
run_epochs(SourceMap, OutputCols,
           [InputEpoch | InputRest], [ExpectedEpoch | ExpectedRest],
           OutputTypes, Epoch, MatchMode) ->
    send_epoch_deltas(InputEpoch, SourceMap, Epoch),
    send_epoch_done(SourceMap, Epoch),

    maps:foreach(fun(_Name, Col) ->
        gdbsp_test_collector_proc:await_done(Col, Epoch, 10000)
    end, OutputCols),

    AllGot = collect_and_consolidate(OutputCols, Epoch),
    AllExpected = parse_expected_deltas(ExpectedEpoch, OutputTypes),

    ct:pal("EPOCH ~w got: ~p", [Epoch, AllGot]),
    ct:pal("EPOCH ~w expected: ~p", [Epoch, AllExpected]),

    case MatchMode of
        subset -> ok = subset_match(AllExpected, AllGot, Epoch);
        exact -> ok = exact_match(AllExpected, AllGot, Epoch)
    end,

    run_epochs(SourceMap, OutputCols, InputRest, ExpectedRest,
               OutputTypes, Epoch + 1, MatchMode);
run_epochs(_SourceMap, _OutputCols,
           [_InputEpoch | _InputRest], [], _OutputTypes, _Epoch, _MatchMode) ->
    ok.

%%--------------------------------------------------------------------
%% Sending deltas
%%--------------------------------------------------------------------

send_epoch_deltas(EpochMap, SourceMap, Epoch) ->
    maps:foreach(fun(TableName, Rows) ->
        case maps:find(TableName, SourceMap) of
            {ok, {InputPid, Type}} ->
                TypedRows = [convert_input_row(Row, Type) || Row <- Rows],
                InputPid ! {delta, #{epoch => Epoch}, TypedRows, self()};
            error ->
                ct:fail("unknown source table: ~p", [TableName])
        end
    end, EpochMap).

send_epoch_done(SourceMap, Epoch) ->
    maps:foreach(fun(_TableName, {InputPid, _Type}) ->
        InputPid ! {delta, #{epoch => Epoch, barrier => epoch_done}, [], self()}
    end, SourceMap).

convert_input_row([W, RowMap], Type) ->
    {ok, Decoded} = gdbsp_value_json:decode_row(Type, RowMap),
    StructRow = gdbsp_struct:map_to_struct(Decoded, Type),
    {W, StructRow}.

%%--------------------------------------------------------------------
%% Collecting and consolidating
%%--------------------------------------------------------------------

collect_and_consolidate(OutputCols, Epoch) ->
    AllDeltas = maps:fold(
        fun(Name, Col, Acc) ->
            Deltas = gdbsp_test_collector_proc:get_by_epoch(Col, Epoch),
            ct:pal("EPOCH ~w ~s deltas: ~p", [Epoch, Name, Deltas]),
            Acc ++ Deltas
        end, [], OutputCols),
    ct:pal("EPOCH ~w aggregated: ~p", [Epoch, AllDeltas]),
    lists:foldl(
        fun({W, Row}, Acc) ->
            Norm = norm_row(Row),
            OldW = maps:get(Norm, Acc, 0),
            case OldW + W of
                0 -> maps:remove(Norm, Acc);
                NewW -> Acc#{Norm => NewW}
            end
        end, #{}, AllDeltas).

parse_expected_deltas([], _OutputTypes) -> #{};
parse_expected_deltas(EpochMap, OutputTypes) when is_map(EpochMap) ->
    maps:fold(
        fun(OutName, Rows, Acc) ->
            OutType = maps:get(OutName, OutputTypes, dynamic),
            lists:foldl(
                fun([W, RowMap], Acc2) ->
                    {ok, Decoded} = gdbsp_value_json:decode_row(OutType, RowMap),
                    Norm = norm_row(Decoded),
                    OldW = maps:get(Norm, Acc2, 0),
                    NewW = OldW + W,
                    case NewW of
                        0 -> maps:remove(Norm, Acc2);
                        _ -> Acc2#{Norm => NewW}
                    end
                end, Acc, Rows)
        end, #{}, EpochMap).

%%--------------------------------------------------------------------
%% Subset match
%%--------------------------------------------------------------------

subset_match(Expected, Got, Epoch) ->
    Missing = maps:fold(
        fun(Row, W, Acc) ->
            case maps:find(Row, Got) of
                {ok, W} -> Acc;
                {ok, GotW} ->
                    [{weight_mismatch, {epoch, Epoch}, {row, Row},
                      {expected, W}, {got, GotW}} | Acc];
                error ->
                    [{missing, {epoch, Epoch}, {row, Row},
                      {expected, W}} | Acc]
            end
        end, [], Expected),
    case Missing of
        [] -> ok;
        _ -> error({subset_match_failed, Missing})
    end.

exact_match(Expected, Got, Epoch) ->
    Missing = maps:fold(
        fun(Row, W, Acc) ->
            case maps:find(Row, Got) of
                {ok, W} -> Acc;
                {ok, GotW} ->
                    [{weight_mismatch, {epoch, Epoch}, {row, Row},
                      {expected, W}, {got, GotW}} | Acc];
                error ->
                    [{missing, {epoch, Epoch}, {row, Row},
                      {expected, W}} | Acc]
            end
        end, [], Expected),
    Extra = maps:fold(
        fun(Row, GotW, Acc) ->
            case maps:find(Row, Expected) of
                {ok, _} -> Acc;
                error -> [{extra, {epoch, Epoch}, {row, Row},
                           {got, GotW}} | Acc]
            end
        end, [], Got),
    case Missing ++ Extra of
        [] -> ok;
        Errors -> error({exact_match_failed, Errors})
    end.

%%--------------------------------------------------------------------
%% Row normalization
%%--------------------------------------------------------------------

norm_row({value, _, _} = Val) ->
    norm_row(gdbsp_struct:struct_to_map(Val));
norm_row(Row) when is_map(Row) ->
    maps:fold(fun(K, V, Acc) ->
        Acc#{norm_val(K) => norm_val(V)}
    end, #{}, Row);
norm_row(Row) -> Row.

norm_val({value, _, V}) -> norm_val(V);
norm_val({value, V}) -> norm_val(V);
norm_val(null) -> <<"absent">>;
norm_val(absent) -> <<"absent">>;
norm_val(V) when is_binary(V) -> V;
norm_val(V) when is_atom(V) -> atom_to_binary(V, utf8);
norm_val(V) when is_list(V) -> list_to_binary(V);
norm_val(V) -> V.

%%====================================================================
%% YAML → Erlang conversion
%%====================================================================

to_map([]) -> [];
to_map([{_, _} | _] = M) ->
    maps:from_list([{to_bin(K), to_map_val(V)} || {K, V} <- M]);
to_map([H | T]) -> [to_map(H) | to_map(T)];
to_map(V) -> V.

to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> list_to_binary(V).

to_map_val(V) when is_list(V) -> to_map(V);
to_map_val(V) -> V.

%%====================================================================
%% DOT file generation
%%====================================================================

write_e2e_lowered_dot(Prog0, Functions, GroupName, Config) ->
    {ok, StdlibMap} = gdbsp_compile:load_stdlib(),
    TSMap = e2e_build_ts_map(Prog0#gdbsp_program.typespecs),
    case gdbsp_compile_lower:run(Prog0, #{}) of
        {ok, Lowered0} ->
            case gdbsp_type_infer:infer_lowered(Lowered0, TSMap, Functions, StdlibMap) of
                {ok, Lowered} ->
                    write_dot_file("e2e", GroupName, "lowered",
                                   gdbsp_graphviz:lowered_to_dot(Lowered),
                                   Config);
                {error, _Err} ->
                    ok
            end;
        {error, _Err} ->
            ok
    end.

write_dot_file(Suite, GroupName, Kind, Dot, _Config) ->
    NameStr = atom_to_list(GroupName),
    Family = extract_family(NameStr),
    FileName = NameStr ++ "." ++ Kind ++ ".dot",
    SubDir = filename:join([Suite, Family]),
    Dir = filename:join([project_root(), "test_suite_graphs", SubDir]),
    ok = filelib:ensure_dir(filename:join(Dir, "_")),
    Path = filename:join(Dir, FileName),
    ok = file:write_file(Path, lists:flatten(Dot)),
    ct:pal("Wrote DOT: ~s", [Path]),
    maybe_render_png(Path).

extract_family(NameStr) ->
    case string:rchr(NameStr, $_) of
        0 -> NameStr;
        Pos ->
            Suffix = string:substr(NameStr, Pos + 1),
            case is_digits(Suffix) of
                true -> string:substr(NameStr, 1, Pos - 1);
                false -> NameStr
            end
    end.

is_digits([]) -> true;
is_digits([C | Rest]) when C >= $0, C =< $9 -> is_digits(Rest);
is_digits(_) -> false.

maybe_render_png(DotPath) ->
    case os:getenv("RENDER_DOT") of
        false -> ok;
        _ ->
            PngPath = filename:rootname(DotPath) ++ ".png",
            Cmd = lists:flatten(["dot -Tpng \"", DotPath, "\" -o \"", PngPath, "\""]),
            try os:cmd(Cmd) of
                _ -> ct:pal("Rendered PNG: ~s", [PngPath])
            catch
                _:_ -> ct:pal("PNG render failed (dot not installed?): ~s", [DotPath])
            end
    end.

project_root() ->
    lists:foldl(fun(_, Acc) -> filename:dirname(Acc) end,
                code:lib_dir(grasp_dbsp), [1,2,3,4]).

e2e_build_ts_map(Typespecs) ->
    lists:foldl(
        fun(#gdbsp_typespec{name = N, spec = {type, {stream, Inner}}}, Acc) ->
                Acc#{N => Inner};
           (#gdbsp_typespec{name = N, spec = {type, T}}, Acc) ->
                Acc#{N => T};
           (_TS, Acc) ->
                Acc
        end, #{}, Typespecs).
