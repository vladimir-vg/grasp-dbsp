%%%-------------------------------------------------------------------
%%% @doc Output streamer: GET /outputs/{name}.
%%%
%%% Subscribes to the named output sink and streams its JSONL header
%%% followed by one line per delta (chunked, flushed per epoch). The
%%% connection stays open until the client disconnects. 404 for an
%%% unknown output.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_http_outputs).

-behaviour(cowboy_loop).

-export([init/2, info/3, terminate/3]).

-spec init(cowboy_req:req(), map()) ->
    {ok, cowboy_req:req(), map()} | {cowboy_loop, cowboy_req:req(), map()}.
init(Req0, #{runtime := Rt}) ->
    Name = cowboy_req:binding(name, Req0),
    OutputTypes = gdbsp_runtime:output_types(Rt),
    case maps:is_key(Name, OutputTypes) of
        false ->
            Req = cowboy_req:reply(404, #{}, <<>>, Req0),
            {ok, Req, #{}};
        true ->
            ok = gdbsp_runtime:subscribe(Rt, Name, self()),
            Req = cowboy_req:stream_reply(200,
                #{<<"content-type">> => <<"application/x-ndjson">>,
                  <<"cache-control">> => <<"no-cache">>}, Req0),
            {cowboy_loop, Req, #{name => Name, runtime => Rt}}
    end.

-spec info(term(), cowboy_req:req(), map()) ->
    {ok, cowboy_req:req(), map()} | {stop, cowboy_req:req(), map()}.
info({output_header, Header}, Req, State) ->
    cowboy_req:stream_body([gdbsp_jsonl:encode_line(Header), "\n"], nofin, Req),
    {ok, Req, State};
info({output_line, Line}, Req, State) ->
    cowboy_req:stream_body([gdbsp_jsonl:encode_line(Line), "\n"], nofin, Req),
    {ok, Req, State};
info({output_epoch_done, _Epoch}, Req, State) ->
    {ok, Req, State};
info(_Msg, Req, State) ->
    {ok, Req, State}.

-spec terminate(term(), cowboy_req:req(), map()) -> ok.
terminate(_Reason, _Req, #{name := Name, runtime := Rt}) ->
    gdbsp_runtime:unsubscribe(Rt, Name, self());
terminate(_Reason, _Req, _State) ->
    ok.
