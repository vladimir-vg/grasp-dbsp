%%%-------------------------------------------------------------------
%%% @doc Input feeder: POST /inputs/{table}.
%%%
%%% The body is JSONL (one `[weight,row]` per line) appended to the
%%% table's ingress buffer. 404 for an unknown table, 400 on a decode
%%% error (with the offending line index).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_http_inputs).

-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), map()) -> {ok, cowboy_req:req(), map()}.
init(Req0, #{runtime := Rt, loop := Loop}) ->
    Table = cowboy_req:binding(table, Req0),
    SourceTypes = gdbsp_runtime:source_types(Rt),
    case maps:find(Table, SourceTypes) of
        {ok, {_Node, Type}} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0, #{length => infinity}),
            handle_body(Table, Type, Body, Loop, Rt, Req1);
        error ->
            Req = cowboy_req:reply(404, #{}, <<>>, Req0),
            {ok, Req, #{}}
    end.

handle_body(Table, Type, Body, Loop, Rt, Req0) ->
    case gdbsp_jsonl:decode_body(Type, Body) of
        {ok, Rows} ->
            ok = gdbsp_runtime:feed(Rt, Table, Rows),
            Loop ! {serve_step},
            Req = cowboy_req:reply(204, #{}, <<>>, Req0),
            {ok, Req, #{}};
        {error, {Line, Reason}} ->
            Msg = iolist_to_binary(
                ["line ", integer_to_list(Line), ": ",
                 gdbsp_jsonl:format_reason(Reason)]),
            Req = cowboy_req:reply(400,
                #{<<"content-type">> => <<"text/plain">>}, Msg, Req0),
            {ok, Req, #{}}
    end.
