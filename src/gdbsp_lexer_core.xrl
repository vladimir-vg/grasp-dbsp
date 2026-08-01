Definitions.

DIGIT     = [0-9]
LETTER    = [a-zA-Z]
ID_CHAR   = [a-zA-Z0-9_]
ID_SEG    = :[a-zA-Z][a-zA-Z0-9_]*
ID_NS0    = [$a-zA-Z_][a-zA-Z0-9_]*
ID_NS1    = {ID_NS0}{ID_SEG}
ID_NS2    = {ID_NS1}{ID_SEG}
IDENT     = {ID_NS2}|{ID_NS1}|{ID_NS0}

Rules.

\n[\040\t]+ : {token, {newline_indent, TokenLine}}.
#[^\n]*                : skip_token.
[\040\t]+              : skip_token.
\n                     : {token, {newline, TokenLine}}.

and                    : {token, {and_keyword, TokenLine}}.
or                     : {token, {or_keyword, TokenLine}}.
not                    : {token, {not_keyword, TokenLine}}.
true                   : {token, {true_literal, TokenLine}}.
false                  : {token, {false_literal, TokenLine}}.
NULL                   : {token, {null_literal, TokenLine}}.
ABSENT                 : {token, {absent_literal, TokenLine}}.
input                  : {token, {input_keyword, TokenLine}}.
closure                : {token, {closure_keyword, TokenLine}}.
eval                   : {token, {eval_keyword, TokenLine}}.
enum                   : {token, {enum_keyword, TokenLine}}.

<-                     : {token, {larrow, TokenLine}}.
:=                     : {token, {walrus, TokenLine}}.
::                     : {token, {double_colon, TokenLine}}.
->                     : {token, {arrow, TokenLine}}.
\*\*                   : {token, {double_star, TokenLine}}.
>=                     : {token, {'>=', TokenLine}}.
<=                     : {token, {'<=', TokenLine}}.
!=                     : {token, {'!=', TokenLine}}.

\+\+                   : {token, {'++', TokenLine}}.
\<\<\<                 : {token, {'<<<', TokenLine}}.
\>\>\>                 : {token, {'>>>', TokenLine}}.
\<\<                   : {token, {'<<', TokenLine}}.
\>\>                   : {token, {'>>', TokenLine}}.
\.                      : {token, {dot, TokenLine}}.
\~                      : {token, {'~', TokenLine}}.
\&                      : {token, {'&', TokenLine}}.
\^                      : {token, {'^', TokenLine}}.
\|                      : {token, {'|', TokenLine}}.

\+                      : {token, {'+', TokenLine}}.
-                       : {token, {'-', TokenLine}}.
\*                      : {token, {'*', TokenLine}}.
/                       : {token, {'/', TokenLine}}.
\%                      : {token, {'%', TokenLine}}.
=                       : {token, {'=', TokenLine}}.
>                       : {token, {'>', TokenLine}}.
<                       : {token, {'<', TokenLine}}.
:                       : {token, {':', TokenLine}}.
,                       : {token, {',', TokenLine}}.
\(                      : {token, {'(', TokenLine}}.
\)                      : {token, {')', TokenLine}}.
\{                      : {token, {'{', TokenLine}}.
\}                      : {token, {'}', TokenLine}}.
\[                      : {token, {'[', TokenLine}}.
\]                      : {token, {']', TokenLine}}.

0b[01]+ :
    {token, {bits_literal, TokenLine, parse_bit_string(TokenChars)}}.

{DIGIT}+[eE][+-]?{DIGIT}+ :
    {token, {float_literal, TokenLine, parse_number(TokenChars)}}.

{DIGIT}+\.{DIGIT}+([eE][+-]?{DIGIT}+)? :
    {token, {decimal_literal, TokenLine, parse_number(TokenChars)}}.

{DIGIT}+ :
    {token, {integer_literal, TokenLine, parse_number(TokenChars)}}.

\"(\\.|[^\"])*\" :
    {token, {string, TokenLine, unescape(TokenChars)}}.

{IDENT} :
    {token, {identifier, TokenLine, to_binary(TokenChars)}}.

Erlang code.

-export([parse_number/1, unescape/1, to_binary/1, parse_bit_string/1]).

parse_number(S) ->
    case string:chr(S, $.) of
        0 ->
            case string:chr(S, $e) of
                0 -> case string:chr(S, $E) of
                    0 -> list_to_integer(S);
                    _ -> parse_float(S)
                end;
                _ -> parse_float(S)
            end;
        _ -> parse_float(S)
    end.

parse_float(S) ->
    {F, _} = string:to_float(S),
    F.

unescape([$" | Rest]) ->
    unescape_tail(lists:droplast(Rest)).

unescape_tail([]) -> <<>>;
unescape_tail([$\\, $n | Rest]) ->
    <<$\n, (unescape_tail(Rest))/binary>>;
unescape_tail([$\\, $t | Rest]) ->
    <<$\t, (unescape_tail(Rest))/binary>>;
unescape_tail([$\\, $" | Rest]) ->
    <<$", (unescape_tail(Rest))/binary>>;
unescape_tail([$\\, $\\ | Rest]) ->
    <<$\\, (unescape_tail(Rest))/binary>>;
unescape_tail([$\\, C | Rest]) ->
    <<$\\, C, (unescape_tail(Rest))/binary>>;
unescape_tail([C | Rest]) ->
    <<(to_binary_char(C))/binary, (unescape_tail(Rest))/binary>>.

to_binary_char(C) when is_integer(C) -> <<C:8>>.

to_binary(S) -> list_to_binary(S).

parse_bit_string("0b" ++ Bits) ->
    parse_bit_string_acc(Bits, 0).

parse_bit_string_acc([], Acc) -> Acc;
parse_bit_string_acc([$1 | Rest], Acc) ->
    parse_bit_string_acc(Rest, (Acc bsl 1) bor 1);
parse_bit_string_acc([$0 | Rest], Acc) ->
    parse_bit_string_acc(Rest, Acc bsl 1).
