%%%-------------------------------------------------------------------
%%% @doc Integration tests for gdbsp_rec + gdbsp_rec_coord.
%%% Tests the Rec↔Coord message protocol: wiring → source feeding →
%%% iteration → fixpoint → consumer output.
%%%
%%% Uses two stub processes to simulate body operators:
%%%   body_in  — receives deltas from Rec (body_input), forwards barrier ones to body_out
%%%   body_out — receives from body_in, echoes back to Rec as body_output
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_rec_integration_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    sourced_single_rec_basic/1,
    sourced_single_rec_epoch_transition/1,
    sourceless_rec_basic/1
]).

all() -> [
    sourced_single_rec_basic,
    sourced_single_rec_epoch_transition,
    sourceless_rec_basic
].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.
init_per_testcase(_TestCase, Config) -> Config.
end_per_testcase(_TestCase, _Config) -> ok.

%%====================================================================
%% Helpers
%%====================================================================

start_collector() ->
    Parent = self(),
    spawn_link(fun() -> col_loop(Parent, []) end).

col_loop(Parent, Msgs) ->
    receive
        {drain, Ref} ->
            Parent ! {Ref, lists:reverse(Msgs)},
            col_loop(Parent, []);
        {await, Min, Ref} when length(Msgs) >= Min ->
            Parent ! {Ref, lists:reverse(Msgs)},
            col_loop(Parent, []);
        {await, Min, Ref} ->
            col_loop_await(Parent, Msgs, Min, Ref);
        stop -> ok;
        Msg -> col_loop(Parent, [Msg | Msgs])
    end.

col_loop_await(Parent, Msgs, Min, Ref) ->
    receive
        stop -> Parent ! {Ref, lists:reverse(Msgs)}, ok;
        Msg ->
            Msgs2 = [Msg | Msgs],
            case length(Msgs2) >= Min of
                true  -> Parent ! {Ref, lists:reverse(Msgs2)}, col_loop(Parent, []);
                false -> col_loop_await(Parent, Msgs2, Min, Ref)
            end
    end.

await(Pid, Min) ->
    Ref = make_ref(),
    Pid ! {await, Min, Ref},
    receive {Ref, Msgs} -> Msgs
    after 5000 -> error({await_timeout, Min})
    end.

cleanup(Pids) ->
    [catch stop(P) || P <- Pids, is_process_alive(P)],
    ok.

stop(Pid) -> Pid ! stop.

