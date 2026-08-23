%%%-------------------------------------------------------------------
%%% @doc Runtime typed-value module — string operations.
%%%
%%% Accepts both `string` and `{string, Encoding}` value tags and
%%% preserves the tag on string-returning operations.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_string).

-include("gdbsp_type.hrl").

-export([string_concat/2, string_upper/1, string_lower/1, string_length/1]).

%%====================================================================
%% Concat
%%====================================================================

string_concat({value, T1, A}, {value, T2, B}) when is_binary(A), is_binary(B) ->
    {value, concat_result_type(T1, T2), <<A/binary, B/binary>>}.

concat_result_type({string, Enc}, {string, Enc}) -> {string, Enc};
concat_result_type(string, string) -> string;
concat_result_type({string, Enc}, _) -> {string, Enc};
concat_result_type(_, {string, Enc}) -> {string, Enc};
concat_result_type(_, _) -> string.

%%====================================================================
%% Case mapping
%%====================================================================

string_upper({value, T, Bin}) when is_binary(Bin) ->
    {value, T, unicode_map(string, uppercase, Bin)}.

string_lower({value, T, Bin}) when is_binary(Bin) ->
    {value, T, unicode_map(string, lowercase, Bin)}.

%%====================================================================
%% Length
%%====================================================================

string_length({value, _T, Bin}) when is_binary(Bin) ->
    {value, integer, length(unicode:characters_to_list(Bin))}.

%%====================================================================
%% Helpers
%%====================================================================

unicode_map(Mod, Fun, Bin) ->
    List = unicode:characters_to_list(Bin),
    Mapped = Mod:Fun(List),
    unicode:characters_to_binary(Mapped).
