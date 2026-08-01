%%%-------------------------------------------------------------------
%%% @doc Lexer — tokenises .gdbsp source text into a token stream.
%%% Wraps the leex-generated scanner (gdbsp_lexer_core).
%%%
%%% Handles indentation tracking for circuit bodies.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_lexer).

-export([string/1]).

%%====================================================================
%% API
%%====================================================================

-spec string(binary()) -> {ok, [term()]} | {error, term()}.
string(Bin) ->
    try
        S = binary_to_list(Bin),
        {ok, Raw, _EndLine} = gdbsp_lexer_core:string(S),
        Stripped = drop_skips(Raw),
        Replaced = replace_null_absent(Stripped),
        Marked = insert_body_markers(Replaced),
        {ok, Marked}
    catch
        C:E ->
            {error, {C, E}}
    end.

%%====================================================================
%% Skip token handling
%%====================================================================

drop_skips(Tokens) ->
    lists:flatmap(
        fun
            ({newline_indent, Line}) -> [{newline, Line}, {indent, Line}];
            (skip_token) -> [];
            (T) -> [T]
        end,
        Tokens
    ).

%%====================================================================
%% NULL → absent_literal, identifier "null" → null_symbol
%%====================================================================

replace_null_absent(Tokens) ->
    [case T of
         {null_literal, L} -> {absent_literal, L};
         {identifier, L, <<"ABSENT">>} -> {absent_literal, L};
         {identifier, L, <<"null">>} -> {null_symbol, L};
         _ -> T
     end || T <- Tokens].

%%====================================================================
%% Circuit body indentation
%%====================================================================
%% State machine:
%%   normal        — pass through, detect circuit keyword
%%   looking(Depth) — tracking paren depth, looking for ':' at depth 0
%%   body_enter    — after circuit header, waiting for indent
%%   body_stmt(Depth) — inside body, tracking paren depth for multiline

insert_body_markers(Tokens) ->
    lists:reverse(pass(Tokens, normal, [])).

pass([], _State, Acc) ->
    Acc;
pass([{identifier, _, <<"circuit">>} = T | Rest], normal, Acc) ->
    pass(Rest, {looking, 0}, [T | Acc]);
pass([T | Rest], normal, Acc) ->
    pass(Rest, normal, [T | Acc]);

%% looking mode — track paren depth, ':' at depth 0 ends header
pass([{'(', _} = T | Rest], {looking, Depth}, Acc) ->
    pass(Rest, {looking, Depth + 1}, [T | Acc]);
pass([{'{', _} = T | Rest], {looking, Depth}, Acc) ->
    pass(Rest, {looking, Depth + 1}, [T | Acc]);
pass([{'[', _} = T | Rest], {looking, Depth}, Acc) ->
    pass(Rest, {looking, Depth + 1}, [T | Acc]);
pass([{')', _} = T | Rest], {looking, Depth}, Acc) when Depth > 0 ->
    pass(Rest, {looking, Depth - 1}, [T | Acc]);
pass([{'}', _} = T | Rest], {looking, Depth}, Acc) when Depth > 0 ->
    pass(Rest, {looking, Depth - 1}, [T | Acc]);
pass([{']', _} = T | Rest], {looking, Depth}, Acc) when Depth > 0 ->
    pass(Rest, {looking, Depth - 1}, [T | Acc]);
pass([{':', _} = T | Rest], {looking, 0}, Acc) ->
    pass(Rest, body_enter, [T | Acc]);
pass([T | Rest], {looking, Depth}, Acc) ->
    pass(Rest, {looking, Depth}, [T | Acc]);

%% body_enter — skip newlines, emit body_line on indent, give up on anything else
pass([{newline, _} | Rest], body_enter, Acc) ->
    pass(Rest, body_enter, Acc);
pass([{indent, _} | Rest], body_enter, Acc) ->
    pass(Rest, {body_stmt, 0}, [{body_line, 0} | Acc]);
pass([T | Rest], body_enter, Acc) ->
    pass(Rest, normal, [T | Acc]);

%% body_stmt — pass through tokens, track paren depth, newline at depth 0 → body_enter
pass([{'(', _} = T | Rest], {body_stmt, Depth}, Acc) ->
    pass(Rest, {body_stmt, Depth + 1}, [T | Acc]);
pass([{'{', _} = T | Rest], {body_stmt, Depth}, Acc) ->
    pass(Rest, {body_stmt, Depth + 1}, [T | Acc]);
pass([{'[', _} = T | Rest], {body_stmt, Depth}, Acc) ->
    pass(Rest, {body_stmt, Depth + 1}, [T | Acc]);
pass([{')', _} = T | Rest], {body_stmt, Depth}, Acc) when Depth > 0 ->
    pass(Rest, {body_stmt, Depth - 1}, [T | Acc]);
pass([{'}', _} = T | Rest], {body_stmt, Depth}, Acc) when Depth > 0 ->
    pass(Rest, {body_stmt, Depth - 1}, [T | Acc]);
pass([{']', _} = T | Rest], {body_stmt, Depth}, Acc) when Depth > 0 ->
    pass(Rest, {body_stmt, Depth - 1}, [T | Acc]);
pass([{newline, _} | Rest], {body_stmt, 0}, Acc) ->
    pass(Rest, body_enter, Acc);
pass([T | Rest], {body_stmt, Depth}, Acc) ->
    pass(Rest, {body_stmt, Depth}, [T | Acc]).
