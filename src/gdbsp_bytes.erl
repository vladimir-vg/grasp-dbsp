%%%-------------------------------------------------------------------
%%% @doc Runtime typed-value module — bytes operations.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_bytes).

-include("gdbsp_type.hrl").

-export([bytes_concat/2]).

%%====================================================================
%% Concat
%%====================================================================

bytes_concat({value, T1, A}, {value, T2, B}) when is_binary(A), is_binary(B) ->
    {value, concat_result_type(T1, T2), <<A/binary, B/binary>>}.

concat_result_type({bytes, N}, {bytes, M}) -> {bytes, N + M};
concat_result_type(bytes, bytes) -> bytes;
concat_result_type({bytes, _}, _) -> bytes;
concat_result_type(_, {bytes, _}) -> bytes;
concat_result_type(_, _) -> bytes.
