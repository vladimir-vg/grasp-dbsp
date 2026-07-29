%%%-------------------------------------------------------------------
%%% @doc Barrier-aware composite operator — runs a sub-DAG of operators
%%% sequentially in topological order.
%%%
%%% Pure function — all sub-operators run in-process. Each sub-operator
%%% is called via its handle_delta/3 API. Multi-upstream sub-operators
%%% use gdbsp_barrier internally for synchronization.
%%%
%%% External inputs arrive as labeled deltas on the circuit's own
%%% input labels. Each delta is propagated through the full sub-DAG
%%% in topological order. Output actions matching external-output
%%% labels are returned as the circuit's own actions.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_circuit).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type op_name() :: term().
-type op_label() :: term().

-type op_state() :: #{
    order   := [op_name()],
    states  := #{op_name() => term()},
    mods    := #{op_name() => module()},
    wires   := #{op_name() => #{op_label() => [{op_name(), op_label()}]}},
    ext_in  := #{op_label() => {op_name(), op_label()}},
    ext_out := #{op_name() => #{op_label() => [op_label()]}}
}.

-export_type([op_state/0, op_action/0]).

%%====================================================================
%% Init
%%====================================================================

-spec init(map()) -> {op_state(), [op_label()], [op_label()]}.
init(#{operators := Ops, wires := Wires,
       external_inputs := ExtIn, external_outputs := ExtOut}) ->

    OpNames = maps:keys(Ops),

    validate_wires(Wires, OpNames),

    Order = topological_sort(OpNames, Wires),

    {Mods, States} = init_operators(Ops),

    WiresIdx = build_wire_index(Wires),
    ExtInIdx = maps:from_list(ExtIn),
    ExtOutIdx = build_ext_out_index(ExtOut),

    ExtInLabels = [L || {L, _} <- ExtIn],
    ExtOutLabels = [L || {_, _, L} <- ExtOut],

    {#{order => Order, states => States, mods => Mods,
       wires => WiresIdx, ext_in => ExtInIdx, ext_out => ExtOutIdx},
     ExtInLabels, ExtOutLabels}.

%%====================================================================
%% handle_delta — process one labeled delta through the sub-DAG
%%====================================================================

-spec handle_delta(op_state(), op_label(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{order := Order, states := States, mods := Mods,
               wires := WiresIdx, ext_in := ExtInIdx, ext_out := ExtOutIdx},
             ExtLabel, DeltaMsg) ->

    case maps:find(ExtLabel, ExtInIdx) of
        {ok, {EntryOp, EntryInLabel}} ->
            Bufs = seed_buffer(Order, EntryOp, EntryInLabel, DeltaMsg),
            {NewStates, ExtActions} = execute_dag(
                Order, States, Mods, Bufs, WiresIdx, ExtOutIdx, []),
            NewState = #{order => Order, states => NewStates, mods => Mods,
                         wires => WiresIdx, ext_in => ExtInIdx, ext_out => ExtOutIdx},
            {NewState, ExtActions};
        error ->
            {#{order => Order, states => States, mods => Mods,
               wires => WiresIdx, ext_in => ExtInIdx, ext_out => ExtOutIdx},
             []}
    end.

%%====================================================================
%% merge_metas
%%====================================================================

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(Metas) ->
    gdbsp_operator_spec:merge_metas_consistent(Metas).

%%====================================================================
%% Internal: operator initialization
%%====================================================================

