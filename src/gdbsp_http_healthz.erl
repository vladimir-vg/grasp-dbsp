%%%-------------------------------------------------------------------
%%% @doc Liveness probe handler.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_http_healthz).

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Req = cowboy_req:reply(200,
        #{<<"content-type">> => <<"text/plain">>}, <<"ok">>, Req0),
    {ok, Req, State}.
