%%%-------------------------------------------------------------------
%%% @doc Circuit process — spawns operators from a deploy plan and
%%% wires them into a running DBSP circuit.
%%%
%%% Accepts a single {circuit_update, Plan, Inputs, Outputs} call
%%% that atomically replaces the current circuit.
%%%
%%% Supports rec and rec_output nodes for recursive DBSP.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_circuit_proc).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("gdbsp_circuit.hrl").
-include("gdbsp_debug.hrl").

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link(?MODULE, {}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({}) ->
    {ok, #{gen => 0}}.

handle_call({circuit_update, Plan, Inputs, Outputs}, _From,
            #{gen := Gen} = State) ->
    ok = stop_gen(Gen, State),
    Gen2 = Gen + 1,
    State2 = build_circuit(Plan, Inputs, Outputs, Gen2, #{}, true),
    {reply, ok, maps:merge(State2, #{gen => Gen2})};
handle_call({circuit_update_with_states, Plan, Inputs, Outputs, OpStates}, _From,
            #{gen := Gen} = State) ->
    ok = stop_gen(Gen, State),
    Gen2 = Gen + 1,
    State2 = build_circuit(Plan, Inputs, Outputs, Gen2, OpStates, true),
    {reply, ok, maps:merge(State2, #{gen => Gen2})};
handle_call({circuit_deploy, Plan, Inputs, Outputs}, _From,
            #{gen := Gen} = State) ->
    ok = stop_gen(Gen, State),
    Gen2 = Gen + 1,
    State2 = build_circuit(Plan, Inputs, Outputs, Gen2, #{}, false),
    {reply, ok, maps:merge(State2, #{gen => Gen2})};
handle_call(get_operators, _From, #{operators := Ops} = State) ->
    {reply, {ok, Ops}, State};
handle_call(stop, _From, #{gen := Gen} = State) ->
    ok = stop_gen(Gen, State),
    {stop, normal, ok, State};
handle_call(_Call, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

%%====================================================================
%% Circuit deployment
%%====================================================================

build_circuit(Plan, Inputs, Outputs, Gen, OpStates, DoKickoff) ->
    #{wiring := Tuples, configs := Configs} = Plan,
    OpRefs = [R || R = {op, _} <- maps:keys(Configs)],
    RecRefs = [R || R = {rec, _, _, _} <- maps:keys(Configs)],

    OpPids = maps:from_list([{R, spawn_op(R, Configs, OpStates)} || R <- OpRefs]),
    RecPids = maps:from_list([{R, spawn_rec(R, Configs)} || R <- RecRefs]),
    RefToPid = maps:merge(OpPids, RecPids),

    RORefs = [R || R = {rec_output, _, _, _} <- maps:keys(Configs)],
    ROToRec = rec_output_to_rec(Tuples, RORefs),

    CoordPids = spawn_coordinators(RecRefs, Configs, DoKickoff),

    Resolve = fun(Ref) ->
        resolve_pid(Ref, RefToPid, ROToRec, Inputs, Outputs)
    end,

    wire_rec_coordinators(RecPids, CoordPids),

    {UpMaps, DownMaps} = build_wiring_maps(Tuples, Resolve),

    wire_all(Tuples, OpRefs, OpPids, Inputs, Outputs, UpMaps, DownMaps),

    wire_rec_body(RecPids, Tuples, Resolve),
    wire_rec_source(RecPids, RecRefs, Tuples, Resolve, Inputs, Outputs, DoKickoff),
    wire_output_consumers(RecPids, ROToRec, Tuples, Resolve),

    AllPids = maps:merge(OpPids, RecPids),
    #{gen => Gen, operators => AllPids, recs => RecPids, coordinators => CoordPids}.
%%====================================================================
%% Process spawning
%%====================================================================

spawn_op({op, _} = Ref, Configs, OpStates) ->
    #{mod := Mod, args := Args0} = maps:get(Ref, Configs),
    Args = wrap_args(Mod, Args0),
    case maps:find(Ref, OpStates) of
        {ok, ChunkData} ->
            {InitState, _, _} = Mod:init(Args),
            FullState = maps:merge(InitState, ChunkData),
            {ok, Pid} = gdbsp_op_proc:start_link(Mod, Args, FullState),
            Pid;
        error ->
            {ok, Pid} = gdbsp_op_proc:start_link(Mod, Args),
            Pid
    end.

spawn_rec({rec, Name, SccId, _} = Ref, Configs) ->
    #{name := Name, scc_id := SccId} = maps:get(Ref, Configs),
    {ok, Pid} = gdbsp_rec_proc:start_link(#{name => Name, scc_id => SccId}),
    Pid.

wrap_args(gdbsp_op_map, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(gdbsp_op_filter, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(gdbsp_op_flat_map, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(gdbsp_op_map_index, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(_, Args) -> Args.

%%====================================================================
%% Rec wiring helpers
%%====================================================================

rec_output_to_rec(Tuples, RORefs) ->
    ROfold = lists:foldl(
        fun({SR, _SL, {rec_output, Name, SccId, _} = RR, _RL}, Acc) ->
            Acc#{RR => SR};
           (_, Acc) -> Acc
        end, #{}, Tuples),
    %% Also populate from RORefs: scan wiring for rec_output → rec edges
    RecOutputMap = maps:from_list([{R, undefined} || R <- RORefs]),
    RecMap = lists:foldl(
        fun({SR, _SL, RR, _RL}, Acc) ->
            case maps:is_key(RR, RecOutputMap) of
                true -> Acc#{RR => SR};
                false -> Acc
            end
        end, ROfold, Tuples),
    RecMap.

spawn_coordinators(RecRefs, Configs, _DoKickoff) ->
    Grouped = group_by_scc(RecRefs, Configs),
    maps:fold(
        fun(SccId, {Sourced, Sourceless}, Acc) ->
            {ok, Pid} = gdbsp_rec_coord_proc:start_link(#{
                scc_id => SccId, sourced => Sourced, sourceless => Sourceless}),
            Acc#{SccId => Pid}
        end, #{}, Grouped).

group_by_scc(RecRefs, Configs) ->
    lists:foldl(
        fun({rec, Name, SccId, _} = Ref, Acc) ->
            Config = maps:get(Ref, Configs),
            IsSourced = maps:get(sourced, Config, false),
            {Sourced0, Sourceless0} = maps:get(SccId, Acc, {#{}, #{}}),
            case IsSourced of
                true ->
                    Acc#{SccId => {Sourced0#{Ref => #{name => Name}}, Sourceless0}};
                false ->
                    Acc#{SccId => {Sourced0, Sourceless0#{Ref => #{name => Name}}}}
            end
        end, #{}, RecRefs).

wire_rec_coordinators(RecPids, CoordPids) ->
    maps:foreach(
        fun({rec, _Name, SccId, _}, RecPid) ->
            CoordPid = maps:get(SccId, CoordPids),
            gen_server:call(RecPid, {set_coordinator, CoordPid})
        end, RecPids).

wire_rec_body(RecPids, Tuples, Resolve) ->
    maps:foreach(
        fun({rec, Name, SccId, _} = RecRef, RecPid) ->
            BodyInputPids = [Resolve(RR) || {SR, _SL, RR, _RL} <- Tuples,
                                              SR =:= RecRef,
                                              element(1, RR) =:= op],
            gen_server:call(RecPid, {set_body_inputs, BodyInputPids}),
            BodyOutputPids = [Resolve(SR) || {SR, SL, RR, _RL} <- Tuples,
                                              RR =:= RecRef, SL =:= body_output],
            BodyOut = case BodyOutputPids of
                [Pid | _] -> Pid;
                [] -> RecPid
            end,
            gen_server:call(RecPid, {set_body_output, BodyOut})
        end, RecPids).

wire_rec_source(RecPids, RecRefs, Tuples, Resolve, Inputs, Outputs, DoKickoff) ->
    maps:foreach(
        fun({rec, Name, SccId, _} = RecRef, RecPid) ->
            SrcPids = [Resolve(SR) || {SR, SL, RR, _RL} <- Tuples,
                                        RR =:= RecRef, SL =:= source],
            case SrcPids of
                [SrcPid | _] when SrcPid =/= undefined ->
                    gen_server:call(RecPid, {set_source, SrcPid});
                _ ->
                    case DoKickoff of
                        true ->
                            synthetic_source_done(RecPid);
                        false -> ok
                    end
            end
        end, RecPids).

synthetic_source_done(RecPid) ->
    {ok, CoordPid} = gen_server:call(RecPid, get_coordinator),
    Epoch = 0,
    CoordPid ! {streaming_started, Epoch, RecPid},
    CoordPid ! {source_done, Epoch, false, RecPid},
    ok.

wire_output_consumers(RecPids, ROToRec, Tuples, Resolve) ->
    maps:foreach(
        fun({rec, _Name, _SccId, _} = RecRef, RecPid) ->
            OutputConsumers = [Resolve(RR) || {SR, _SL, RR, _RL} <- Tuples,
                                                SR =:= RecRef,
                                                element(1, RR) =:= output],
            lists:foreach(
                fun(C) ->
                    gen_server:call(RecPid, {set_consumer, C})
                end, OutputConsumers)
        end, RecPids).

%%====================================================================
%% Wiring maps
%%====================================================================

build_wiring_maps(Tuples, Resolve) ->
    UpMaps = lists:foldl(
        fun({SR, _SL, RR, RL}, Acc) ->
            RcvrPid = Resolve(RR),
            case is_pid(RcvrPid) of
                true ->
                    SndrPid = Resolve(SR),
                    case is_pid(SndrPid) of
                        true ->
                            Up0 = maps:get(RR, Acc, #{}),
                            Acc#{RR => Up0#{SndrPid => RL}};
                        false -> Acc
                    end;
                false -> Acc
            end
        end, #{}, Tuples),
    DownMaps = lists:foldl(
        fun({SR, SL, RR, _RL}, Acc) ->
            RcvrPid = Resolve(RR),
            case is_pid(RcvrPid) of
                true ->
                    SndrPid = Resolve(SR),
                    case is_pid(SndrPid) of
                        true ->
                            Down0 = maps:get(SR, Acc, #{}),
                            Existing = maps:get(SL, Down0, []),
                            Acc#{SR => Down0#{SL => [RcvrPid | Existing]}};
                        false -> Acc
                    end;
                false -> Acc
            end
        end, #{}, Tuples),
    {UpMaps, DownMaps}.

resolve_pid({op, _} = R, RefToPid, _ROToRec, _Inputs, _Outputs) ->
    maps:get(R, RefToPid, undefined);
resolve_pid({rec, _, _, _} = R, RefToPid, _ROToRec, _Inputs, _Outputs) ->
    maps:get(R, RefToPid, undefined);
resolve_pid({rec_output, _, _, _} = R, _RefToPid, ROToRec, _Inputs, _Outputs) ->
    RecRef = maps:get(R, ROToRec, undefined),
    case RecRef of
        undefined -> undefined;
        _ -> maps:get(RecRef, _RefToPid, undefined)
    end;
resolve_pid({source, Name, _}, _RefToPid, _ROToRec, Inputs, _Outputs) ->
    maps:get(Name, Inputs, undefined);
resolve_pid({output, Name, _}, _RefToPid, _ROToRec, _Inputs, Outputs) ->
    maps:get(Name, Outputs, undefined).

%%====================================================================
%% Wire operators
%%====================================================================

wire_all(Tuples, OpRefs, OpPids, Inputs, Outputs, UpMaps, DownMaps) ->
    lists:foreach(
        fun(Ref) ->
            Pid = maps:get(Ref, OpPids),
            Up = maps:get(Ref, UpMaps, #{}),
            Down = maps:get(Ref, DownMaps, #{}),
            Pid ! {wiring_update, Up, Down}
        end, OpRefs),
    SourceRefs = lists:usort(
        [SR || {SR, _SL, _RR, _RL} <- Tuples, element(1, SR) =:= source]),
    lists:foreach(
        fun({source, Name, _} = Ref) ->
            case maps:find(Name, Inputs) of
                {ok, SrcPid} ->
                    Down = maps:get(Ref, DownMaps, #{}),
                    SrcPid ! {wiring_update, #{}, Down};
                error -> ok
            end
        end, SourceRefs),
    OutputRefs = lists:usort(
        [RR || {_SR, _SL, RR, _RL} <- Tuples, element(1, RR) =:= output]),
    lists:foreach(
            fun({output, Name, _} = Ref) ->
            case maps:find(Name, Outputs) of
                {ok, SubPid} ->
                    Up = maps:get(Ref, UpMaps, #{}),
                    SubPid ! {wiring_update, Up, #{}};
                error -> ok
            end
        end, OutputRefs).

%%====================================================================
%% Helpers
%%====================================================================

stop_gen(0, _State) -> ok;
stop_gen(_Gen, #{operators := Ops}) ->
    maps:foreach(fun(_, P) -> catch gen_server:stop(P) end, Ops),
    ok.
