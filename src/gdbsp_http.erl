%%%-------------------------------------------------------------------
%%% @doc Cowboy HTTP front-end for `gdbsp serve`.
%%%
%%% Compiles the sources, starts a running circuit, and exposes three
%%% endpoints:
%%%   POST /inputs/{table}   — feed JSONL deltas to a source table
%%%   GET  /outputs/{name}   — stream a JSONL output (chunked, long-lived)
%%%   GET  /healthz          — liveness
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_http).

-export([serve/1]).

%% @doc Run the serve subcommand: load sources, compile, start the
%% runtime and a serve-loop, then block serving HTTP until stopped.
-spec serve(map()) -> ok | {error, iolist()}.
serve(Spec) ->
    {ok, _} = application:ensure_all_started(cowboy),
    Sources = maps:get(sources, Spec),
    Outputs = maps:get(outputs, Spec),
    {Ip, Port} = maps:get(listen, Spec),
    case gdbsp_loader:load_sources(Sources) of
        {error, Reason} ->
            {error, gdbsp_cli:load_error_msg(Reason)};
        {ok, Prog} ->
            case gdbsp_loader:compile(Prog, Outputs, true) of
                {error, Reason} ->
                    {error, gdbsp_cli:compile_error_msg(Reason)};
                {ok, Compiled} ->
                    {ok, Rt} = gdbsp_runtime:start(Compiled),
                    Loop = gdbsp_runtime:serve_loop(Rt),
                    start_listener(Rt, Loop, Ip, Port)
            end
    end.

start_listener(Rt, Loop, Ip, Port) ->
    case inet:parse_address(Ip) of
        {ok, IpAddr} ->
            Dispatch = cowboy_router:compile(routes(Rt, Loop)),
            Ref = {gdbsp_http, Port},
            case cowboy:start_clear(Ref, [{ip, IpAddr}, {port, Port}],
                                    #{env => #{dispatch => Dispatch}}) of
                {ok, _} -> wait_forever();
                {error, Reason} -> {error, ["cannot listen on ", Ip, ":",
                                            iolist_to_binary(io_lib:format("~p", [Reason]))]}
            end;
        {error, _} ->
            {error, ["invalid listen address: ", Ip]}
    end.

routes(Rt, Loop) ->
    [
        {'_', [
            {"/healthz", gdbsp_http_healthz, #{}},
            {"/inputs/:table", gdbsp_http_inputs, #{runtime => Rt, loop => Loop}},
            {"/outputs/:name", gdbsp_http_outputs, #{runtime => Rt}}
        ]}
    ].

wait_forever() ->
    receive
        stop -> ok
    end.
