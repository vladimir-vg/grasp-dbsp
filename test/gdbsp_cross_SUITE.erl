%%%-------------------------------------------------------------------
%%% @doc Cross-implementation test suite — SQLite vs grasp-dbsp.
%%%
%%% Walks test/gdbsp_cross_SUITE_data/, discovers test directories
%%% containing .sql and .gdbsp files, and runs each scenario through
%%% gdbsp_cross_runner.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_cross_SUITE).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([fixture_test/1]).

-include_lib("common_test/include/ct.hrl").

%%====================================================================
%% CT callbacks
%%====================================================================

all() -> [{group, all_tests}].

init_per_suite(Config) ->
    application:ensure_all_started(esqlite),
    Config.

end_per_suite(_Config) ->
    application:stop(esqlite),
    ok.

groups() ->
    TestDefs = discover_test_dirs(),
    GroupRefs = [{group, N} || {N, _, _} <- TestDefs],
    case GroupRefs of
        [] -> [];
        _ -> [{all_tests, [parallel], GroupRefs} | TestDefs]
    end.

%%====================================================================
%% Test discovery
%%====================================================================

discover_test_dirs() ->
    DataDir = data_dir(),
    case file:list_dir(DataDir) of
        {ok, Entries} ->
            lists:filtermap(fun(Entry) ->
                TestDir = filename:join(DataDir, Entry),
                case filelib:is_dir(TestDir) of
                    true -> build_test_group(TestDir, Entry);
                    false -> false
                end
            end, Entries);
        {error, _} -> []
    end.

build_test_group(TestDir, Entry) ->
    SqlFile = filename:join(TestDir, Entry ++ ".sql"),
    GdbspFile = filename:join(TestDir, Entry ++ ".gdbsp"),
    case {filelib:is_file(SqlFile), filelib:is_file(GdbspFile)} of
        {true, true} ->
            Scenarios = discover_scenarios(TestDir),
            case Scenarios of
                [] -> false;
                _ ->
                    GroupName = list_to_atom(Entry),
                    {ok, SqlContent} = file:read_file(SqlFile),
                    {ok, GdbspContent} = file:read_file(GdbspFile),
                    persistent_term:put({?MODULE, GroupName},
                        {TestDir, SqlContent, GdbspContent, Scenarios}),
                    {true, {GroupName, [parallel], [fixture_test]}}
            end;
        _ ->
            false
    end.

discover_scenarios(TestDir) ->
    case file:list_dir(TestDir) of
        {ok, Entries} ->
            [E || E <- Entries,
                  filelib:is_dir(filename:join(TestDir, E)),
                  not lists:prefix(".", E)];
        {error, _} -> []
    end.

data_dir() ->
    filename:join(
        filename:dirname(code:which(?MODULE)),
        "gdbsp_cross_SUITE_data").

%%====================================================================
%% Test runner
%%====================================================================

fixture_test(Config) ->
    GroupName = proplists:get_value(name,
        ?config(tc_group_properties, Config)),
    {TestDir, SqlContent, GdbspContent, Scenarios} =
        persistent_term:get({?MODULE, GroupName}),
    lists:foreach(fun(Scenario) ->
        ct:pal("Running scenario: ~s/~s", [GroupName, Scenario]),
        gdbsp_cross_runner:run_scenario(
            TestDir, Scenario, SqlContent, GdbspContent)
    end, Scenarios).
