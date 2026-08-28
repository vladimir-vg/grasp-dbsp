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

handle_call({circuit_update, Plan, Inputs, Outputs, Empties}, _From,
            #{gen := Gen} = State) ->
    ok = stop_gen(Gen, State),
    Gen2 = Gen + 1,
    State2 = build_circuit(Plan, Inputs, Outputs, Empties, Gen2, #{}, true),
    {reply, ok, maps:merge(State2, #{gen => Gen2})};
handle_call({circuit_update_with_states, Plan, Inputs, Outputs, OpStates, Empties}, _From,
            #{gen := Gen} = State) ->
    ok = stop_gen(Gen, State),
    Gen2 = Gen + 1,
    State2 = build_circuit(Plan, Inputs, Outputs, Empties, Gen2, OpStates, true),
    {reply, ok, maps:merge(State2, #{gen => Gen2})};
handle_call({circuit_deploy, Plan, Inputs, Outputs, Empties}, _From,
            #{gen := Gen} = State) ->
    ok = stop_gen(Gen, State),
    Gen2 = Gen + 1,
    State2 = build_circuit(Plan, Inputs, Outputs, Empties, Gen2, #{}, false),
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

build_circuit(Plan, Inputs, Outputs, Empties, Gen, OpStates, DoKickoff) ->
    #{wiring := Tuples, configs := Configs} = Plan,
    OpRefs = [R || R = {op, _} <- maps:keys(Configs)],
    OpPids = maps:from_list([{R, spawn_op(R, Configs, OpStates)} || R <- OpRefs]),
    RecRefs = [R || R = {rec, _, _, _} <- maps:keys(Configs)],
    RecPids = maps:from_list([{R, spawn_rec(R, Configs)} || R <- RecRefs]),
    EmptyRefs = [R || R = {empty, _, _} <- maps:keys(Configs)],
    EmptyPids = maps:from_list([{R, spawn_empty(R)} || R <- EmptyRefs]),
    EmptyByScc = maps:fold(
        fun({empty, _, _} = Ref, Pid, Acc) ->
            SccId = maps:get(scc_id, maps:get(Ref, Configs)),
            maps:update_with(SccId, fun(L) -> [Pid | L] end, [Pid], Acc)
        end, #{}, EmptyPids),
    RefToPid = maps:merge(maps:merge(OpPids, RecPids), EmptyPids),

    RORefs = lists:usort([SR || {SR, _, _, _} <- Tuples, element(1, SR) =:= rec_output]),
    ROToRec = rec_output_to_rec(RecRefs, RORefs, Configs),

    CoordPids = spawn_coordinators(RecPids, Configs),

    ResolveStd = fun(Ref) ->
        resolve_pid(Ref, RefToPid, #{}, Inputs, Outputs, Empties)
    end,
    ResolveWithRO = fun(Ref) ->
        resolve_pid(Ref, RefToPid, ROToRec, Inputs, Outputs, Empties)
    end,

    wire_rec_coordinators(RecPids, CoordPids),

    {UpMaps, DownMaps} = build_wiring_maps(Tuples, ResolveWithRO),

    wire_all(Tuples, OpRefs, OpPids, EmptyRefs, EmptyPids, Inputs, Outputs, Empties,
             UpMaps, DownMaps),
    validate_wiring(OpPids, RecPids, EmptyPids, Inputs, Outputs, Empties),

    wire_rec_body(RecPids, Tuples, ResolveStd, EmptyByScc),
    wire_rec_source(RecPids, RecRefs, Tuples, ResolveWithRO, Inputs, Outputs, DoKickoff),
    wire_output_consumers(RecPids, ROToRec, Tuples, ResolveWithRO),

    AllPids = maps:merge(maps:merge(OpPids, RecPids), EmptyPids),
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

spawn_empty(_Ref) ->
    {ok, Pid} = gdbsp_op_empty:start_link(),
    Pid.

wrap_args(gdbsp_op_map, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(gdbsp_op_filter, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(gdbsp_op_flat_map, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(gdbsp_op_map_index, Args) when is_function(Args) -> #{'fun' => Args};
wrap_args(_, Args) -> Args.

%%====================================================================
%% Rec wiring helpers
%%====================================================================

rec_output_to_rec(RecRefs, RORefs, Configs) ->
    SccIdToRec = lists:foldl(
        fun({rec, _Name, SccId, _} = RecRef, Acc) ->
            Config = maps:get(RecRef, Configs),
            Meta = maps:get(meta, Config, #{}),
            HasBodyOut = maps:get(has_body_out, Meta, false),
            case HasBodyOut of
                true ->
                    Acc#{SccId => RecRef};
                false ->
                    case maps:is_key(SccId, Acc) of
                        true -> Acc;
                        false -> Acc#{SccId => RecRef}
                    end
            end
        end, #{}, RecRefs),
    maps:from_list(
        lists:filtermap(
            fun({rec_output, _Name, SccId, _} = RORef) ->
                case maps:find(SccId, SccIdToRec) of
                    {ok, RecRef} -> {true, {RORef, RecRef}};
                    error -> false
                end
            end, RORefs)).

spawn_coordinators(RecPids, Configs) ->
    Grouped = group_by_scc(RecPids, Configs),
    maps:fold(
        fun(SccId, {Sourced, Sourceless}, Acc) ->
            {ok, Pid} = gdbsp_rec_coord_proc:start_link(#{
                scc_id => SccId, sourced => Sourced, sourceless => Sourceless}),
            Acc#{SccId => Pid}
        end, #{}, Grouped).

group_by_scc(RecPids, Configs) ->
    maps:fold(
        fun({rec, Name, SccId, _} = Ref, RecPid, Acc) ->
            Config = maps:get(Ref, Configs),
            IsSourced = maps:get(sourced, Config, false),
            {Sourced0, Sourceless0} = maps:get(SccId, Acc, {#{}, #{}}),
            case IsSourced of
                true ->
                    Acc#{SccId => {Sourced0#{RecPid => #{name => Name}}, Sourceless0}};
                false ->
                    Acc#{SccId => {Sourced0, Sourceless0#{RecPid => #{name => Name}}}}
            end
        end, #{}, RecPids).

wire_rec_coordinators(RecPids, CoordPids) ->
    maps:foreach(
        fun({rec, _Name, SccId, _}, RecPid) ->
            CoordPid = maps:get(SccId, CoordPids),
            gen_server:call(RecPid, {set_coordinator, CoordPid})
        end, RecPids).

wire_rec_body(RecPids, Tuples, Resolve, EmptyByScc) ->
    FirstRecNames = first_rec_names(RecPids),
    maps:foreach(
        fun({rec, Name, SccId, _} = RecRef, RecPid) ->
            BodyInputPids = [Resolve(RR) || {SR, _SL, RR, _RL} <- Tuples,
                                              SR =:= RecRef,
                                              element(1, RR) =:= op],
            ExtraEmpties = case maps:get(SccId, FirstRecNames) =:= Name of
                true -> lists:usort(maps:get(SccId, EmptyByScc, []));
                false -> []
            end,
            gen_server:call(RecPid, {set_body_inputs, BodyInputPids ++ ExtraEmpties}),
            BodyOutputPids = [Resolve(SR) || {SR, _SL, RR, RL} <- Tuples,
                                              RR =:= RecRef, RL =:= body_output],
            BodyOut = case BodyOutputPids of
                [Pid | _] -> Pid;
                [] -> RecPid
            end,
            gen_server:call(RecPid, {set_body_output, BodyOut})
        end, RecPids).

%% Deterministically pick the lexicographically-smallest rec name per SCC,
%% so body-internal empties attach to exactly one rec of the SCC.
first_rec_names(RecPids) ->
    Pairs = [{SccId, Name} || {{rec, Name, SccId, _}, _} <- maps:to_list(RecPids)],
    lists:foldl(
        fun({SccId, Name}, Acc) ->
            case maps:find(SccId, Acc) of
                {ok, Min} when Min =< Name -> Acc;
                _ -> Acc#{SccId => Name}
            end
        end, #{}, Pairs).

wire_rec_source(RecPids, RecRefs, Tuples, Resolve, Inputs, Outputs, DoKickoff) ->
    maps:foreach(
        fun({rec, Name, SccId, _} = RecRef, RecPid) ->
            SrcPids = [Resolve(SR) || {SR, _SL, RR, RL} <- Tuples,
                                        RR =:= RecRef, RL =:= source],
            case SrcPids of
                [SrcPid | ExtraSrcPids] when SrcPid =/= undefined ->
                    gen_server:call(RecPid, {set_source, SrcPid}),
                    lists:foreach(
                        fun(ExtraPid) ->
                            gen_server:call(RecPid, {add_extra_source, ExtraPid})
                        end, ExtraSrcPids);
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
    RecRefToRecPid = maps:from_list([{RecRef, RecPid} || {RecRef, RecPid} <- maps:to_list(RecPids)]),
    RecConsumerPids = build_rec_consumers(Tuples, ROToRec, RecRefToRecPid),
    maps:foreach(
        fun({rec, _Name, _SccId, _} = RecRef, RecPid) ->
            DirectOutputs = [Resolve(RR) || {SR, _SL, RR, _RL} <- Tuples,
                                              element(1, SR) =:= rec,
                                              element(1, RR) =:= output,
                                              maps:get(SR, RecRefToRecPid, undefined) =:= RecPid],
            RecOutputPairs = [{RO, R} || {RO, R} <- maps:to_list(ROToRec), R =:= RecRef],
            Immediate = lists:usort(lists:flatmap(
                fun({RO, _}) ->
                    [Resolve(RR) || {SR, _SL, RR, _RL} <- Tuples, SR =:= RO,
                                    element(1, RR) =:= op orelse element(1, RR) =:= output]
                end, RecOutputPairs)),
            PidConsumers = [P || P <- DirectOutputs ++ Immediate, is_pid(P)],
            RecConsumersForMe = maps:get(RecRef, RecConsumerPids, []),
            AllConsumers = lists:usort(PidConsumers ++ RecConsumersForMe),
            gen_server:call(RecPid, {set_consumers, AllConsumers})
        end, RecPids).

%%--------------------------------------------------------------------
%% Rec consumer wiring helpers
%%--------------------------------------------------------------------

build_rec_consumers(Tuples, ROToRec, RecRefToRecPid) ->
    lists:foldl(
        fun({SR, _SL, RR, RL}, Acc) ->
            case {element(1, RR), RL} of
                {rec, source} ->
                    case maps:find(SR, ROToRec) of
                        {ok, UpstreamRecRef} ->
                            DownstreamPid = maps:get(RR, RecRefToRecPid),
                            maps:update_with(UpstreamRecRef,
                                fun(L) -> [DownstreamPid | L] end,
                                [DownstreamPid], Acc);
                        error -> Acc
                    end;
                _ -> Acc
            end
        end, #{}, Tuples).

%%====================================================================
%% Wiring maps
%%====================================================================

build_wiring_maps(Tuples, Resolve) ->
    %% rec_output is a virtual node (it resolves to its parent Rec pid), so an
    %% edge *into* rec_output is not a real operator edge: the body output
    %% already reaches the Rec through its body_output feedback edge. Skipping
    %% these avoids double-wiring the Rec into a body operator's downstream.
    RealTuples = [T || T = {_SR, _SL, RR, _RL} <- Tuples,
                       element(1, RR) =/= rec_output],
    UpMaps = lists:foldl(
        fun({SR, _SL, RR, RL}, Acc) ->
            RcvrPid = Resolve(RR),
            case is_pid(RcvrPid) of
                true ->
                    SndrPid = Resolve(SR),
                    case is_pid(SndrPid) of
                        true ->
                            Up0 = maps:get(RR, Acc, #{}),
                            Existing = maps:get(SndrPid, Up0, []),
                            Acc#{RR => Up0#{SndrPid => [RL | Existing]}};
                        false -> Acc
                    end;
                false -> Acc
            end
        end, #{}, RealTuples),
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
        end, #{}, RealTuples),
    {UpMaps, DownMaps}.

resolve_pid({op, _} = R, RefToPid, _ROToRec, _Inputs, _Outputs, _Empties) ->
    Pid = maps:get(R, RefToPid, undefined),
    resolve_pid_check(R, Pid);
resolve_pid({rec, _, _, _} = R, RefToPid, _ROToRec, _Inputs, _Outputs, _Empties) ->
    Pid = maps:get(R, RefToPid, undefined),
    resolve_pid_check(R, Pid);
resolve_pid({empty, _, _} = R, RefToPid, _ROToRec, _Inputs, _Outputs, Empties) ->
    case maps:find(R, RefToPid) of
        {ok, Pid} ->
            resolve_pid_check(R, Pid);
        error ->
            Name = element(2, R),
            Pid = maps:get(Name, Empties, undefined),
            resolve_pid_check(R, Pid)
    end;
resolve_pid({rec_output, _, _, _} = R, _RefToPid, ROToRec, _Inputs, _Outputs, _Empties) ->
    RecRef = maps:get(R, ROToRec, undefined),
    case RecRef of
        undefined ->
            ?DBG("resolve_pid: rec_output ~p has no parent Rec", [R]),
            undefined;
        _ ->
            Pid = maps:get(RecRef, _RefToPid, undefined),
            resolve_pid_check(R, Pid)
    end;
resolve_pid({source, Name, _} = R, _RefToPid, _ROToRec, Inputs, _Outputs, _Empties) ->
    Pid = maps:get(Name, Inputs, undefined),
    resolve_pid_check(R, Pid);
resolve_pid({output, Name, _} = R, _RefToPid, _ROToRec, _Inputs, Outputs, _Empties) ->
    Pid = maps:get(Name, Outputs, undefined),
    resolve_pid_check(R, Pid).

resolve_pid_check(_Ref, Pid) when is_pid(Pid) -> Pid;
resolve_pid_check(Ref, undefined) ->
    ?DBG("resolve_pid: unresolved ref ~p", [Ref]),
    undefined.

%%====================================================================
%% Wire operators
%%====================================================================

wire_all(Tuples, OpRefs, OpPids, EmptyRefs, EmptyPids, Inputs, Outputs, Empties,
         UpMaps, DownMaps) ->
    WiringRef = make_ref(),
    SenderPid = self(),
    FunWire = fun(Pid, Up, Down) ->
        Pid ! {wiring_update, Up, Down, WiringRef, SenderPid}
    end,

    %% Wire operators
    OpPidsList = maps:values(OpPids),
    lists:foreach(
        fun(Ref) ->
            Pid = maps:get(Ref, OpPids),
            Up = maps:get(Ref, UpMaps, #{}),
            Down = maps:get(Ref, DownMaps, #{}),
            FunWire(Pid, Up, Down)
        end, OpRefs),

    %% Wire body-internal empties (spawned by this circuit)
    EmptyPidsList = maps:values(EmptyPids),
    lists:foreach(
        fun(Ref) ->
            Pid = maps:get(Ref, EmptyPids),
            Up = maps:get(Ref, UpMaps, #{}),
            Down = maps:get(Ref, DownMaps, #{}),
            FunWire(Pid, Up, Down)
        end, EmptyRefs),

    %% Wire sources
    SourceRefs = lists:usort(
        [SR || {SR, _SL, _RR, _RL} <- Tuples, element(1, SR) =:= source]),
    SrcPids = lists:filtermap(
        fun({source, Name, _}) ->
            case maps:find(Name, Inputs) of
                {ok, SrcPid} -> {true, SrcPid};
                error -> false
            end
        end, SourceRefs),
    lists:foreach(
        fun({source, Name, _} = Ref) ->
            case maps:find(Name, Inputs) of
                {ok, SrcPid} ->
                    Down = maps:get(Ref, DownMaps, #{}),
                    FunWire(SrcPid, #{}, Down);
                error -> ok
            end
        end, SourceRefs),

    %% Wire top-level empties (external feeders passed in Empties)
    AllEmptyRefs = lists:usort(
        [SR || {SR, _SL, _RR, _RL} <- Tuples, element(1, SR) =:= empty]),
    TopEmptyRefs = AllEmptyRefs -- EmptyRefs,
    TopEmptyPids = lists:filtermap(
        fun({empty, Name, _}) ->
            case maps:find(Name, Empties) of
                {ok, Pid} -> {true, Pid};
                error -> false
            end
        end, TopEmptyRefs),
    lists:foreach(
        fun({empty, Name, _} = Ref) ->
            case maps:find(Name, Empties) of
                {ok, Pid} ->
                    Down = maps:get(Ref, DownMaps, #{}),
                    FunWire(Pid, #{}, Down);
                error -> ok
            end
        end, TopEmptyRefs),

    %% Wire outputs
    OutputRefs = lists:usort(
        [RR || {_SR, _SL, RR, _RL} <- Tuples, element(1, RR) =:= output]),
    OutPids = lists:filtermap(
        fun({output, Name, _}) ->
            case maps:find(Name, Outputs) of
                {ok, SubPid} -> {true, SubPid};
                error -> false
            end
        end, OutputRefs),
    lists:foreach(
        fun({output, Name, _} = Ref) ->
            case maps:find(Name, Outputs) of
                {ok, SubPid} ->
                    Up = maps:get(Ref, UpMaps, #{}),
                    FunWire(SubPid, Up, #{});
                error -> ok
            end
        end, OutputRefs),

    ExpectedPids = lists:usort(OpPidsList ++ EmptyPidsList ++ SrcPids ++ TopEmptyPids ++ OutPids),
    gather_wiring_acks(WiringRef, ExpectedPids, 5000).

gather_wiring_acks(_WiringRef, [], _Timeout) ->
    ok;
gather_wiring_acks(WiringRef, ExpectPids, Timeout) ->
    receive
        {wiring_ack, WiringRef, Pid} ->
            gather_wiring_acks(WiringRef, lists:delete(Pid, ExpectPids), Timeout)
    after Timeout ->
        ?DBG("wiring_acks: ~w PID(s) unacknowledged after ~p ms: ~p",
               [length(ExpectPids), Timeout, ExpectPids])
    end.

validate_wiring(OpPids, RecPids, EmptyPids, Inputs, Outputs, Empties) ->
    AllPids = maps:values(OpPids)
        ++ maps:values(RecPids)
        ++ maps:values(EmptyPids)
        ++ maps:values(Inputs)
        ++ maps:values(Outputs)
        ++ maps:values(Empties),
    Dead = lists:filter(fun(P) -> not is_process_alive(P) end, AllPids),
    case Dead of
        [] -> ok;
        _ ->
            ?DBG("validate_wiring: ~p dead/terminated PIDs detected after wiring",
                   [length(Dead)])
    end,
    Orphans = maps:fold(
        fun(Ref, Pid, Acc) ->
            case is_process_alive(Pid) of
                true -> Acc;
                false -> [{Ref, Pid} | Acc]
            end
        end, [], OpPids),
    lists:foreach(
        fun({_Ref, _Pid}) ->
            ?DBG("validate_wiring: orphan operator ~p", [_Ref, _Pid])
        end, Orphans).

%%====================================================================
%% Helpers
%%====================================================================

stop_gen(0, _State) -> ok;
stop_gen(_Gen, #{operators := Ops}) ->
    maps:foreach(fun(_, P) -> catch gen_server:stop(P) end, Ops),
    ok.
