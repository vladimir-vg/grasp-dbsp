%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_cli — argument parsing and offline run.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_cli_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    parse_validate/1,
    parse_run/1,
    parse_serve/1,
    parse_errors/1,
    validate_ok/1,
    validate_bad_source/1,
    run_end_to_end/1,
    run_unknown_output/1,
    run_unknown_input/1,
    run_stdout/1
]).

all() -> [{group, cli}].

groups() ->
    [{cli, [parallel], [
        parse_validate,
        parse_run,
        parse_serve,
        parse_errors,
        validate_ok,
        validate_bad_source,
        run_end_to_end,
        run_unknown_output,
        run_unknown_input,
        run_stdout
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(jsx),
    Config.

end_per_suite(_Config) ->
    ok.

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

write_file(Dir, Name, Content) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, Content),
    Path.

read_lines(Path) ->
    {ok, Bin} = file:read_file(Path),
    [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>].

source() ->
    "src := source(\"data\")\n"
    "src :: stream(struct(\"id\": i64, \"dept\": i64))\n"
    "out := distinct(src)\n".

input_jsonl() ->
    "[1, {\"id\": \"1\", \"dept\": \"10\"}]\n"
    "[1, {\"id\": \"2\", \"dept\": \"20\"}]\n".

%%====================================================================
%% parse_args
%%====================================================================

parse_validate(_Config) ->
    {ok, #{command := validate, sources := ["a.gdbsp", "b.gdbsp"]}} =
        gdbsp_cli:parse_args(["validate", "a.gdbsp", "b.gdbsp"]).

parse_run(_Config) ->
    {ok, Spec} = gdbsp_cli:parse_args(
        ["run", "--output", "out=o.jsonl", "--input", "data=in.jsonl",
         "a.gdbsp"]),
    #{command := run,
      sources := ["a.gdbsp"],
      outputs := [{<<"out">>, "o.jsonl"}],
      inputs := #{<<"data">> := "in.jsonl"}} = Spec.

parse_serve(_Config) ->
    {ok, Spec} = gdbsp_cli:parse_args(
        ["serve", "--output", "out", "--listen", "127.0.0.1:9000", "a.gdbsp"]),
    #{command := serve,
      sources := ["a.gdbsp"],
      outputs := [<<"out">>],
      listen := {"127.0.0.1", 9000}} = Spec.

parse_errors(_Config) ->
    {error, {unknown_command, <<"frobnicate">>}} =
        gdbsp_cli:parse_args(["frobnicate"]),
    {error, no_sources} = gdbsp_cli:parse_args(["validate"]),
    {error, no_outputs} = gdbsp_cli:parse_args(["run", "a.gdbsp"]),
    {error, {invalid_output, _}} =
        gdbsp_cli:parse_args(["run", "--output", "nodest", "a.gdbsp"]),
    {error, {invalid_input, _}} =
        gdbsp_cli:parse_args(["run", "--output", "o=-", "--input", "nodest",
                              "a.gdbsp"]),
    {error, {unknown_option, <<"--foo">>}} =
        gdbsp_cli:parse_args(["validate", "--foo", "a.gdbsp"]),
    {error, {invalid_listen, <<"nope">>}} =
        gdbsp_cli:parse_args(["serve", "--output", "o", "--listen", "nope",
                              "a.gdbsp"]).

%%====================================================================
%% validate
%%====================================================================

validate_ok(Config) ->
    Src = write_file(?config(sub_dir, Config), "a.gdbsp", source()),
    ok = gdbsp_cli:validate(#{command => validate, sources => [Src]}).

validate_bad_source(Config) ->
    Src = write_file(?config(sub_dir, Config), "bad.gdbsp",
                     "src := source(\"data\")\nout := distinct(missing)\n"),
    {error, _} = gdbsp_cli:validate(#{command => validate, sources => [Src]}).

%%====================================================================
%% run
%%====================================================================

run_end_to_end(Config) ->
    Dir = ?config(sub_dir, Config),
    Src = write_file(Dir, "a.gdbsp", source()),
    In = write_file(Dir, "in.jsonl", input_jsonl()),
    Out = filename:join(Dir, "out.jsonl"),

    ok = gdbsp_cli:run(#{
        command => run, sources => [Src],
        inputs => #{<<"data">> => In},
        outputs => [{<<"out">>, Out}]
    }),

    [Header | Data] = read_lines(Out),
    #{<<"id">> := <<"i64">>, <<"dept">> := <<"i64">>} =
        jsx:decode(Header, [return_maps]),

    Expected = [[1, #{<<"id">> => <<"1">>, <<"dept">> => <<"10">>}],
                [1, #{<<"id">> => <<"2">>, <<"dept">> => <<"20">>}]],
    Expected = [jsx:decode(L, [return_maps]) || L <- Data].

run_unknown_output(Config) ->
    Dir = ?config(sub_dir, Config),
    Src = write_file(Dir, "a.gdbsp", source()),
    In = write_file(Dir, "in.jsonl", input_jsonl()),
    Out = filename:join(Dir, "out.jsonl"),
    {error, _} = gdbsp_cli:run(#{
        command => run, sources => [Src],
        inputs => #{<<"data">> => In},
        outputs => [{<<"nope">>, Out}]
    }).

run_unknown_input(Config) ->
    Dir = ?config(sub_dir, Config),
    Src = write_file(Dir, "a.gdbsp", source()),
    In = write_file(Dir, "in.jsonl", input_jsonl()),
    Out = filename:join(Dir, "out.jsonl"),
    {error, _} = gdbsp_cli:run(#{
        command => run, sources => [Src],
        inputs => #{<<"nope">> => In},
        outputs => [{<<"out">>, Out}]
    }).

run_stdout(Config) ->
    Dir = ?config(sub_dir, Config),
    Src = write_file(Dir, "a.gdbsp", source()),
    In = write_file(Dir, "in.jsonl", input_jsonl()),
    ok = gdbsp_cli:run(#{
        command => run, sources => [Src],
        inputs => #{<<"data">> => In},
        outputs => [{<<"out">>, "-"}]
    }).
