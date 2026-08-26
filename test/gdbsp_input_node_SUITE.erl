%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_input_node.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_input_node_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).
-export([wiring_ack/1, forward_delta/1, forward_epoch_done/1]).

all() -> [{group, input_node}].

groups() ->
    [{input_node, [parallel], [
        wiring_ack,
        forward_delta,
        forward_epoch_done
    ]}].

wiring_ack(_Config) ->
    {ok, Node} = gdbsp_input_node:start_link(),
    Ref = make_ref(),
    Node ! {wiring_update, #{}, #{default => [self()]}, Ref, self()},
    receive
        {wiring_ack, Ref, Node} -> ok
    after 1000 ->
        error(wiring_ack_timeout)
    end,
    ok = gdbsp_input_node:stop(Node).

forward_delta(_Config) ->
    {ok, Node} = gdbsp_input_node:start_link(),
    Down = spawn_collector(self()),
    Ref = make_ref(),
    Node ! {wiring_update, #{}, #{default => [Down]}, Ref, self()},
    receive {wiring_ack, Ref, _} -> ok after 1000 -> error(wiring_ack_timeout) end,

    Meta = #{epoch => 0},
    Node ! {delta, Meta, [{1, row}], self()},
    receive
        {fwd, {delta, Meta, [{1, row}], Node}} -> ok
    after 1000 ->
        error(delta_not_forwarded)
    end,
    ok = gdbsp_input_node:stop(Node).

forward_epoch_done(_Config) ->
    {ok, Node} = gdbsp_input_node:start_link(),
    Down = spawn_collector(self()),
    Ref = make_ref(),
    Node ! {wiring_update, #{}, #{default => [Down]}, Ref, self()},
    receive {wiring_ack, Ref, _} -> ok after 1000 -> error(wiring_ack_timeout) end,

    Meta = #{epoch => 1, barrier => epoch_done},
    Node ! {delta, Meta, [], self()},
    receive
        {fwd, {delta, Meta, [], Node}} -> ok
    after 1000 ->
        error(epoch_done_not_forwarded)
    end,
    ok = gdbsp_input_node:stop(Node).

spawn_collector(Parent) ->
    spawn(fun() ->
        receive
            stop -> ok;
            Msg -> Parent ! {fwd, Msg}
        end
    end).
