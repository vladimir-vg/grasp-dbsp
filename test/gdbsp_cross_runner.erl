%%%-------------------------------------------------------------------
%%% @doc Cross-implementation test runner — SQLite vs grasp-dbsp.
%%%
%%% Each test scenario compares the output of a SQLite query against
%%% the equivalent grasp-dbsp circuit. Input data is supplied as .jsonl
%%% files (type header + rows in gdbsp value encoding). Expected output
%%% is also .jsonl.
%%%
%%% Output naming convention:
%%%   <name>_set.expected.jsonl → order-independent comparison
%%%   <name>_seq.expected.jsonl → exact-order comparison
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_cross_runner).

-include("gdbsp_parse.hrl").
-include("gdbsp_circuit.hrl").
-include("gdbsp_type.hrl").

-export([run_scenario/4]).

%%====================================================================
%% API
%%====================================================================

-spec run_scenario(
    TestDir     :: file:filename_all(),
    Scenario    :: file:filename_all(),
    SqlContent  :: binary(),
    GdbspContent :: binary()
) -> ok | no_return().
run_scenario(TestDir, Scenario, SqlContent, GdbspContent) ->
    ScenarioDir = filename:join(TestDir, Scenario),
    {InputData, ExpectedInfo} = discover_and_read_files(ScenarioDir),
    ct:pal("Scenario ~s: inputs=~p, expected=~p",
           [Scenario, maps:keys(InputData),
            [{N, M} || {N, M, _} <- ExpectedInfo]]),

    {ok, Prog} = gdbsp_parse:parse_string(GdbspContent, #{}),
    validate_gdbsp_sources(Prog, InputData),
    validate_gdbsp_outputs(Prog, ExpectedInfo),

    SqlResults = run_sql(SqlContent, InputData, ExpectedInfo),
    GdbspResults = run_gdbsp(Prog, InputData, ExpectedInfo),

    lists:foreach(fun({Name, Mode, {TypeHeader, ExpectedRows}}) ->
        SqlRows = maps:get(Name, SqlResults, []),
        GdbspRows = maps:get(Name, GdbspResults, []),
        compare_output(Name, Mode, TypeHeader, ExpectedRows,
                       SqlRows, GdbspRows)
    end, ExpectedInfo),
    ok.

%%====================================================================
%% File discovery
%%====================================================================

discover_and_read_files(ScenarioDir) ->
    {ok, Files} = file:list_dir(ScenarioDir),
    InputFiles = [F || F <- Files,
        lists:suffix(".input.jsonl", F)],
    ExpectedFiles = [F || F <- Files,
        lists:suffix(".expected.jsonl", F)],

    InputData = lists:foldl(fun(F, Acc) ->
        SourceName = input_source_name(F),
        FullPath = filename:join(ScenarioDir, F),
        {TypeHeader, Rows} = read_jsonl_file(FullPath),
        Acc#{SourceName => {TypeHeader, Rows}}
    end, #{}, InputFiles),

    ExpectedInfo = lists:map(fun(F) ->
        {Name, Mode} = parse_output_name(F),
        FullPath = filename:join(ScenarioDir, F),
        {Name, Mode, read_jsonl_file(FullPath)}
    end, ExpectedFiles),

    {InputData, ExpectedInfo}.

input_source_name(Filename) ->
    list_to_binary(filename:basename(Filename, ".input.jsonl")).

parse_output_name(Filename) ->
    Base = filename:basename(Filename, ".expected.jsonl"),
    parse_output_suffix(Base).

parse_output_suffix(Base) when is_list(Base) ->
    case lists:suffix("_set", Base) of
        true ->
            {list_to_binary(Base), set};
        false ->
            case lists:suffix("_seq", Base) of
                true ->
                    {list_to_binary(Base), seq};
                false ->
                    error({invalid_output_name, Base})
            end
    end.

%%====================================================================
%% JSONL reading
%%====================================================================

read_jsonl_file(Path) ->
    {ok, Content} = file:read_file(Path),
    Lines = [L || L <- binary:split(Content, <<"\n">>, [global, trim]),
                  L =/= <<>>],
    case Lines of
        [] -> error({empty_file, Path});
        [HeaderLine | DataLines] ->
            TypeHeader = case jsx:decode(HeaderLine, [return_maps]) of
                H when is_map(H) -> H;
                _ -> error({invalid_type_header, Path})
            end,
            Rows = [case jsx:decode(L, [return_maps]) of
                        R when is_map(R) -> R;
                        _ -> error({invalid_row, Path, L})
                    end || L <- DataLines],
            {TypeHeader, Rows}
    end.

%%====================================================================
%% Validation
%%====================================================================

validate_gdbsp_sources(Prog, InputData) ->
    SourceTypes = build_source_type_map(Prog),
    maps:foreach(fun(SrcName, {_NodeName, _Type}) ->
        case maps:is_key(SrcName, InputData) of
            true -> ok;
            false -> error({missing_input_file_for_source, SrcName})
        end
    end, SourceTypes).

validate_gdbsp_outputs(Prog, ExpectedInfo) ->
    NodeNames = [N || #gdbsp_node_def{name = N}
                      <- Prog#gdbsp_program.nodes],
    lists:foreach(fun({OutName, _Mode, _}) ->
        case lists:member(OutName, NodeNames) of
            true -> ok;
            false -> error({output_node_not_found_in_gdbsp, OutName})
        end
    end, ExpectedInfo).

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
%% SQLite execution
%%====================================================================

run_sql(SqlContent, InputData, ExpectedInfo) ->
    {ok, Conn} = esqlite3:open(":memory:"),
    try
        ok = execute_sql_file(Conn, SqlContent),
        insert_input_data(Conn, InputData),
        OutputNames = lists:usort([N || {N, _, _} <- ExpectedInfo]),
        lists:foldl(fun(OutName, Acc) ->
            Rows = select_view_rows(Conn, OutName),
            Acc#{OutName => Rows}
        end, #{}, OutputNames)
    after
        esqlite3:close(Conn)
    end.

execute_sql_file(Conn, SqlContent) ->
    Stmts = split_sql_statements(SqlContent),
    lists:foreach(fun(Stmt) ->
        ok = esqlite3:exec(Conn, Stmt)
    end, Stmts).

split_sql_statements(<<>>) -> [];
split_sql_statements(Sql) ->
    Parts = binary:split(Sql, <<";">>, [global]),
    [string:trim(P) || P <- Parts, string:trim(P) =/= <<>>].

insert_input_data(Conn, InputData) ->
    maps:foreach(fun(TableName, {TypeHeader, Rows}) ->
        insert_rows(Conn, TableName, TypeHeader, Rows)
    end, InputData).

insert_rows(_Conn, _TableName, _TypeHeader, []) ->
    ok;
insert_rows(Conn, TableName, TypeHeader, [_First | _] = Rows) ->
    RowType = json_header_to_struct_type(TypeHeader),
    ColNames = maps:keys(TypeHeader),
    ColList = bin_join(ColNames, <<", ">>),
    lists:foreach(fun(RowMap) ->
        {ok, Decoded} = gdbsp_value_json:decode_row(RowType, RowMap),
        ValueLiterals = [raw_to_sql_literal(maps:get(Col, Decoded))
                          || Col <- ColNames],
        ValList = bin_join(ValueLiterals, <<", ">>),
        Sql = <<"INSERT INTO ", TableName/binary,
                " (", ColList/binary, ") VALUES (", ValList/binary, ")">>,
        ok = esqlite3:exec(Conn, Sql)
    end, Rows).

json_header_to_struct_type(Header) ->
    Fields = maps:fold(fun(Col, TypeJson, Acc) ->
        {ok, T} = gdbsp_type:parse_type(TypeJson),
        Acc#{Col => T}
    end, #{}, Header),
    {struct, Fields, exact}.

raw_to_sql_literal(V) when is_integer(V) -> integer_to_binary(V);
raw_to_sql_literal(V) when is_float(V) -> float_to_binary(V, [short]);
raw_to_sql_literal(V) when is_binary(V) ->
    Escaped = escape_sql_string(V),
    <<"'", Escaped/binary, "'">>;
raw_to_sql_literal(null) -> <<"NULL">>;
raw_to_sql_literal(absent) -> <<"NULL">>;
raw_to_sql_literal({value, _, Inner}) -> raw_to_sql_literal(Inner);
raw_to_sql_literal(V) when is_tuple(V) ->
    Encoded = jsx:encode(V),
    Escaped = escape_sql_string(Encoded),
    <<"'", Escaped/binary, "'">>;
raw_to_sql_literal(V) when is_list(V) ->
    Encoded = jsx:encode(V),
    Escaped = escape_sql_string(Encoded),
    <<"'", Escaped/binary, "'">>;
raw_to_sql_literal(V) when is_map(V) ->
    Encoded = jsx:encode(V),
    Escaped = escape_sql_string(Encoded),
    <<"'", Escaped/binary, "'">>;
raw_to_sql_literal(V) ->
    Encoded = iolist_to_binary(io_lib:format("~p", [V])),
    Escaped = escape_sql_string(Encoded),
    <<"'", Escaped/binary, "'">>.

escape_sql_string(Bin) ->
    %% SQL single-quote escaping: '' for each '
    binary:replace(Bin, <<"'">>, <<"''">>, [global]).

select_view_rows(Conn, ViewName) ->
    Sql = <<"SELECT * FROM ", ViewName/binary>>,
    case esqlite3:prepare(Conn, Sql) of
        {ok, Stmt} ->
            ColNames = esqlite3:column_names(Stmt),
            Rows = esqlite3:fetchall(Stmt),
            ok = esqlite3:reset(Stmt),
            lists:map(fun(Row) ->
                maps:from_list(lists:zip(ColNames, Row))
            end, Rows);
        {error, _} = Err ->
            error({sql_view_error, ViewName, Err})
    end.

%%====================================================================
%% GDBSP execution
%%====================================================================

run_gdbsp(Prog, InputData, ExpectedInfo) ->
    OutputNames = lists:usort([N || {N, _, _} <- ExpectedInfo]),
    SourceTypeMap = build_source_type_map(Prog),
    SourceTypes = maps:fold(fun(K, {_N, T}, Acc) ->
        Acc#{K => T}
    end, #{}, SourceTypeMap),

    {Plan, _SourceMapFromPlan, _OutputTypes} =
        compile_to_plan(Prog, OutputNames),

    SourceMap = spawn_inputs(SourceTypes),
    OutputCols = spawn_output_collectors(OutputNames),

    {ok, Circuit} = gdbsp_circuit_proc:start_link(),
    InputPids = maps:map(fun(_TableName, {InputPid, _Type}) -> InputPid end,
                         SourceMap),
    OutputPids = maps:map(fun(_Name, Col) ->
        gdbsp_test_collector_proc:pid(Col)
    end, OutputCols),
    ok = gen_server:call(Circuit, {circuit_update, Plan, InputPids, OutputPids}),

    try
        Epoch = 0,
        send_all_inputs(InputData, SourceMap, SourceTypes, Epoch),
        send_epoch_done(SourceMap, Epoch),

        maps:foreach(fun(_Name, Col) ->
            gdbsp_test_collector_proc:await_done(Col, Epoch, 30000)
        end, OutputCols),

        AllDeltas = maps:fold(fun(Name, Col, Acc) ->
            Ds = gdbsp_test_collector_proc:get_by_epoch(Col, Epoch),
            [{Name, Ds} | Acc]
        end, [], OutputCols),

        lists:foldl(fun({Name, Deltas}, Acc) ->
            Rows = consolidate_and_expand(Deltas, Name),
            Expanded = expand_weighted(Rows),
            Acc#{Name => Expanded}
        end, #{}, AllDeltas)
    after
        catch gen_server:call(Circuit, stop),
        maps:foreach(fun(_Name, Col) ->
            catch gdbsp_test_collector_proc:stop(Col)
        end, OutputCols)
    end.

compile_to_plan(Prog, OutputNames) ->
    case gdbsp_compile:compile_with_names(
           Prog, #{incrementalize => false}) of
        {ok, Graph0, NameToId} ->
            Graph1 = add_output_nodes(Graph0, OutputNames, NameToId),
            SourceTypeMap = build_source_type_map(Prog),
            OutTypes = maps:fold(fun(OutName, _NodeId, Acc) ->
                Acc#{OutName => dynamic}
            end, #{}, maps:with(OutputNames, NameToId)),
            Plan = gdbsp_deploy:plan(Graph1),
            {Plan, SourceTypeMap, OutTypes};
        {error, Reason} ->
            error({compile_error, Reason})
    end.

add_output_nodes(Graph, OutputNames, NameToId) ->
    #circuit_graph{next_id = NextId0} = Graph,
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
                    OutSchema = maps:get(NodeId,
                        GAcc#circuit_graph.schemas, []),
                    GAcc2 = GAcc#circuit_graph{
                        nodes = maps:put(AccNextId, OutputNode,
                                         GAcc#circuit_graph.nodes),
                        schemas = maps:put(AccNextId, OutSchema,
                                           GAcc#circuit_graph.schemas),
                        next_id = AccNextId + 1
                    },
                    {GAcc2, AccNextId + 1};
                error ->
                    error({output_not_found_in_graph, OutName})
            end
        end,
        {Graph, NextId0},
        OutputNames
    ),
    G.

spawn_inputs(SourceTypes) ->
    maps:map(fun(_TableName, Type) ->
        {ok, Pid} = gdbsp_test_input_node:start_link(),
        {Pid, Type}
    end, SourceTypes).

spawn_output_collectors(OutputNames) ->
    maps:from_list([
        {Name, gdbsp_test_collector_proc:start()}
        || Name <- OutputNames
    ]).

send_all_inputs(InputData, SourceMap, _SourceTypes, Epoch) ->
    maps:foreach(fun(TableName, {_TypeHeader, Rows}) ->
        case maps:find(TableName, SourceMap) of
            {ok, {InputPid, Type}} ->
                TypedRows = lists:map(fun(Row) ->
                    convert_input_row(Row, Type)
                end, Rows),
                InputPid ! {delta, #{epoch => Epoch}, TypedRows, self()};
            error ->
                ok
        end
    end, InputData).

convert_input_row(RowMap, Type) ->
    {ok, Decoded} = gdbsp_value_json:decode_row(Type, RowMap),
    StructRow = gdbsp_struct:map_to_struct(Decoded, Type),
    {1, StructRow}.

send_epoch_done(SourceMap, Epoch) ->
    maps:foreach(fun(_TableName, {InputPid, _Type}) ->
        InputPid ! {delta,
                    #{epoch => Epoch, barrier => epoch_done},
                    [], self()}
    end, SourceMap).

consolidate_and_expand(Deltas, OutputName) ->
    consolidate_ordered(Deltas, [], OutputName).

consolidate_ordered([], Acc, _OutputName) ->
    lists:reverse(Acc);
consolidate_ordered([{W, StructRow} | Rest], Acc, OutputName) ->
    Norm = row_to_cmp_map(StructRow),
    case lists:keyfind(Norm, 1, Acc) of
        false when W =:= 1 ->
            consolidate_ordered(Rest, [{Norm, 1} | Acc], OutputName);
        {Norm, OldW} ->
            NewW = OldW + W,
            NewAcc = lists:keyreplace(Norm, 1, Acc, {Norm, NewW}),
            consolidate_ordered(Rest, NewAcc, OutputName);
        false when W > 1 ->
            ct:pal("Warning: weight ~p > 1 for ~s row ~p", [W, OutputName, Norm]),
            consolidate_ordered(Rest, [{Norm, W} | Acc], OutputName);
        false when W =< 0 ->
            error({negative_weight, OutputName, Norm, W})
    end.

expand_weighted(Pairs) ->
    lists:flatmap(fun({Row, W}) ->
        lists:duplicate(W, Row)
    end, Pairs).

row_to_cmp_map(StructRow) ->
    Map = gdbsp_struct:struct_to_map(StructRow),
    maps:map(fun(_K, V) -> native_value(V) end, Map).

native_value({value, _, V}) -> native_value(V);
native_value(V) -> V.

%%====================================================================
%% Comparison
%%====================================================================

compare_output(Name, Mode, TypeHeader, ExpectedRows,
               SqlRows, GdbspRows) ->
    ct:pal("Comparing output ~s (~s): expected=~w, sql=~w, gdbsp=~w",
           [Name, Mode, length(ExpectedRows),
            length(SqlRows), length(GdbspRows)]),

    ExpectedDecoded = decode_expected_rows(TypeHeader, ExpectedRows),
    SqlNormalized = normalize_sql_rows(SqlRows, TypeHeader),
    GdbspNormalized = GdbspRows,

    case Mode of
        set ->
            ExpSorted = canonical_sort(ExpectedDecoded),
            SqlSorted = canonical_sort(SqlNormalized),
            GdbspSorted = canonical_sort(GdbspNormalized),
            assert_list_equal("expected", ExpSorted, SqlSorted, Name),
            assert_list_equal("gdbsp", GdbspSorted, SqlSorted, Name);
        seq ->
            assert_list_equal("expected", ExpectedDecoded,
                              SqlNormalized, Name),
            assert_list_equal("gdbsp", GdbspNormalized,
                              SqlNormalized, Name)
    end.

decode_expected_rows(TypeHeader, Rows) ->
    RowType = json_header_to_struct_type(TypeHeader),
    lists:map(fun(Row) ->
        {ok, Decoded} = gdbsp_value_json:decode_row(RowType, Row),
        maps:map(fun(_K, V) -> native_value(V) end, Decoded)
    end, Rows).

normalize_sql_rows(Rows, TypeHeader) ->
    RowType = json_header_to_struct_type(TypeHeader),
    lists:map(fun(Row) ->
        maps:map(fun(Col, Val) ->
            normalize_sql_value(Col, Val, RowType)
        end, Row)
    end, Rows).

normalize_sql_value(Col, Val, {struct, Fields, _}) ->
    case maps:find(Col, Fields) of
        {ok, FieldType} ->
            sql_val_to_native(FieldType, Val);
        error ->
            Val
    end.

sql_val_to_native(T, V) when T =:= i8; T =:= i16; T =:= i32;
                             T =:= i64; T =:= integer;
                             T =:= u8; T =:= u16; T =:= u32;
                             T =:= u64 ->
    V;
sql_val_to_native(string, V) -> V;
sql_val_to_native({string, _Encoding}, V) -> V;
sql_val_to_native(T, V) when T =:= f32; T =:= f64 ->
    V;
sql_val_to_native(T, V) when T =:= string;
                             is_tuple(T), element(1, T) =:= string ->
    V;
sql_val_to_native(numeric, V) when is_binary(V) ->
    string_to_numeric(V);
sql_val_to_native(date, V) when is_binary(V) ->
    parse_date_string(V);
sql_val_to_native(time, V) when is_binary(V) ->
    parse_time_string(V);
sql_val_to_native(timestamp, V) when is_binary(V) ->
    parse_timestamp_string(V);
sql_val_to_native(timestamp_with_timezone, V) when is_binary(V) ->
    parse_timestamp_string(V);
sql_val_to_native(interval, V) when is_binary(V) ->
    parse_interval_string(V);
sql_val_to_native(_T, V) ->
    V.

string_to_numeric(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<".">>) of
        [IntBin] ->
            {binary_to_integer(IntBin), 0};
        [IntBin, DecBin] ->
            Sign = case IntBin of
                <<"-", Rest/binary>> -> {negative, Rest};
                _ -> {positive, IntBin}
            end,
            {Polarity, AbsInt} = Sign,
            AbsCoeff = binary_to_integer(
                <<AbsInt/binary, DecBin/binary>>),
            case Polarity of
                negative -> {-AbsCoeff, byte_size(DecBin)};
                positive -> {AbsCoeff, byte_size(DecBin)}
            end
    end;

string_to_numeric(N) when is_number(N) ->
    {trunc(N * 10000000000000000), 16}.

parse_date_string(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<"-">>, [global]) of
        [Y, M, D] ->
            calendar:date_to_gregorian_days({b2i(Y), b2i(M), b2i(D)})
                - calendar:date_to_gregorian_days({2000, 1, 1});
        _ -> Bin
    end.

parse_time_string(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<":">>, [global]) of
        [H, M, S] ->
            case binary:split(S, <<".">>) of
                [Sec, Us] ->
                    {b2i(H), b2i(M), b2i(Sec),
                     trunc(b2f(Us) * 1000000)};
                _ ->
                    {b2i(H), b2i(M), b2i(S), 0}
            end;
        _ -> Bin
    end.

parse_timestamp_string(Bin) when is_binary(Bin) ->
    try
        String = binary_to_list(Bin),
        case calendar:rfc3339_to_system_time(
               String, [{unit, microsecond}]) of
            Us when is_integer(Us) -> Us;
            _ -> Bin
        end
    catch _:_ ->
        Bin
    end.

parse_interval_string(Bin) when is_binary(Bin) ->
    {0, 0, 0}.

b2i(B) -> binary_to_integer(B).

b2f(B) -> binary_to_float(B).

canonical_sort(Rows) ->
    lists:sort(fun(A, B) ->
        AK = io_lib:format("~tp", [maps:to_list(A)]),
        BK = io_lib:format("~tp", [maps:to_list(B)]),
        AK =< BK
    end, Rows).

assert_list_equal(Label, Expected, Actual, Name) ->
    LenExp = length(Expected),
    LenAct = length(Actual),
    if
        LenExp =/= LenAct ->
            ct:pal("~s length mismatch for ~s: expected ~p, got ~p",
                   [Label, Name, LenExp, LenAct]),
            error({length_mismatch, Label, Name, LenExp, LenAct});
        true ->
            lists:foreach(fun({E, ACTUAL}) ->
                case E =:= ACTUAL of
                    true -> ok;
                    false ->
                        ct:pal("~s row mismatch for ~s:", [Label, Name]),
                        ct:pal("  expected: ~p", [E]),
                        ct:pal("  actual:   ~p", [ACTUAL]),
                        error({row_mismatch, Label, Name, E, ACTUAL})
                end
            end, lists:zip(Expected, Actual)),
            ok
    end.

%%====================================================================
%% Helpers
%%====================================================================

bin_join([], _Sep) -> <<>>;
bin_join([H], _Sep) -> H;
bin_join([H | T], Sep) ->
    <<H/binary, Sep/binary, (bin_join(T, Sep))/binary>>.
