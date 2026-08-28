%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_op_empty.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_empty_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([wiring_ack/1, echo_epoch_done/1, echo_iter_barrier/1, drops_rows/1]).

all() -> [{group, op_empty}].

groups() ->
    [{op_empty, [parallel], [
        wiring_ack,
        echo_epoch_done,
        echo_iter_barrier,
        drops_rows
    ]}].

wiring_ack(_Config) ->
    {ok, Node} = gdbsp_op_empty:start_link(),
    Ref = make_ref(),
    Node ! {wiring_update, #{}, #{default => [self()]}, Ref, self()},
    receive
        {wiring_ack, Ref, Node} -> ok
    after 1000 ->
        error(wiring_ack_timeout)
    end,
    ok = gdbsp_op_empty:stop(Node).

echo_epoch_done(_Config) ->
    {ok, Node} = gdbsp_op_empty:start_link(),
    Down = spawn_collector(self()),
    Ref = make_ref(),
    Node ! {wiring_update, #{}, #{default => [Down]}, Ref, self()},
    receive {wiring_ack, Ref, _} -> ok after 1000 -> error(wiring_ack_timeout) end,

    Meta = #{epoch => 3, barrier => epoch_done},
    Node ! {delta, Meta, [], self()},
    receive
        {fwd, {delta, Meta, [], Node}} -> ok
    after 1000 ->
        error(epoch_done_not_forwarded)
    end,
    ok = gdbsp_op_empty:stop(Node).

echo_iter_barrier(_Config) ->
    {ok, Node} = gdbsp_op_empty:start_link(),
    Down = spawn_collector(self()),
    Ref = make_ref(),
    Node ! {wiring_update, #{}, #{default => [Down]}, Ref, self()},
    receive {wiring_ack, Ref, _} -> ok after 1000 -> error(wiring_ack_timeout) end,

    Meta = #{epoch => 2, barrier => {iter, 2, 1}},
    Node ! {delta, Meta, [], self()},
    receive
        {fwd, {delta, Meta, [], Node}} -> ok
    after 1000 ->
        error(iter_barrier_not_forwarded)
    end,
    ok = gdbsp_op_empty:stop(Node).

drops_rows(_Config) ->
    {ok, Node} = gdbsp_op_empty:start_link(),
    Down = spawn_collector(self()),
    Ref = make_ref(),
    Node ! {wiring_update, #{}, #{default => [Down]}, Ref, self()},
    receive {wiring_ack, Ref, _} -> ok after 1000 -> error(wiring_ack_timeout) end,

    Meta = #{epoch => 0},
    Node ! {delta, Meta, [{1, row}], self()},
    receive
        {fwd, {delta, Meta, [], Node}} -> ok
    after 1000 ->
        error(rows_not_dropped)
    end,
    ok = gdbsp_op_empty:stop(Node).

spawn_collector(Parent) ->
    spawn(fun() ->
        receive
            stop -> ok;
            Msg -> Parent ! {fwd, Msg}
        end
    end).
