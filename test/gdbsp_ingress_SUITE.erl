%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_ingress — unit-batch epoch coordination.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_ingress_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0]).

-export([
    unit_batch/1,
    multi_table_lockstep/1,
    empty_batches_for_exhausted/1,
    monotonic_epoch/1,
    exhausted_signal/1
]).

all() -> [{group, ingress}].

groups() ->
    [{ingress, [parallel], [
        unit_batch,
        multi_table_lockstep,
        empty_batches_for_exhausted,
        monotonic_epoch,
        exhausted_signal
    ]}].

%%====================================================================
%% Stub input nodes
%%====================================================================

start_stubs(Tables) ->
    maps:from_list([{T, start_stub()} || T <- Tables]).

start_stub() ->
    spawn(fun() -> stub_loop([]) end).

stub_loop(Msgs) ->
    receive
        {delta, _, _, _} = M -> stub_loop([M | Msgs]);
        {get, Ref, Parent} -> Parent ! {Ref, lists:reverse(Msgs)}, stub_loop(Msgs);
        stop -> ok
    end.

get_msgs(Pid) ->
    Ref = make_ref(),
    Pid ! {get, Ref, self()},
    receive {Ref, Msgs} -> Msgs after 2000 -> error(stub_timeout) end.

stop_stubs(Stubs) ->
    maps:foreach(fun(_T, P) -> P ! stop end, Stubs).

%% Extract the delta rows delivered in the given epoch for a stub.
deltas_for_epoch(Msgs, Epoch) ->
    lists:append(
        [D || {delta, M, D, _} <- Msgs, maps:get(epoch, M) =:= Epoch,
              not maps:is_key(barrier, M)]).

%%====================================================================
%% Tests
%%====================================================================

unit_batch(_Config) ->
    Stubs = start_stubs([<<"t">>]),
    {ok, Ing} = gdbsp_ingress:start_link(Stubs),

    ok = gdbsp_ingress:feed(Ing, <<"t">>, [{1, a}, {1, b}, {1, c}]),
    ok = gdbsp_ingress:mark_exhausted(Ing, <<"t">>),

    {ok, 1} = gdbsp_ingress:step(Ing),
    {ok, 2} = gdbsp_ingress:step(Ing),
    {ok, 3} = gdbsp_ingress:step(Ing),
    exhausted = gdbsp_ingress:step(Ing),

    Msgs = get_msgs(maps:get(<<"t">>, Stubs)),
    [{1, a}] = deltas_for_epoch(Msgs, 1),
    [{1, b}] = deltas_for_epoch(Msgs, 2),
    [{1, c}] = deltas_for_epoch(Msgs, 3),
    stop_stubs(Stubs).

multi_table_lockstep(_Config) ->
    Stubs = start_stubs([<<"a">>, <<"b">>]),
    {ok, Ing} = gdbsp_ingress:start_link(Stubs),

    ok = gdbsp_ingress:feed(Ing, <<"a">>, [{1, a1}, {1, a2}]),
    ok = gdbsp_ingress:feed(Ing, <<"b">>, [{1, b1}]),
    ok = gdbsp_ingress:mark_exhausted(Ing, <<"a">>),
    ok = gdbsp_ingress:mark_exhausted(Ing, <<"b">>),

    {ok, 1} = gdbsp_ingress:step(Ing),
    {ok, 2} = gdbsp_ingress:step(Ing),
    exhausted = gdbsp_ingress:step(Ing),

    AMsgs = get_msgs(maps:get(<<"a">>, Stubs)),
    BMsgs = get_msgs(maps:get(<<"b">>, Stubs)),
    [{1, a1}] = deltas_for_epoch(AMsgs, 1),
    [{1, b1}] = deltas_for_epoch(BMsgs, 1),
    [{1, a2}] = deltas_for_epoch(AMsgs, 2),
    [] = deltas_for_epoch(BMsgs, 2),
    stop_stubs(Stubs).

empty_batches_for_exhausted(_Config) ->
    Stubs = start_stubs([<<"a">>, <<"b">>]),
    {ok, Ing} = gdbsp_ingress:start_link(Stubs),

    ok = gdbsp_ingress:feed(Ing, <<"a">>, [{1, a1}]),
    ok = gdbsp_ingress:mark_exhausted(Ing, <<"a">>),
    ok = gdbsp_ingress:mark_exhausted(Ing, <<"b">>),

    {ok, 1} = gdbsp_ingress:step(Ing),
    exhausted = gdbsp_ingress:step(Ing),

    BMsgs = get_msgs(maps:get(<<"b">>, Stubs)),
    [] = deltas_for_epoch(BMsgs, 1),
    stop_stubs(Stubs).

monotonic_epoch(_Config) ->
    Stubs = start_stubs([<<"t">>]),
    {ok, Ing} = gdbsp_ingress:start_link(Stubs),

    ok = gdbsp_ingress:feed(Ing, <<"t">>, [{1, x}, {1, y}, {1, z}]),
    ok = gdbsp_ingress:mark_exhausted(Ing, <<"t">>),

    {ok, E1} = gdbsp_ingress:step(Ing),
    {ok, E2} = gdbsp_ingress:step(Ing),
    {ok, E3} = gdbsp_ingress:step(Ing),
    true = (E1 < E2 andalso E2 < E3),
    E3 = gdbsp_ingress:epoch(Ing),
    stop_stubs(Stubs).

exhausted_signal(_Config) ->
    Stubs = start_stubs([<<"t">>]),
    {ok, Ing} = gdbsp_ingress:start_link(Stubs),

    %% Not exhausted while no table has been marked exhausted.
    idle = gdbsp_ingress:step(Ing),
    false = gdbsp_ingress:is_exhausted(Ing),

    ok = gdbsp_ingress:mark_exhausted(Ing, <<"t">>),
    exhausted = gdbsp_ingress:step(Ing),
    true = gdbsp_ingress:is_exhausted(Ing),
    stop_stubs(Stubs).
