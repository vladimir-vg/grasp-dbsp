%%%-------------------------------------------------------------------
%%% @doc Parser test suite — YAML fixture-driven.
%%%
%%% Discovers *.yaml files in parse_fixtures/. Each file is a list
%%% of test cases with `input` (DSL source), plus either `expected`
%%% (positive — parsed AST) or `expected_errors` (negative — a list
%%% of error maps with `line`, `contains`).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_parse_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_parse.hrl").
-include("gdbsp_type.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([fixture_test/1]).

-define(FIXTURE_DIR, "parse_fixtures").

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
        fixture_dir(), "\\.yaml$", true,
        fun(P, Acc) -> [P | Acc] end, []).

fixture_dir() ->
    filename:join(
        filename:dirname(code:which(?MODULE)),
        ?FIXTURE_DIR).

load_yaml_file(Path) ->
    try
        {ok, Yaml} = file:read_file(Path),
        [Doc] = yamerl:decode(binary_to_list(Yaml)),
        Doc
    catch
        C:E ->
            ct:log("Failed to load YAML file ~s: ~p:~p", [Path, C, E]),
            []
    end.

group_name(YamlPath) ->
    D = fixture_dir(),
    Rel = lists:nthtail(length(D) + 1, YamlPath),
    Parts = string:tokens(filename:rootname(Rel), "/"),
    join_atom(Parts).

join_atom([]) -> unnamed;
join_atom(Parts) -> list_to_atom(string:join(Parts, "_")).

%%====================================================================
%% Test runner
%%====================================================================

fixture_test(Config) ->
    GroupName = proplists:get_value(name, ?config(tc_group_properties, Config)),
    [Fixture] = persistent_term:get({?MODULE, GroupName}),
    run_one_fixture(Fixture).

run_one_fixture(Fixture) ->
    Input = proplists:get_value("input", Fixture),
    Source = list_to_binary(Input),

    case proplists:get_value("expected_errors", Fixture) of
        undefined ->
            Expected = proplists:get_value("expected", Fixture),
            check_positive(Source, Expected);
        ExpectedErrors ->
            check_negative(Source, ExpectedErrors)
    end.

%%====================================================================
%% Positive: parse must succeed, deep-compare AST
%%====================================================================

