%%%-------------------------------------------------------------------
%%% @doc Runtime typed-value module — bits (bitstring) operations.
%%%
%%% Bits are represented as byte-aligned binaries at the JSON boundary;
%%% bitwise operations treat them as byte sequences. Shift/rotate
%%% operations work at the bit level and may produce non-byte-aligned
%%% bitstrings.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_bits).

-include("gdbsp_type.hrl").

-export([bits_concat/2]).
-export([bits_and/2, bits_or/2, bits_xor/2, bits_not/1]).
-export([bits_shl/2, bits_shr/2, bits_rotl/2, bits_rotr/2]).

%%====================================================================
%% Concat
%%====================================================================

bits_concat({value, T1, A}, {value, T2, B}) when is_binary(A), is_binary(B) ->
    {value, concat_result_type(T1, T2), <<A/binary, B/binary>>}.

concat_result_type({bits, N}, {bits, M}) -> {bits, N + M};
concat_result_type(bits, bits) -> bits;
concat_result_type({bits, _}, _) -> bits;
concat_result_type(_, {bits, _}) -> bits;
concat_result_type(_, _) -> bits.

%%====================================================================
%% Bitwise and / or / xor / not
%%====================================================================

bits_and({value, T, A}, {value, _, B}) when is_binary(A), is_binary(B) ->
    {value, T, bytewise_op(fun(X, Y) -> X band Y end, A, B)}.

bits_or({value, T, A}, {value, _, B}) when is_binary(A), is_binary(B) ->
    {value, T, bytewise_op(fun(X, Y) -> X bor Y end, A, B)}.

bits_xor({value, T, A}, {value, _, B}) when is_binary(A), is_binary(B) ->
    {value, T, bytewise_op(fun(X, Y) -> X bxor Y end, A, B)}.

bits_not({value, T, A}) when is_binary(A) ->
    {value, T, list_to_binary([(bnot X) band 16#FF || X <- binary_to_list(A)])}.

bytewise_op(Fun, A, B) ->
    Size = min(byte_size(A), byte_size(B)),
    <<AHead:Size/binary, _/binary>> = A,
    <<BHead:Size/binary, _/binary>> = B,
    list_to_binary([Fun(X, Y) || {X, Y} <- lists:zip(binary_to_list(AHead),
                                                     binary_to_list(BHead))]).

%%====================================================================
%% Shift / rotate
%%====================================================================

bits_shl({value, T, A}, Shift) when is_binary(A) ->
    {value, T, <<A/bitstring, 0:(shift_count(Shift))>>}.

bits_shr({value, T, A}, Shift) when is_binary(A) ->
    Len = bit_size(A),
    case shift_count(Shift) of
        N when N >= Len -> {value, T, <<>>};
        N ->
            <<_:N, Rest/bitstring>> = A,
            {value, T, Rest}
    end.

bits_rotl({value, T, A}, Shift) when is_binary(A) ->
    Len = bit_size(A),
    N = rotate_count(shift_count(Shift), Len),
    <<Head:N/bitstring, Rest/bitstring>> = A,
    {value, T, <<Rest/bitstring, Head/bitstring>>}.

bits_rotr({value, T, A}, Shift) when is_binary(A) ->
    Len = bit_size(A),
    N = rotate_count(shift_count(Shift), Len),
    Split = Len - N,
    <<Head:Split/bitstring, Rest/bitstring>> = A,
    {value, T, <<Rest/bitstring, Head/bitstring>>}.

shift_count({value, _, N}) when is_integer(N), N >= 0 -> N.

rotate_count(_N, 0) -> 0;
rotate_count(N, Len) -> N rem Len.
