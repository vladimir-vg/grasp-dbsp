%%%-------------------------------------------------------------------
%%% @doc Type inference test suite — YAML fixture-driven.
%%%
%%% Each YAML file in gdbsp_type_infer_SUITE_data/ contains a list of
%%% test cases. Each case provides .gdbsp source, optional function
%%% definitions, and expected types for tagged node names.
%%%
%%% Type inference runs on the lowered graph (after lowering).
%%% Assertions use tag names which correspond to original source
%%% node names for regular nodes.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_type_infer_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_parse.hrl").
-include("gdbsp_lowered.hrl").
-include("gdbsp_type.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([fixture_test/1]).

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
        filename:dirname(code:which(?MODULE)), "gdbsp_type_infer_SUITE_data").

load_yaml_file(Path) ->
    try
        [YamlDoc] = yamerl_constr:file(Path),
        to_map(YamlDoc)
    catch
        C:E ->
            ct:log("Failed to load YAML file ~s: ~p:~p", [Path, C, E]),
            []
    end.

group_name(YamlPath) ->
    D = yaml_data_dir(),
    Rel = lists:nthtail(length(D) + 1, YamlPath),
    Parts = string:tokens(filename:rootname(Rel), "/"),
    list_to_atom(string:join(Parts, "_")).

%%====================================================================
%% YAML helpers
%%====================================================================

to_map(L) when is_list(L) -> L;
to_map(V) -> V.

maybe_to_bin(V) when is_list(V) -> list_to_binary(V);
maybe_to_bin(V) when is_binary(V) -> V;
maybe_to_bin(V) -> V.

deep_binify_vals(V) when is_map(V) ->
    maps:fold(fun(K, Val, Acc) ->
        Acc#{K => deep_binify_vals(Val)}
    end, #{}, V);
deep_binify_vals(V) when is_list(V) ->
    case is_char_list(V) of
        true -> list_to_binary(V);
        false ->
            case is_proplist(V) of
                true -> maps:from_list([deep_binify_vals(E) || E <- V]);
                false -> [deep_binify_vals(E) || E <- V]
            end
    end;
deep_binify_vals({K, V}) -> {deep_binify_vals(K), deep_binify_vals(V)};
deep_binify_vals(V) -> V.

is_proplist([{K, _} | _]) when is_list(K); is_binary(K) -> true;
is_proplist(_) -> false.

is_char_list([]) -> true;
is_char_list([H | T]) when is_integer(H), H >= 0, H =< 255 ->
    is_char_list(T);
is_char_list(_) -> false.

%%====================================================================
%% Test runner
%%====================================================================

fixture_test(Config) ->
    GroupName = proplists:get_value(name, ?config(tc_group_properties, Config)),
    [Fixture] = persistent_term:get({?MODULE, GroupName}),
    run_one_fixture(Fixture, GroupName, Config).

run_one_fixture(Fixture, GroupName, Config) ->
    FixtureMap = deep_binify_vals(Fixture),
    Source = maybe_to_bin(maps:get(<<"source">>, FixtureMap)),
    Functions = maps:get(<<"functions">>, FixtureMap, #{}),

    {ok, Prog} = gdbsp_parse:parse_string(Source, #{}),

    case maps:find(<<"expected">>, FixtureMap) of
        {ok, ExpectedRaw} ->
            run_positive(Prog, Functions, ExpectedRaw, GroupName, Config);
        error ->
            ExpectedErrorsRaw = maps:get(<<"expected_errors">>, FixtureMap),
            run_negative(Prog, Functions, ExpectedErrorsRaw)
    end.

run_positive(Prog, Functions, ExpectedRaw, GroupName, Config) ->
    TSMap = build_ts_map(Prog#gdbsp_program.typespecs),
    {ok, StdlibMap} = gdbsp_compile:load_stdlib(),
    Lowered0 = lower_program(Prog),
    {ok, Lowered} = gdbsp_type_infer:infer_lowered(Lowered0, TSMap, Functions, StdlibMap),

    %% Generate lowered graph DOT
    write_dot_file("type_infer", GroupName, "lowered",
                   gdbsp_graphviz:lowered_to_dot(Lowered), Config),

    NameToType = tags_to_types(Lowered),
    maps:foreach(
        fun(Name, JsonType) ->
            {ok, ExpectedType} = convert_type(JsonType),
            case maps:find(Name, NameToType) of
                {ok, ExpectedType} ->
                    ok;
                {ok, Got} ->
                    ct:pal("Type mismatch for ~p: expected ~p, got ~p",
                           [Name, ExpectedType, Got]),
                    error({type_mismatch, Name, ExpectedType, Got});
                error ->
                    ct:pal("No type computed for node ~p", [Name]),
                    error({missing_type, Name})
            end
        end,
        ExpectedRaw),
    ok.

run_negative(Prog, Functions, ExpectedErrorsRaw) ->
    TSMap = build_ts_map(Prog#gdbsp_program.typespecs),
    {ok, StdlibMap} = gdbsp_compile:load_stdlib(),
    Lowered0 = lower_program(Prog),
    case gdbsp_type_infer:infer_lowered(Lowered0, TSMap, Functions, StdlibMap) of
        {ok, _Lowered} ->
            ct:fail("expected error but infer succeeded");
        {error, Reason} when is_map(Reason) ->
            check_expected_errors(Reason, ExpectedErrorsRaw);
        {error, Other} ->
            ct:pal("Unexpected error reason: ~p", [Other]),
            error({unexpected_error, Other})
    end.

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
                    case match_value(ExpVal, ActVal) of
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

match_value(Exp, Act) when is_list(Exp), is_list(Act) ->
    lists:sort(Exp) =:= lists:sort(Act);
match_value(Exp, Act) ->
    Exp =:= Act.

%%====================================================================
%% Compilation pipeline helpers
%%====================================================================

build_ts_map(Typespecs) ->
    lists:foldl(
        fun(#gdbsp_typespec{name = N, spec = {type, {stream, Inner}}}, Acc) ->
                Acc#{N => Inner};
           (#gdbsp_typespec{name = N, spec = {type, T}}, Acc) ->
                Acc#{N => T};
           (_TS, Acc) ->
                Acc
        end, #{}, Typespecs).

lower_program(Prog) ->
    case gdbsp_compile_lower:run(Prog, #{}) of
        {ok, Lowered} -> Lowered;
        {error, Reason} ->
            ct:pal("Lowering failed: ~p", [Reason]),
            error({lowering_error, Reason})
    end.

%%--------------------------------------------------------------------
%% Build a tag-name → type map from the inferred lowered graph
%%--------------------------------------------------------------------

tags_to_types(#lowered_graph{nodes = Nodes, tag_map = TagMap}) ->
    maps:fold(
        fun(Tag, LId, Acc) ->
            case maps:find(LId, Nodes) of
                {ok, #lnode{type = T}} when T =/= undefined ->
                    Acc#{Tag => T};
                _ -> Acc
            end
        end, #{}, TagMap).

%%====================================================================
%% Type helpers
%%====================================================================

convert_type(JsonType) ->
    case gdbsp_type:parse_type(JsonType) of
        {ok, Type} -> {ok, Type};
        {error, Reason} ->
            ct:pal("Failed to parse expected type ~p: ~p", [JsonType, Reason]),
            error({invalid_type_json, JsonType, Reason})
    end.

%%====================================================================
%% DOT file generation
%%====================================================================

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
