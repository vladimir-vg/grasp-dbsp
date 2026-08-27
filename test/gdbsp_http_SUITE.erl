%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_http — the `gdbsp serve` HTTP front-end.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_http_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    healthz_200/1,
    post_input_streams_output/1,
    post_unknown_table_404/1,
    get_unknown_output_404/1,
    post_bad_line_400/1
]).

all() -> [healthz_200,
          post_input_streams_output,
          post_unknown_table_404,
          get_unknown_output_404,
          post_bad_line_400].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(jsx),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    case get(server_pid) of
        Pid when is_pid(Pid) -> catch exit(Pid, kill), erase(server_pid);
        _ -> ok
    end,
    ok.

%%====================================================================
%% Helpers
%%====================================================================

source() ->
    "src := source(\"data\")\n"
    "src :: stream(struct(\"id\": i64, \"dept\": i64))\n"
    "out := distinct(src)\n".

input_jsonl() ->
    <<"[1, {\"id\": \"1\", \"dept\": \"10\"}]\n"
      "[1, {\"id\": \"2\", \"dept\": \"20\"}]\n">>.

write_file(Dir, Name, Content) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, Content),
    Path.

free_port() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(L),
    gen_tcp:close(L),
    Port.

start_server(Config) ->
    Dir = ?config(priv_dir, Config),
    Src = write_file(Dir, "a.gdbsp", source()),
    Port = free_port(),
    Pid = spawn(fun() ->
        gdbsp_http:serve(#{command => serve, sources => [Src],
                           outputs => [<<"out">>],
                           listen => {"127.0.0.1", Port}})
    end),
    put(server_pid, Pid),
    ok = await_listening(Port),
    {Pid, Port}.

await_listening(Port) ->
    await_listening(Port, 100).

await_listening(_Port, 0) ->
    error(listening_timeout);
await_listening(Port, N) ->
    case gun:open("127.0.0.1", Port) of
        {ok, Conn} ->
            case gun:await_up(Conn) of
                {ok, _} -> gun:close(Conn), ok;
                _ -> gun:close(Conn), timer:sleep(20), await_listening(Port, N - 1)
            end;
        _ -> timer:sleep(20), await_listening(Port, N - 1)
    end.

%% Fire a complete (short-lived) request and return {Status, Body}.
request(Port, Method, Path) ->
    request(Port, Method, Path, []).
request(Port, Method, Path, Body) ->
    {ok, Conn} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Conn),
    StreamRef = case Method of
        get -> gun:get(Conn, Path);
        post -> gun:post(Conn, Path, [{<<"content-type">>, <<"application/x-ndjson">>}], Body)
    end,
    {Status, RespBody} = finish_request(Conn, StreamRef, 5000),
    gun:close(Conn),
    {Status, RespBody}.

finish_request(Conn, StreamRef, Timeout) ->
    case gun:await(Conn, StreamRef, Timeout) of
        {response, fin, Status, _Headers} ->
            {Status, <<>>};
        {response, nofin, Status, _Headers} ->
            read_body(Conn, StreamRef, <<>>, Status);
        {error, Reason} -> error({gun_error, Reason})
    end.

read_body(Conn, StreamRef, Acc, Status) ->
    case gun:await_body(Conn, StreamRef) of
        {ok, B} -> {Status, <<Acc/binary, B/binary>>};
        {more, B} -> read_body(Conn, StreamRef, <<Acc/binary, B/binary>>, Status)
    end.

%% Read N newline-terminated lines from a streaming response.
recv_n_lines(Conn, StreamRef, N) ->
    {Lines, _Rest} = recv_n_lines(Conn, StreamRef, N, <<>>, []),
    Lines.

recv_n_lines(_Conn, _S, 0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
recv_n_lines(Conn, S, N, Buf, Acc) ->
    case binary:split(Buf, <<"\n">>) of
        [Line, Rest] ->
            recv_n_lines(Conn, S, N - 1, Rest, [Line | Acc]);
        [_] ->
            Data = recv_data(Conn, S),
            recv_n_lines(Conn, S, N, <<Buf/binary, Data/binary>>, Acc)
    end.

recv_data(Conn, S) ->
    receive
        {gun_data, Conn, S, _IsFin, Data} -> Data
    after 5000 ->
        error(recv_timeout)
    end.

decode(Bin) -> jsx:decode(Bin, [return_maps]).

%%====================================================================
%% Test cases
%%====================================================================

healthz_200(Config) ->
    {_Pid, Port} = start_server(Config),
    {200, <<"ok">>} = request(Port, get, "/healthz").

post_input_streams_output(Config) ->
    {_Pid, Port} = start_server(Config),

    {ok, Conn} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(Conn),
    StreamRef = gun:get(Conn, "/outputs/out"),
    {response, nofin, 200, _} = gun:await(Conn, StreamRef),

    %% Subscribe first, then feed: the sink broadcasts the header on
    %% subscribe and each delta as it flows.
    {204, <<>>} = request(Port, post, "/inputs/data", input_jsonl()),

    [HeaderLine, D1, D2] = recv_n_lines(Conn, StreamRef, 3),
    gun:close(Conn),

    #{<<"id">> := <<"i64">>, <<"dept">> := <<"i64">>} = decode(HeaderLine),
    [1, #{<<"id">> := <<"1">>, <<"dept">> := <<"10">>}] = decode(D1),
    [1, #{<<"id">> := <<"2">>, <<"dept">> := <<"20">>}] = decode(D2).

post_unknown_table_404(Config) ->
    {_Pid, Port} = start_server(Config),
    {404, _} = request(Port, post, "/inputs/nope", input_jsonl()).

get_unknown_output_404(Config) ->
    {_Pid, Port} = start_server(Config),
    {404, _} = request(Port, get, "/outputs/nope").

post_bad_line_400(Config) ->
    {_Pid, Port} = start_server(Config),
    Body = <<"[1, {\"id\": \"1\", \"dept\": \"10\"}]\nnot-json\n">>,
    {400, Resp} = request(Port, post, "/inputs/data", Body),
    <<"line 2: ", _/binary>> = Resp.