check_positive(Source, Expected) ->
    case gdbsp_parse:parse_string(Source, #{}) of
        {ok, Prog} ->
            Got = program_to_stmts(Prog),
            case deep_compare(Got, normalize_expected(Expected)) of
                ok -> ok;
                {mismatch, Path, GotVal, ExpVal} ->
                    ct:fail("mismatch at ~s: got ~p, expected ~p",
                            [Path, GotVal, ExpVal])
            end;
        {error, {Line, Msg}} ->
            ct:fail("unexpected parse error at line ~b: ~s", [Line, Msg])
    end.

%%====================================================================
%% Negative: parse must fail, subset-match each error
%%====================================================================

check_negative(Source, ExpectedErrors) ->
    case gdbsp_parse:parse_string(Source, #{}) of
        {ok, _Prog} ->
            ct:fail("expected parse error but got success");
        {error, {Line, MsgBin}} ->
            Msg = binary_to_list(MsgBin),
            check_negative_errors(Line, Msg, ExpectedErrors)
    end.

check_negative_errors(_Line, _Msg, []) ->
    ok;
check_negative_errors(Line, Msg, [Error | Rest]) ->
    case proplists:get_value("line", Error) of
        ExpLine when is_integer(ExpLine) ->
            case Line =:= ExpLine of
                true -> ok;
                false ->
                    ct:fail("expected error line ~b, got ~b: ~s",
                            [ExpLine, Line, Msg])
            end;
        _ -> ok
    end,
    case proplists:get_value("contains", Error) of
        ExpContains when is_list(ExpContains) ->
            case string:str(Msg, ExpContains) > 0 of
                true -> ok;
                false ->
                    ct:fail("expected error containing '~s', got: ~s",
                            [ExpContains, Msg])
            end;
        _ -> ok
    end,
    check_negative_errors(Line, Msg, Rest).

%%====================================================================
%% Program → ordered statement list
%%====================================================================

program_to_stmts(#gdbsp_program{nodes = Nodes, typespecs = TSs}) ->
    NStmts = [#{name => b2a(N#gdbsp_node_def.name),
                op   => N#gdbsp_node_def.op,
                args => norm_args(N#gdbsp_node_def.args),
                line => N#gdbsp_node_def.line} || N <- Nodes],
    TStmts = [typespec_to_stmt(T) || T <- TSs],
    lists:sort(fun(A, B) -> maps:get(line, A) =< maps:get(line, B) end,
               NStmts ++ TStmts).

b2a(B) -> binary_to_atom(B, utf8).

norm_args([{Key, Items} | Rest]) when is_list(Items) ->
    [#{Key => [norm_arg_val(I) || I <- Items]} | norm_args(Rest)];
norm_args([{Key, Val} | Rest]) ->
    [#{Key => norm_arg_val(Val)} | norm_args(Rest)];
norm_args([]) -> [].

norm_arg_val(B) when is_binary(B) -> binary_to_atom(B, utf8);
norm_arg_val(V) -> V.

typespec_to_stmt(#gdbsp_typespec{name = N, spec = {type, T}, line = L}) ->
    #{name => b2a(N), type => norm_type(T), line => L};
typespec_to_stmt(#gdbsp_typespec{name = N, spec = {Kind, Params, Ret}, line = L}) ->
    #{name   => b2a(N),
      kind   => Kind,
      params => [norm_type(P) || P <- Params],
      return => norm_type(Ret),
      line   => L}.

%%--------------------------------------------------------------------
%% Type normalization — Erlang type term → fixture-comparable form
%%--------------------------------------------------------------------

norm_type(T) when is_binary(T) ->
    binary_to_atom(T, utf8);
norm_type({enum, Names}) ->
    Sorted = lists:sort(Names),
    #{enum => [b2a(N) || N <- Sorted]};
norm_type(T) when is_atom(T) -> T;
norm_type({json, T}) -> #{json => norm_type(T)};
norm_type({dynamic, T}) -> #{dynamic => norm_type(T)};
norm_type({optional, T}) -> #{optional => norm_type(T)};
norm_type({closure, [], T}) -> #{closure => #{'return' => norm_type(T)}};
norm_type({closure, Ps, T}) ->
    PMap = maps:from_list([{b2a(K), norm_type(V)} || {K, V} <- Ps]),
    #{closure => #{params => PMap, 'return' => norm_type(T)}};
norm_type({numeric, P, S}) -> #{numeric => #{precision => P, scale => S}};
norm_type({bytes, N}) -> #{bytes => #{size => N}};
norm_type({bits, N}) -> #{bits => #{size => N}};
norm_type({string, E}) -> #{string => #{encoding => b2a(E)}};
norm_type({array, T, varsize}) -> #{array => norm_type(T)};
norm_type({array, T, N}) when is_integer(N) ->
    #{array => #{element => norm_type(T), size => N}};
norm_type({array, T, Dims}) when is_list(Dims) ->
    #{array => #{element => norm_type(T), shape => Dims}};
norm_type({map, K, V}) -> #{map => #{key => norm_type(K), value => norm_type(V)}};
norm_type({stream, Inner}) -> #{stream => norm_type(Inner)};
norm_type({struct, Fields, wildcard}) when map_size(Fields) =:= 0 ->
    #{struct => '**'};
norm_type({struct, Fields, _Rest}) ->
    #{struct => maps:fold(fun(F, T2, Acc) ->
        Acc#{b2a(F) => norm_type(T2)}
    end, #{}, Fields)}.

%%--------------------------------------------------------------------
%% YAML expected normalization — converts yamerl output to canonical form
%%--------------------------------------------------------------------

normalize_expected([]) -> [];
normalize_expected(List) when is_list(List) ->
    case is_char_list(List) of
        true -> to_type_val(List);
        false ->
            case is_tuples_only(List) of
                true ->
                    maps:from_list([{to_atom(K), normalize_expected(V)}
                                   || {K, V} <- List]);
                false ->
                    [normalize_expected_item(I) || I <- List]
            end
    end;
normalize_expected({Key, Val}) ->
    #{to_atom(Key) => normalize_expected(Val)};
normalize_expected(Other) ->
    to_type_val(Other).

is_char_list([]) -> true;
is_char_list([H | T]) when is_integer(H), H >= 0 -> is_char_list(T);
is_char_list(_) -> false.

is_tuples_only([{K, _} | Rest])
  when is_list(K) orelse is_atom(K) orelse is_binary(K) ->
    is_tuples_only(Rest);
is_tuples_only([]) -> true;
is_tuples_only(_) -> false.

normalize_expected_item(Map) when is_map(Map) -> Map;
normalize_expected_item({Key, Val}) ->
    normalize_expected_item(#{to_atom(Key) => normalize_expected(Val)});
normalize_expected_item([{K, _} | _] = PropList)
  when is_list(K); is_atom(K); is_binary(K) ->
    PL = [{to_atom(K2), V2} || {K2, V2} <- PropList],
    case proplists:get_value(name, PL) of
        undefined ->
            maps:from_list([{K3, normalize_expected(V3)} || {K3, V3} <- PL]);
        Name ->
            Line = proplists:get_value(line, PL),
            case proplists:get_value(op, PL) of
                undefined ->
                    case proplists:get_value(type, PL) of
                        undefined ->
                            maps:from_list([
                                {name, to_type_val(Name)},
                                {kind, to_atom(proplists:get_value(kind, PL))},
                                {params, normalize_expected(
                                    proplists:get_value(params, PL))},
                                {'return', normalize_expected(
                                    proplists:get_value('return', PL))},
                                {line, Line}]);
                        TypeVal ->
                            maps:from_list([
                                {name, to_type_val(Name)},
                                {type, normalize_expected(TypeVal)},
                                {line, Line}])
                    end;
                Op ->
                    maps:from_list([
                        {name, to_type_val(Name)},
                        {op, to_atom(Op)},
                        {args, normalize_expected(
                            proplists:get_value(args, PL))},
                        {line, Line}])
            end
    end;
normalize_expected_item(Other) ->
    to_type_val(Other).

to_atom(A) when is_atom(A) -> A;
to_atom(B) when is_binary(B) -> binary_to_atom(B, utf8);
to_atom(S) when is_list(S) -> list_to_atom(S).

to_type_val(A) when is_atom(A) -> A;
to_type_val(B) when is_binary(B) -> binary_to_atom(B, utf8);
to_type_val(S) when is_list(S) -> list_to_atom(S);
to_type_val(N) when is_integer(N) -> N.

%%--------------------------------------------------------------------
%% Deep comparison helper
%%--------------------------------------------------------------------

deep_compare(Got, Exp) ->
    deep_compare(Got, Exp, "").

deep_compare(A, A, _Path) -> ok;
deep_compare(L1, L2, Path) when is_list(L1), is_list(L2) ->
    case length(L1) =:= length(L2) of
        true -> deep_compare_list(L1, L2, Path, 1);
        false -> {mismatch, Path ++ " (length)", L1, L2}
    end;
deep_compare(M1, M2, Path) when is_map(M1), is_map(M2) ->
    case maps:keys(M1) =:= maps:keys(M2) of
        true ->
            maps:fold(fun(K, V1, ok) ->
                V2 = maps:get(K, M2),
                deep_compare(V1, V2, Path ++ "." ++ fmt_key(K));
            (_, _, Err) -> Err end, ok, M1);
        false ->
            {mismatch, Path, maps:keys(M1), maps:keys(M2)}
    end;
deep_compare(G, E, Path) ->
    {mismatch, Path, G, E}.

deep_compare_list([H1 | T1], [H2 | T2], Path, N) ->
    case deep_compare(H1, H2, Path ++ "[" ++ integer_to_list(N) ++ "]") of
        ok -> deep_compare_list(T1, T2, Path, N + 1);
        Err -> Err
    end;
deep_compare_list([], [], _, _) -> ok.

fmt_key(K) when is_atom(K) -> atom_to_list(K);
fmt_key(K) when is_binary(K) -> binary_to_list(K);
fmt_key(K) -> io_lib:format("~p", [K]).
