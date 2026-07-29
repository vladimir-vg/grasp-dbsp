%%%-------------------------------------------------------------------
%%% @doc Circuit process — spawns operators from a deploy plan and
%%% wires them into a running DBSP circuit.
%%%
%%% Accepts a single {circuit_update, Plan, Inputs, Outputs} call
%%% that atomically replaces the current circuit.
%%%
%%% Modeled after the Circuit entity in grasp-pipeline-design.md §2.2.
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

build_circuit(Plan, Inputs, Outputs, Gen, OpStates, _DoKickoff) ->
    #{wiring := Tuples, configs := Configs} = Plan,
    OpRefs = [R || R = {op, _} <- maps:keys(Configs)],

    OpPids = maps:from_list([{R, spawn_op(R, Configs, OpStates)} || R <- OpRefs]),
    RefToPid = OpPids,
    Resolve = fun(Ref) -> resolve_pid(Ref, RefToPid, Inputs, Outputs) end,

    {UpMaps, DownMaps} = build_wiring_maps(Tuples, Resolve),

    wire_all(Tuples, OpRefs, OpPids, Inputs, Outputs, UpMaps, DownMaps),

    #{gen => Gen, operators => OpPids}.

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

wrap_args(gdbsp_op_map, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(gdbsp_op_filter, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(gdbsp_op_flat_map, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(gdbsp_op_map_index, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(_, Args) -> Args.

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

resolve_pid({op, _} = R, RefToPid, _Inputs, _Outputs) ->
    maps:get(R, RefToPid, undefined);
resolve_pid({source, Name, _}, _RefToPid, Inputs, _Outputs) ->
    maps:get(Name, Inputs, undefined);
resolve_pid({output, Name, _}, _RefToPid, _Inputs, Outputs) ->
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