mk_delta(Epoch, Deltas, From) ->
    {delta, #{epoch => Epoch}, Deltas, From}.

mk_barrier_delta(Epoch, Tag, Deltas, From) ->
    {delta, #{epoch => Epoch, barrier => Tag}, Deltas, From}.

%% Spawn body_in + body_out pair and wire them.
%% body_in receives from Rec, forwards barrier deltas to body_out.
%% body_out echoes back to Rec as body_output.
body_entry_exit_pair(RecPid) ->
    BodyOut = spawn_link(fun() -> body_out_stub(RecPid) end),
    BodyIn = spawn_link(fun() -> body_in_stub(BodyOut) end),
    {BodyIn, BodyOut}.

%% body_in: receives from Rec, forwards barrrier deltas to body_out
body_in_stub(BodyOut) ->
    receive
        stop -> BodyOut ! stop, ok;
        {delta, Meta, _Deltas, _From} ->
            case maps:find(barrier, Meta) of
                {ok, _Tag} ->
                    BodyOut ! {delta, Meta, _Deltas, self()};
                error -> ok
            end,
            body_in_stub(BodyOut);
        _ -> body_in_stub(BodyOut)
    end.

%% body_out: receives from body_in, echoes back to Rec
body_out_stub(RecPid) ->
    receive
        stop -> ok;
        {delta, Meta, Deltas, _From} ->
            RecPid ! {delta, Meta, Deltas, self()},
            body_out_stub(RecPid);
        _ -> body_out_stub(RecPid)
    end.

%%====================================================================
%% Tests
%%====================================================================

sourced_single_rec_basic(_Config) ->
    Consumer = start_collector(),
    {ok, RecPid} = gdbsp_rec_proc:start_link(#{name => <<"path">>, scc_id => 0}),

    {BodyIn, BodyOut} = body_entry_exit_pair(RecPid),
    gen_server:call(RecPid, {set_body_inputs, [BodyIn]}),
    gen_server:call(RecPid, {set_body_output, BodyOut}),

    {ok, CoordPid} = gdbsp_rec_coord_proc:start_link(#{
        scc_id => 0,
        sourced => #{RecPid => #{name => <<"path">>}},
        sourceless => #{}}),
    gen_server:call(RecPid, {set_coordinator, CoordPid}),
    gen_server:call(RecPid, {set_consumer, Consumer}),

    Src = self(),
    gen_server:call(RecPid, {set_source, Src}),

    RecPid ! mk_delta(0, [{1, <<"a">>}, {1, <<"b">>}], Src),
    RecPid ! mk_barrier_delta(0, epoch_done, [], Src),
    gen_server:cast(CoordPid, {activate}),

    ConsumerDeltas = await(Consumer, 2),
    All = lists:flatmap(fun({delta, _, Ds, _}) -> Ds end, ConsumerDeltas),
    true = lists:member({1, <<"a">>}, All),
    true = lists:member({1, <<"b">>}, All),

    cleanup([RecPid, CoordPid, Consumer, BodyIn, BodyOut]).

sourced_single_rec_epoch_transition(_Config) ->
    Consumer = start_collector(),
    {ok, RecPid} = gdbsp_rec_proc:start_link(#{name => <<"r">>, scc_id => 0}),

    {BodyIn, BodyOut} = body_entry_exit_pair(RecPid),
    gen_server:call(RecPid, {set_body_inputs, [BodyIn]}),
    gen_server:call(RecPid, {set_body_output, BodyOut}),

    {ok, CoordPid} = gdbsp_rec_coord_proc:start_link(#{
        scc_id => 0,
        sourced => #{RecPid => #{name => <<"r">>}},
        sourceless => #{}}),
    gen_server:call(RecPid, {set_coordinator, CoordPid}),
    gen_server:call(RecPid, {set_consumer, Consumer}),

    Src = self(),
    gen_server:call(RecPid, {set_source, Src}),

    %% Epoch 0
    RecPid ! mk_delta(0, [{1, <<"x">>}], Src),
    RecPid ! mk_barrier_delta(0, epoch_done, [], Src),
    gen_server:cast(CoordPid, {activate}),
    Batch0 = await(Consumer, 2),
    All0 = lists:flatmap(fun({delta, _, Ds, _}) -> Ds end, Batch0),
    true = lists:member({1, <<"x">>}, All0),

    %% Epoch 1
    RecPid ! mk_delta(1, [{1, <<"y">>}], Src),
    RecPid ! mk_barrier_delta(1, epoch_done, [], Src),
    Batch1 = await(Consumer, 2),
    All1 = lists:flatmap(fun({delta, _, Ds, _}) -> Ds end, Batch1),
    true = lists:member({1, <<"y">>}, All1),

    cleanup([RecPid, CoordPid, Consumer, BodyIn, BodyOut]).

sourceless_rec_basic(_Config) ->
    Consumer = start_collector(),
    {ok, RecPid} = gdbsp_rec_proc:start_link(#{name => <<"r">>, scc_id => 0}),

    {BodyIn, BodyOut} = body_entry_exit_pair(RecPid),
    gen_server:call(RecPid, {set_body_inputs, [BodyIn]}),
    gen_server:call(RecPid, {set_body_output, BodyOut}),

    {ok, CoordPid} = gdbsp_rec_coord_proc:start_link(#{
        scc_id => 0,
        sourced => #{},
        sourceless => #{RecPid => #{name => <<"r">>}}}),
    gen_server:call(RecPid, {set_coordinator, CoordPid}),
    gen_server:call(RecPid, {set_consumer, Consumer}),

    gen_server:cast(CoordPid, {activate}),

    ConsumerDeltas = await(Consumer, 1),
    All = lists:flatmap(fun({delta, _, Ds, _}) -> Ds end, ConsumerDeltas),
    [] = All,

    cleanup([RecPid, CoordPid, Consumer, BodyIn, BodyOut]).