init_operators(Ops) ->
    maps:fold(
        fun(Name, {Mod, Args}, {ModsAcc, StAcc}) ->
            {InitSt, _InL, _OutL} = Mod:init(Args),
            {maps:put(Name, Mod, ModsAcc), maps:put(Name, InitSt, StAcc)}
        end,
        {#{}, #{}},
        Ops
    ).

%%====================================================================
%% Internal: topological sort (Kahn's algorithm)
%%====================================================================

topological_sort(Names, Wires) ->
    {Adj, InDeg0} = build_graph(Names, Wires),
    topological_sort_loop(Adj, InDeg0, []).

topological_sort_loop(Adj, InDeg, Result) ->
    case find_zero_indegree(InDeg) of
        none ->
            case maps:size(InDeg) of
                0 -> lists:reverse(Result);
                _ -> error({cycle_detected, maps:keys(InDeg)})
            end;
        {Name, NewInDeg} ->
            {NewAdj, NewInDeg2} = case maps:find(Name, Adj) of
                {ok, Neighbors} ->
                    NewIDeg = lists:foldl(
                        fun(N, Acc) ->
                            maps:update_with(N, fun(C) -> C - 1 end, Acc)
                        end,
                        NewInDeg,
                        Neighbors
                    ),
                    {maps:remove(Name, Adj), NewIDeg};
                error ->
                    {Adj, NewInDeg}
            end,
            topological_sort_loop(NewAdj, NewInDeg2, [Name | Result])
    end.

build_graph(Names, Wires) ->
    EmptyInDeg = maps:from_list([{N, 0} || N <- Names]),
    {InDeg, Adj} = lists:foldl(
        fun({FromOp, _FromLabel, ToOp, _ToLabel}, {IDeg, Adj0}) ->
            NewAdj = maps:update_with(FromOp, fun(L) -> [ToOp | L] end, [ToOp], Adj0),
            NewIDeg = maps:update_with(ToOp, fun(C) -> C + 1 end, IDeg),
            {NewIDeg, NewAdj}
        end,
        {EmptyInDeg, #{}},
        Wires
    ),
    {Adj, InDeg}.

find_zero_indegree(InDeg) ->
    case maps:size(InDeg) of
        0 -> none;
        _ -> find_zero_in_list(maps:to_list(InDeg), InDeg)
    end.

find_zero_in_list([], _InDeg) -> none;
find_zero_in_list([{Key, 0} | _Rest], InDeg) ->
    {Key, maps:remove(Key, InDeg)};
find_zero_in_list([_ | Rest], InDeg) ->
    find_zero_in_list(Rest, InDeg).

%%====================================================================
%% Internal: wire index
%%====================================================================

build_wire_index(Wires) ->
    lists:foldl(
        fun({FromOp, FromLabel, ToOp, ToLabel}, Acc) ->
            OpMap = maps:get(FromOp, Acc, #{}),
            Old = maps:get(FromLabel, OpMap, []),
            OpMap2 = maps:put(FromLabel, [{ToOp, ToLabel} | Old], OpMap),
            maps:put(FromOp, OpMap2, Acc)
        end,
        #{},
        Wires
    ).

build_ext_out_index(ExtOut) ->
    lists:foldl(
        fun({FromOp, FromLabel, ExtLabel}, Acc) ->
            OpMap = maps:get(FromOp, Acc, #{}),
            Old = maps:get(FromLabel, OpMap, []),
            OpMap2 = maps:put(FromLabel, [ExtLabel | Old], OpMap),
            maps:put(FromOp, OpMap2, Acc)
        end,
        #{},
        ExtOut
    ).

%%====================================================================
%% Internal: wiring validation
%%====================================================================

validate_wires([], _OpNames) -> ok;
validate_wires(Wires, OpNames) ->
    lists:foreach(
        fun({FromOp, _FromL, ToOp, _ToL}) ->
            case lists:member(FromOp, OpNames) of
                true -> ok;
                false -> error({unknown_operator, FromOp})
            end,
            case lists:member(ToOp, OpNames) of
                true -> ok;
                false -> error({unknown_operator, ToOp})
            end
        end,
        Wires
    ),
    ok.

%%====================================================================
%% Internal: step execution
%%====================================================================

seed_buffer(Order, EntryOp, EntryInLabel, DeltaMsg) ->
    Bufs = maps:from_list([{Op, []} || Op <- Order]),
    OpBufs = maps:get(EntryOp, Bufs, []),
    maps:put(EntryOp, [{EntryInLabel, DeltaMsg} | OpBufs], Bufs).

execute_dag([], _States, _Mods, _Bufs, _WiresIdx, _ExtOutIdx, ExtActions) ->
    {_States, lists:reverse(ExtActions)};
execute_dag([Op | Rest], States, Mods, Bufs, WiresIdx, ExtOutIdx, ExtActions) ->
    OpState = maps:get(Op, States),
    OpMod = maps:get(Op, Mods),
    OpDeltas = maps:get(Op, Bufs, []),

    {NewOpState, NewBufs, NewExtActions} = lists:foldl(
        fun({InLabel, DeltaMsg}, {StAcc, BufAcc, ExtAcc}) ->
            {StAcc2, Actions} = OpMod:handle_delta(StAcc, InLabel, DeltaMsg),
            {BAcc2, EAcc2} = route_actions(Op, Actions, BufAcc, WiresIdx, ExtOutIdx, ExtAcc),
            {StAcc2, BAcc2, EAcc2}
        end,
        {OpState, Bufs, ExtActions},
        lists:reverse(OpDeltas)
    ),

    States2 = maps:put(Op, NewOpState, States),
    execute_dag(Rest, States2, Mods, NewBufs, WiresIdx, ExtOutIdx, NewExtActions).

route_actions(Op, Actions, Bufs, WiresIdx, ExtOutIdx, ExtActions) ->
    lists:foldl(
        fun({send, Label, Msg}, {BAcc, EAcc}) ->
            RouteInternal = case maps:find(Op, WiresIdx) of
                {ok, OpWires} -> maps:find(Label, OpWires);
                error -> error
            end,
            RouteExternal = case maps:find(Op, ExtOutIdx) of
                {ok, OpExt} -> maps:find(Label, OpExt);
                error -> error
            end,
            {BAcc2, EAcc2} = case RouteInternal of
                {ok, Destinations} ->
                    BAcc3 = lists:foldl(
                        fun({DestOp, DestLabel}, B) ->
                            DestBufs = maps:get(DestOp, B, []),
                            maps:put(DestOp, [{DestLabel, Msg} | DestBufs], B)
                        end,
                        BAcc,
                        Destinations
                    ),
                    {BAcc3, EAcc};
                error ->
                    {BAcc, EAcc}
            end,
            case RouteExternal of
                {ok, ExtLabels} ->
                    NewExt = [{send, EL, Msg} || EL <- ExtLabels],
                    {BAcc2, NewExt ++ EAcc2};
                error ->
                    {BAcc2, EAcc2}
            end;
        ({error, _} = Err, {BAcc, EAcc}) ->
            {BAcc, [Err | EAcc]};
        (_Other, Acc) ->
            Acc
        end,
        {Bufs, ExtActions},
        Actions
    ).
