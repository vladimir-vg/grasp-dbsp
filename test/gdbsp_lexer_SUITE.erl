%%%-------------------------------------------------------------------
%%% @doc Lexer test suite — unit tests for gdbsp_lexer:string/1.
%%% Each test case validates that a source string produces the expected
%%% token sequence.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_lexer_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([t01_node_def/1, t02_typespec/1, t03_literals/1,
         t04_expr_operators/1, t05_bitwise_operators/1, t06_delimiters/1,
         t07_function_def/1, t08_circuit_indent/1, t09_comments/1]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() -> [
    t01_node_def, t02_typespec, t03_literals,
    t04_expr_operators, t05_bitwise_operators, t06_delimiters,
    t07_function_def, t08_circuit_indent, t09_comments
].

%%====================================================================
%% Helpers
%%====================================================================

lex(Source) ->
    {ok, Tokens} = gdbsp_lexer:string(list_to_binary(Source)),
    %% Strip newline tokens and line numbers for assertion convenience
    Stripped = [T || T <- Tokens, element(1, T) =/= newline],
    [strip_line(T) || T <- Stripped].

%% Strip line number (position 2) from tokens that carry one.
%% body_line tokens keep their line number since it's part of their
%% semantic value.
strip_line({body_line, _Line} = T) -> T;
strip_line({Tag, Line, Val}) when is_integer(Line) ->
    {Tag, Val};
strip_line({Tag, Line}) when is_integer(Line) ->
    {Tag};
strip_line(T) -> T.

%%====================================================================
%% Cycle 1 — Node definition
%%====================================================================

t01_node_def(_Config) ->
    Tokens = lex("name := source(\"table\")"),
    Expected = [
        {identifier, <<"name">>},
        {walrus},
        {identifier, <<"source">>},
        {'('},
        {string, <<"table">>},
        {')'}
    ],
    assert_tokens(Expected, Tokens).

%%====================================================================
%% Cycle 2 — Typespec
%%====================================================================

t02_typespec(_Config) ->
    Tokens = lex("name :: stream(struct(\"f\": i64))"),
    Expected = [
        {identifier, <<"name">>},
        {double_colon},
        {identifier, <<"stream">>},
        {'('},
        {identifier, <<"struct">>},
        {'('},
        {string, <<"f">>},
        {':'},
        {identifier, <<"i64">>},
        {')'},
        {')'}
    ],
    assert_tokens(Expected, Tokens).

%%====================================================================
%% Cycle 3 — Literals
%%====================================================================

t03_literals(_Config) ->
    Tokens = lex("42 3.14 0b1011 \"hello\""),
    Expected = [
        {integer_literal, 42},
        {decimal_literal, 3.14},
        {bits_literal, 11},
        {string, <<"hello">>}
    ],
    assert_tokens(Expected, Tokens).

%%====================================================================
%% Cycle 4 — Expression operators
%%====================================================================

t04_expr_operators(_Config) ->
    Tokens = lex("+ - * / % = != < > <= >= and or not"),
    Expected = [
        {'+'}, {'-'}, {'*'}, {'/'}, {'%'},
        {'='}, {'!='}, {'<'}, {'>'}, {'<='}, {'>='},
        {and_keyword}, {or_keyword}, {not_keyword}
    ],
    assert_tokens(Expected, Tokens).

%%====================================================================
%% Cycle 5 — Bitwise operators
%%====================================================================

t05_bitwise_operators(_Config) ->
    Tokens = lex("| ^ & << >> <<< >>> ~ ++"),
    Expected = [
        {'|'}, {'^'}, {'&'},
        {'<<'}, {'>>'}, {'<<<'}, {'>>>'},
        {'~'}, {'++'}
    ],
    assert_tokens(Expected, Tokens).

%%====================================================================
%% Cycle 6 — Delimiters
%%====================================================================

t06_delimiters(_Config) ->
    Tokens = lex("{ } [ ] . , : -> := :: **"),
    Expected = [
        {'{'}, {'}'}, {'['}, {']'},
        {dot}, {','}, {':'},
        {arrow}, {walrus}, {double_colon}, {double_star}
    ],
    assert_tokens(Expected, Tokens).

%%====================================================================
%% Cycle 7 — Function definition
%%====================================================================

t07_function_def(_Config) ->
    Tokens = lex("add := function((x, y, d:, e: evar) -> x + y)"),
    Expected = [
        {identifier, <<"add">>},
        {walrus},
        {identifier, <<"function">>},
        {'('},
        {'('},
        {identifier, <<"x">>},
        {','},
        {identifier, <<"y">>},
        {','},
        {identifier, <<"d">>},
        {':'},
        {','},
        {identifier, <<"e">>},
        {':'},
        {identifier, <<"evar">>},
        {')'},
        {arrow},
        {identifier, <<"x">>},
        {'+'},
        {identifier, <<"y">>},
        {')'}
    ],
    assert_tokens(Expected, Tokens).

%%====================================================================
%% Cycle 8 — Circuit body indentation
%%====================================================================

t08_circuit_indent(_Config) ->
    Tokens = lex("circuit tc_body(edge: e, path: p):\n"
                 "    base := map(e, rename)\n"
                 "    path := distinct(plus(base, joined))\n"),
    Expected = [
        {identifier, <<"circuit">>},
        {identifier, <<"tc_body">>},
        {'('},
        {identifier, <<"edge">>},
        {':'},
        {identifier, <<"e">>},
        {','},
        {identifier, <<"path">>},
        {':'},
        {identifier, <<"p">>},
        {')'},
        {':'},
        {body_line, 0},
        {identifier, <<"base">>},
        {walrus},
        {identifier, <<"map">>},
        {'('},
        {identifier, <<"e">>},
        {','},
        {identifier, <<"rename">>},
        {')'},
        {body_line, 0},
        {identifier, <<"path">>},
        {walrus},
        {identifier, <<"distinct">>},
        {'('},
        {identifier, <<"plus">>},
        {'('},
        {identifier, <<"base">>},
        {','},
        {identifier, <<"joined">>},
        {')'},
        {')'}
    ],
    assert_tokens(Expected, Tokens).

%%====================================================================
%% Cycle 9 — Comments
%%====================================================================

t09_comments(_Config) ->
    Tokens = lex("# this is a comment\n"
                 "name := source(\"table\") # inline comment\n"
                 "# another comment\n"
                 "other := plus(name)\n"),
    Expected = [
        {identifier, <<"name">>},
        {walrus},
        {identifier, <<"source">>},
        {'('},
        {string, <<"table">>},
        {')'},
        {identifier, <<"other">>},
        {walrus},
        {identifier, <<"plus">>},
        {'('},
        {identifier, <<"name">>},
        {')'}
    ],
    assert_tokens(Expected, Tokens).

%%====================================================================
%% Assertions
%%====================================================================

assert_tokens([], []) -> ok;
assert_tokens([], Got) ->
    ct:fail("expected no more tokens, got ~p", [Got]);
assert_tokens(Expected, []) ->
    ct:fail("expected tokens ~p, got none", [Expected]);
assert_tokens([{Tag, Val} | ERest], [{Tag, Val} | GRest]) ->
    assert_tokens(ERest, GRest);
assert_tokens([{Tag, Val, V2} | ERest], [{Tag, Val, V2} | GRest]) ->
    assert_tokens(ERest, GRest);
assert_tokens([{Tag} | ERest], [{Tag} | GRest]) ->
    assert_tokens(ERest, GRest);
assert_tokens([{Tag, Val, V2, V3} | ERest], [{Tag, Val, V2, V3} | GRest]) ->
    assert_tokens(ERest, GRest);
assert_tokens([E | _], [G | _]) ->
    ct:fail("token mismatch at position: expected ~p, got ~p", [E, G]).
