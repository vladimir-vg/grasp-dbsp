%%%-------------------------------------------------------------------
%%% @doc Integration tests for gdbsp_rec + gdbsp_rec_coord.
%%% Tests the Rec↔Coord message protocol: wiring → source feeding →
%%% iteration → fixpoint → consumer output.
%%%
%%% Uses stub processes to simulate body operators:
%%%   body_in  — receives deltas from Rec, forwards barrier ones to body_out
%%%   body_out — receives from body_in, echoes back to Rec as body_output
%%%
%%% For mutual recursion, body_in tracks seen barrier tags to prevent
%%% infinite echo loops across cross-body edges.
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
    sourceless_rec_basic/1,
    mutual_recursion_two_recs/1,
    sourced_negative_delta_epoch/1
]).

all() -> [
    sourced_single_rec_basic,
    sourced_single_rec_epoch_transition,
    sourceless_rec_basic,
    mutual_recursion_two_recs,
    sourced_negative_delta_epoch
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

%%====================================================================
%% Simple body stubs (single Rec)
%%====================================================================

body_entry_exit_pair(RecPid) ->
    BodyOut = spawn_link(fun() -> body_out_stub(RecPid) end),
    BodyIn = spawn_link(fun() -> body_in_stub(BodyOut) end),
    {BodyIn, BodyOut}.

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

body_out_stub(RecPid) ->
    receive
        stop -> ok;
        {delta, Meta, Deltas, _From} ->
            RecPid ! {delta, Meta, Deltas, self()},
            body_out_stub(RecPid);
        _ -> body_out_stub(RecPid)
    end.

%%====================================================================
%% Mutual body stubs (two Recs, cross-connected)
%%====================================================================

mutual_body_pair(Rec1Pid, Rec2Pid) ->
    BodyOut1 = spawn_link(fun() -> body_out_stub(Rec1Pid) end),
    BodyOut2 = spawn_link(fun() -> body_out_stub(Rec2Pid) end),
    BodyIn1 = spawn_link(fun() -> mutual_init() end),
    BodyIn2 = spawn_link(fun() -> mutual_init() end),
    BodyIn1 ! {pair, BodyIn2},
    BodyIn2 ! {pair, BodyIn1},
    BodyIn1 ! {body_out, BodyOut1},
    BodyIn2 ! {body_out, BodyOut2},
    {BodyIn1, BodyOut1, BodyIn2, BodyOut2}.

mutual_init() ->
    receive
        {pair, Peer} -> mutual_init2(Peer)
    end.

mutual_init2(Peer) ->
    receive
        {body_out, Out} -> mutual_loop(Peer, Out, undefined, [], undefined, [])
    end.

%% Peer=other body_in, Out=my body_out
%% RcvTag/RcvData=my own Rec's barrier
%% SyncTag/SyncData=peer's barrier
mutual_loop(Peer, Out, RcvTag, RcvData, SyncTag, SyncData) ->
    receive
        stop -> Out ! stop, Peer ! stop, ok;
        {sync, PeerTag, PeerData} ->
            case RcvTag of
                PeerTag ->
                    Out ! {delta, #{barrier => PeerTag}, RcvData ++ PeerData, self()},
                    mutual_loop(Peer, Out, undefined, [], undefined, []);
                _ ->
                    mutual_loop(Peer, Out, RcvTag, RcvData, PeerTag, PeerData)
            end;
        {delta, Meta, Deltas, _From} ->
            case maps:find(barrier, Meta) of
                {ok, Tag} ->
                    Peer ! {sync, Tag, Deltas},
                    case SyncTag of
                        Tag ->
                            Out ! {delta, Meta, Deltas ++ SyncData, self()},
                            mutual_loop(Peer, Out, undefined, [], undefined, []);
                        _ ->
                            mutual_loop(Peer, Out, Tag, Deltas, SyncTag, SyncData)
                    end;
                error ->
                    mutual_loop(Peer, Out, RcvTag, RcvData, SyncTag, SyncData)
            end;
        _ -> mutual_loop(Peer, Out, RcvTag, RcvData, SyncTag, SyncData)
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

%%====================================================================
%% Mutual recursion: r1(x) ← init(x), r1(x) ← r2(x), r2(x) ← r1(x)
%%====================================================================

mutual_recursion_two_recs(_Config) ->
    Consumer1 = start_collector(),
    Consumer2 = start_collector(),

    {ok, Rec1} = gdbsp_rec_proc:start_link(#{name => <<"r1">>, scc_id => 0}),
    {ok, Rec2} = gdbsp_rec_proc:start_link(#{name => <<"r2">>, scc_id => 0}),

    %% Build 4 mutual stubs: BodyIn1, BodyOut1, BodyIn2, BodyOut2
    %% BodyOut1 → Rec1 (body_output) + BodyIn2 (cross → r2 body)
    %% BodyOut2 → Rec2 (body_output) + BodyIn1 (cross → r1 body)
    %% body_in tracks seen barrier tags → prevents infinite echo loops
    {BodyIn1, BodyOut1, BodyIn2, BodyOut2} = mutual_body_pair(Rec1, Rec2),

    gen_server:call(Rec1, {set_body_inputs, [BodyIn1]}),
    gen_server:call(Rec1, {set_body_output, BodyOut1}),
    gen_server:call(Rec2, {set_body_inputs, [BodyIn2]}),
    gen_server:call(Rec2, {set_body_output, BodyOut2}),

    {ok, CoordPid} = gdbsp_rec_coord_proc:start_link(#{
        scc_id => 0,
        sourced => #{Rec1 => #{name => <<"r1">>}},
        sourceless => #{Rec2 => #{name => <<"r2">>}}}),
    gen_server:call(Rec1, {set_coordinator, CoordPid}),
    gen_server:call(Rec2, {set_coordinator, CoordPid}),
    gen_server:call(Rec1, {set_consumer, Consumer1}),
    gen_server:call(Rec2, {set_consumer, Consumer2}),

    %% Source feeds Rec1 with init data
    Src = self(),
    gen_server:call(Rec1, {set_source, Src}),
    Rec1 ! mk_delta(0, [{1, <<"x">>}], Src),
    Rec1 ! mk_barrier_delta(0, epoch_done, [], Src),
    gen_server:cast(CoordPid, {activate}),

    %% Both Recs should produce the same output
    Deltas1 = await(Consumer1, 2),
    All1 = lists:flatmap(fun({delta, _, Ds, _}) -> Ds end, Deltas1),
    true = lists:member({1, <<"x">>}, All1),

    Deltas2 = await(Consumer2, 2),
    All2 = lists:flatmap(fun({delta, _, Ds, _}) -> Ds end, Deltas2),
    true = lists:member({1, <<"x">>}, All2),

    cleanup([Rec1, Rec2, CoordPid, Consumer1, Consumer2,
             BodyIn1, BodyOut1, BodyIn2, BodyOut2]).

%%====================================================================
%% sourced_negative_delta_epoch — verifies state_reset protocol
%% Epoch 0: insert {+1, a} → fixpoint → consumer gets {+1, a}
%% Epoch 1: retract {-1, a} → coord detects negative, sends reset →
%%   Rec stores deferred_iter, sends state_reset to body →
%%   body stubs echo state_reset → Rec handles, sends CID →
%%   fixpoint → consumer gets {-1, a} (retraction propagated)
%%====================================================================

sourced_negative_delta_epoch(_Config) ->
    Consumer = start_collector(),
    {ok, RecPid} = gdbsp_rec_proc:start_link(#{name => <<"r1">>, scc_id => 0}),

    {BodyIn, BodyOut} = body_entry_exit_pair(RecPid),
    gen_server:call(RecPid, {set_body_inputs, [BodyIn]}),
    gen_server:call(RecPid, {set_body_output, BodyOut}),

    {ok, CoordPid} = gdbsp_rec_coord_proc:start_link(#{
        scc_id => 0,
        sourced => #{RecPid => #{name => <<"r1">>}},
        sourceless => #{}}),
    gen_server:call(RecPid, {set_coordinator, CoordPid}),
    gen_server:call(RecPid, {set_consumer, Consumer}),

    Src = self(),
    gen_server:call(RecPid, {set_source, Src}),

    %% Epoch 0: insert a
    RecPid ! mk_delta(0, [{1, <<"a">>}], Src),
    RecPid ! mk_barrier_delta(0, epoch_done, [], Src),
    gen_server:cast(CoordPid, {activate}),

    Batch0 = await(Consumer, 2),
    All0 = lists:flatmap(fun({delta, _, Ds, _}) -> Ds end, Batch0),
    true = lists:member({1, <<"a">>}, All0),

    %% Epoch 1: retract a — should NOT crash on negative feedback
    RecPid ! mk_delta(1, [{-1, <<"a">>}], Src),
    RecPid ! mk_barrier_delta(1, epoch_done, [], Src),

    Batch1 = await(Consumer, 2),
    All1 = lists:flatmap(fun({delta, _, Ds, _}) -> Ds end, Batch1),
    true = lists:member({-1, <<"a">>}, All1),

    cleanup([RecPid, CoordPid, Consumer, BodyIn, BodyOut]).
