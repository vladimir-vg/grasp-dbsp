%%%-------------------------------------------------------------------
%%% @doc Cowboy HTTP front-end for `gdbsp serve`.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_http).

-export([serve/1]).

-spec serve(map()) -> ok | {error, iolist()}.
serve(_Spec) ->
    {error, "serve: not implemented yet"}.
