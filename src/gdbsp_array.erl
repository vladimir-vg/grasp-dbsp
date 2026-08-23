%%%-------------------------------------------------------------------
%%% @doc Runtime typed-value module — array operations.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_array).

-include("gdbsp_type.hrl").

-export([array_concat/2]).

%%====================================================================
%% Concat
%%====================================================================

array_concat({value, {array, T, _}, A}, {value, {array, _, _}, B})
  when is_list(A), is_list(B) ->
    {value, {array, T, varsize}, A ++ B}.
