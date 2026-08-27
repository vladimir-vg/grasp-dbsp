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
    FixtureDefs = discover_test_groups(),
    FixtureRefs = [{group, N} || {N, _, _} <- FixtureDefs],
    case FixtureRefs of
        [] -> [];
        _ -> [{all_tests, [parallel], FixtureRefs} | FixtureDefs]
    end.

%%====================================================================
%% Test discovery
%%====================================================================

discover_test_groups() ->
    DataDir = data_dir(),
    case file:list_dir(DataDir) of
        {ok, Entries} ->
            lists:flatmap(fun(Entry) ->
                build_test_groups(DataDir, Entry)
            end, lists:sort(Entries));
        {error, _} -> []
    end.

build_test_groups(DataDir, Entry) ->
    TestDir = filename:join(DataDir, Entry),
    SqlFile = filename:join(TestDir, Entry ++ ".sql"),
    GdbspFile = filename:join(TestDir, Entry ++ ".gdbsp"),
    case {filelib:is_dir(TestDir),
          filelib:is_file(SqlFile),
          filelib:is_file(GdbspFile)} of
        {true, true, true} ->
            {ok, SqlContent} = file:read_file(SqlFile),
            {ok, GdbspContent} = file:read_file(GdbspFile),
            [begin
                 GroupName = list_to_atom(Entry ++ "_" ++ Scenario),
                 persistent_term:put({?MODULE, GroupName},
                     {TestDir, Scenario, SqlContent, GdbspContent}),
                 {GroupName, [parallel], [fixture_test]}
             end || Scenario <- discover_scenarios(TestDir)];
        _ ->
            []
    end.

discover_scenarios(TestDir) ->
    case file:list_dir(TestDir) of
        {ok, Entries} ->
            lists:sort([E || E <- Entries,
                  filelib:is_dir(filename:join(TestDir, E)),
                  not lists:prefix(".", E)]);
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
    {TestDir, Scenario, SqlContent, GdbspContent} =
        persistent_term:get({?MODULE, GroupName}),
    ct:pal("Running scenario: ~s/~s", [GroupName, Scenario]),
    gdbsp_cross_runner:run_scenario(
        TestDir, Scenario, SqlContent, GdbspContent).
