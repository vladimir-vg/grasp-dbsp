%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_output_sink.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_output_sink_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_type.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1]).

-export([
    header_then_data_lines/1,
    raw_delta_retention/1,
    subscriber_broadcast/1,
    epoch_done_notification/1,
    await_epoch_done_blocks/1
]).

all() -> [{group, sink}].

groups() ->
    [{sink, [parallel], [
        header_then_data_lines,
        raw_delta_retention,
        subscriber_broadcast,
        epoch_done_notification,
        await_epoch_done_blocks
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(jsx),
    Config.

end_per_suite(_Config) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

type() ->
    {struct, #{<<"id">> => i64, <<"name">> => {string, <<"UTF-8">>}}, exact}.

row(Id, Name) ->
    {1, {value, type(), #{
        <<"id">> => {value, i64, Id},
        <<"name">> => {value, {string, <<"UTF-8">>}, Name}
    }}}.

send_delta(Pid, Epoch, Deltas) ->
    Pid ! {delta, #{epoch => Epoch}, Deltas, self()}.

send_done(Pid, Epoch) ->
    Pid ! {delta, #{epoch => Epoch, barrier => epoch_done}, [], self()}.

%% Subscriber forwards every received message to Parent as {sub, Msg}.
start_sub(Parent) ->
    spawn(fun() -> sub_loop(Parent) end).

sub_loop(Parent) ->
    receive
        stop -> ok;
        Msg -> Parent ! {sub, Msg}, sub_loop(Parent)
    end.

%%====================================================================
%% Tests
%%====================================================================

header_then_data_lines(_Config) ->
    {ok, Sink} = gdbsp_output_sink:start_link(type()),
    Sub = start_sub(self()),
    ok = gdbsp_output_sink:subscribe(Sink, Sub),

    {sub, {output_header, Header}} = await_sub(),
    #{<<"id">> := <<"i64">>,
      <<"name">> := #{<<"string">> := #{<<"encoding">> := <<"UTF-8">>}}} = Header,

    send_delta(Sink, 0, [row(1, <<"a">>)]),
    {sub, {output_line, [1, #{<<"id">> := <<"1">>}]}} = await_sub(),
    ok = gdbsp_output_sink:stop(Sink).

raw_delta_retention(_Config) ->
    {ok, Sink} = gdbsp_output_sink:start_link(type()),
    send_delta(Sink, 0, [row(1, <<"a">>), row(2, <<"b">>)]),
    send_done(Sink, 0),
    ok = gdbsp_output_sink:await_epoch_done(Sink, 0, 1000),

    Raw = gdbsp_output_sink:get_by_epoch(Sink, 0),
    [{1, _}, {1, _}] = Raw,

    Lines = gdbsp_output_sink:get_lines_by_epoch(Sink, 0),
    [LineA, LineB] = Lines,
    [1, #{<<"id">> := <<"1">>}] = LineA,
    [1, #{<<"id">> := <<"2">>}] = LineB,
    ok = gdbsp_output_sink:stop(Sink).

subscriber_broadcast(_Config) ->
    {ok, Sink} = gdbsp_output_sink:start_link(type()),
    Sub = start_sub(self()),
    ok = gdbsp_output_sink:subscribe(Sink, Sub),
    {sub, {output_header, _}} = await_sub(),

    send_delta(Sink, 0, [row(7, <<"x">>)]),
    {sub, {output_line, [1, #{<<"id">> := <<"7">>, <<"name">> := <<"x">>}]}} =
        await_sub(),
    ok = gdbsp_output_sink:stop(Sink).

epoch_done_notification(_Config) ->
    {ok, Sink} = gdbsp_output_sink:start_link(type()),
    Sub = start_sub(self()),
    ok = gdbsp_output_sink:subscribe(Sink, Sub),
    {sub, {output_header, _}} = await_sub(),

    send_done(Sink, 3),
    {sub, {output_epoch_done, 3}} = await_sub(),
    ok = gdbsp_output_sink:stop(Sink).

await_epoch_done_blocks(_Config) ->
    {ok, Sink} = gdbsp_output_sink:start_link(type()),
    spawn(fun() ->
        timer:sleep(50),
        send_done(Sink, 1)
    end),
    ok = gdbsp_output_sink:await_epoch_done(Sink, 1, 5000),
    ok = gdbsp_output_sink:stop(Sink).

await_sub() ->
    receive
        {sub, Msg} -> {sub, Msg}
    after 2000 ->
        error(await_sub_timeout)
    end.
