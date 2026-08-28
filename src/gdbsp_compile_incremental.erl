%%%-------------------------------------------------------------------
%%% @doc Incrementalization pass — wraps non-linear operators in
%%% integrate/differentiate pairs.
%%%
%%% Ported from gg_c_dbsp_graph.erl.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_incremental).

-export([run/1, topological_sort/1]).

-include("gdbsp_circuit.hrl").

%%====================================================================
%% Public API
%%====================================================================

-spec run(#circuit_graph{}) -> #circuit_graph{}.
run(G = #circuit_graph{nodes = Nodes, next_id = NextId}) ->
    {ok, Sorted} = topological_sort(G),
    InitialModeMap = maps:fold(
        fun(_Id, #circuit_node{op = Op}, Acc) ->
            OpTag = element(1, Op),
            case OpTag of
                integrate -> Acc#{_Id => full};
                _ -> Acc
            end
        end, #{}, Nodes),
    {NewNodes, NewNextId, _ModeMap} =
        lists:foldl(
            fun(NodeId, {AccNodes, AccNextId, ModeMap}) ->
                Node = maps:get(NodeId, AccNodes),
                InputModes = get_modes(Node#circuit_node.inputs, ModeMap),
                process(Node, InputModes, AccNodes, AccNextId, ModeMap)
            end,
            {Nodes, NextId, InitialModeMap},
            Sorted
        ),
    #circuit_graph{nodes = NewNodes, next_id = NewNextId}.

%%====================================================================
%% Topological sort
%%====================================================================

-spec topological_sort(#circuit_graph{}) -> {ok, [node_id()]} | {error, cycle}.
topological_sort(#circuit_graph{nodes = Nodes}) ->
    ConsumerIndex = build_consumer_index(Nodes),
    case do_topological_sort(Nodes, ConsumerIndex, false) of
        {ok, Sorted} -> {ok, Sorted};
        {error, cycle} -> do_topological_sort(Nodes, ConsumerIndex, true)
    end.

do_topological_sort(Nodes, ConsumerIndex, ExcludeDelayEdges) ->
    AllIds = maps:keys(Nodes),
    InDegree = init_indegree(Nodes, ExcludeDelayEdges),
    Queue = [Id || Id <- AllIds, maps:get(Id, InDegree) =:= 0],
    case topo_loop(queue:from_list(Queue), InDegree, Nodes,
                   ConsumerIndex, ExcludeDelayEdges, []) of
        {sorted, Result} when length(Result) =:= length(AllIds) ->
            {ok, lists:reverse(Result)};
        {sorted, _Result} ->
            {error, cycle}
    end.

build_consumer_index(Nodes) ->
    maps:fold(
        fun(ToId, #circuit_node{inputs = Ins}, Acc) ->
            lists:foldl(
                fun(FromId, A) ->
                    maps:update_with(FromId, fun(L) -> [ToId | L] end, [ToId], A)
                end,
                Acc,
                lists:usort(Ins))
        end,
        #{},
        Nodes).

init_indegree(Nodes, ExcludeDelayEdges) ->
    maps:map(
        fun(_ToId, #circuit_node{op = ToOp, inputs = ToInputs}) ->
            IsRecOutput = element(1, ToOp) =:= rec_output,
            lists:foldl(
                fun(FromId, Count) ->
                    case maps:find(FromId, Nodes) of
                        {ok, #circuit_node{op = FromOp}} ->
                            ShouldSkip = ExcludeDelayEdges
                                andalso element(1, FromOp) =:= rec,
                            case ShouldSkip of
                                false -> Count + 1;
                                true when IsRecOutput -> Count + 1;
                                true -> Count
                            end;
                        error -> Count
                    end
                end, 0, lists:usort(ToInputs))
        end, Nodes).

topo_loop(Queue, InDegree, Nodes, ConsumerIndex, ExcludeDelayEdges, Acc) ->
    case queue:out(Queue) of
        {empty, _} ->
            {sorted, Acc};
        {{value, Id}, RestQ} ->
            NewAcc = [Id | Acc],
            Node = maps:get(Id, Nodes),
            IsRec = element(1, Node#circuit_node.op) =:= rec,
            ShouldSkip = ExcludeDelayEdges andalso IsRec,
            {NewQ, NewIndeg} = lists:foldl(
                fun(ConsumerId, {Q, Indeg}) ->
                    Skip = case ShouldSkip of
                        true ->
                            #circuit_node{op = COp} = maps:get(ConsumerId, Nodes),
                            element(1, COp) =/= rec_output;
                        false -> false
                    end,
                    case Skip of
                        true ->
                            {Q, Indeg};
                        false ->
                            NewD = maps:get(ConsumerId, Indeg) - 1,
                            Indeg2 = maps:put(ConsumerId, NewD, Indeg),
                            case NewD of
                                0 -> {queue:in(ConsumerId, Q), Indeg2};
                                _ -> {Q, Indeg2}
                            end
                    end
                end,
                {RestQ, InDegree},
                maps:get(Id, ConsumerIndex, [])
            ),
            topo_loop(NewQ, NewIndeg, Nodes, ConsumerIndex, ExcludeDelayEdges, NewAcc)
    end.

%%====================================================================
%% Mode tracking
%%====================================================================

get_modes(Inputs, ModeMap) ->
    [maps:get(Id, ModeMap, delta) || Id <- Inputs].

%% Reconcile the input modes of a linear (delta pass-through) node. When all
%% inputs already agree, the node simply inherits that mode. When they are
%% mixed, insert a differentiate before each full-mode input so every input
%% carries delta and the node emits delta.
reconcile_linear(Id, Node, InputModes, AccNodes, AccNextId, ModeMap) ->
    case lists:usort(InputModes) of
        [M] ->
            {AccNodes, AccNextId, maps:put(Id, M, ModeMap)};
        _ ->
            {NewInputs, Nodes1, NextId1, ModeMap1} =
                reconcile_delta(Node#circuit_node.inputs, InputModes, Id,
                                AccNodes, AccNextId, ModeMap),
            Nodes2 = maps:put(Id, Node#circuit_node{inputs = NewInputs}, Nodes1),
            {Nodes2, NextId1, maps:put(Id, delta, ModeMap1)}
    end.

reconcile_delta([], [], _ParentId, AccNodes, AccNextId, ModeMap) ->
    {[], AccNodes, AccNextId, ModeMap};
reconcile_delta([InId | RestIns], [full | RestModes], ParentId,
                AccNodes, AccNextId, ModeMap) ->
    {RestNewIns, Nodes1, NextId1, ModeMap1} =
        reconcile_delta(RestIns, RestModes, ParentId, AccNodes, AccNextId, ModeMap),
    DiffId = NextId1,
    DiffNode = #circuit_node{id = DiffId, op = {differentiate},
                             inputs = [InId], meta = #{serves => ParentId}},
    Nodes2 = maps:put(DiffId, DiffNode, Nodes1),
    ModeMap2 = maps:put(DiffId, delta, ModeMap1),
    {[DiffId | RestNewIns], Nodes2, NextId1 + 1, ModeMap2};
reconcile_delta([InId | RestIns], [_M | RestModes], ParentId,
                AccNodes, AccNextId, ModeMap) ->
    {RestNewIns, Nodes1, NextId1, ModeMap1} =
        reconcile_delta(RestIns, RestModes, ParentId, AccNodes, AccNextId, ModeMap),
    {[InId | RestNewIns], Nodes1, NextId1, ModeMap1}.

%%====================================================================
%% Per-node processing
%%====================================================================

process(#circuit_node{id = Id, op = {source, _}}, _InputModes,
        AccNodes, AccNextId, ModeMap) ->
    {AccNodes, AccNextId, maps:put(Id, delta, ModeMap)};

process(#circuit_node{id = Id, op = {output, _}} = Node, InputModes,
        AccNodes, AccNextId, ModeMap) ->
    case InputModes of
        [full] ->
            [InputId] = Node#circuit_node.inputs,
            DiffId = AccNextId,
            DiffNode = #circuit_node{id = DiffId, op = {differentiate},
                                     inputs = [InputId],
                                     meta = #{serves => Id}},
            NewNode = Node#circuit_node{inputs = [DiffId]},
            Nodes2 = maps:put(DiffId, DiffNode, maps:put(Id, NewNode, AccNodes)),
            ModeMap2 = maps:put(Id, delta, maps:put(DiffId, delta, ModeMap)),
            {Nodes2, AccNextId + 1, ModeMap2};
        [delta] ->
            {AccNodes, AccNextId, maps:put(Id, delta, ModeMap)};
        [] ->
            {AccNodes, AccNextId, maps:put(Id, delta, ModeMap)}
    end;

process(#circuit_node{id = Id, op = Op}, _InputModes,
        AccNodes, AccNextId, ModeMap)
  when element(1, Op) =:= integrate ->
    {AccNodes, AccNextId, maps:put(Id, full, ModeMap)};

process(#circuit_node{id = Id, op = {differentiate}}, _InputModes,
        AccNodes, AccNextId, ModeMap) ->
    {AccNodes, AccNextId, maps:put(Id, delta, ModeMap)};

process(#circuit_node{id = Id, op = Op} = Node, InputModes,
        AccNodes, AccNextId, ModeMap) ->
    case gdbsp_operator_spec:is_linear(Op) of
        true  -> reconcile_linear(Id, Node, InputModes, AccNodes, AccNextId, ModeMap);
        false -> wrap_nonlinear(Id, Node, InputModes, AccNodes, AccNextId, ModeMap)
    end.

%%====================================================================
%% Non-linear wrapping
%%====================================================================

wrap_nonlinear(Id, #circuit_node{inputs = Inputs} = Node, InputModes,
               AccNodes, AccNextId, ModeMap) ->
    {NewInputs, Nodes1, NextId1, ModeMap1} =
        insert_integrates(Inputs, InputModes, Id, AccNodes, AccNextId, ModeMap),
    Node1 = Node#circuit_node{inputs = NewInputs},
    Nodes2 = maps:put(Id, Node1, Nodes1),
    ModeMap2 = maps:put(Id, full, ModeMap1),

    DiffId = NextId1,

    Nodes3 = maps:map(
        fun(_CId, CNode = #circuit_node{inputs = CIns}) ->
            case lists:member(Id, CIns) of
                true ->
                    NewCIns = [case I of Id -> DiffId; _ -> I end || I <- CIns],
                    CNode#circuit_node{inputs = NewCIns};
                false ->
                    CNode
            end
        end,
        Nodes2
    ),

    DiffNode = #circuit_node{id = DiffId, op = {differentiate},
                             inputs = [Id], meta = #{serves => Id}},
    Nodes4 = maps:put(DiffId, DiffNode, Nodes3),
    ModeMap3 = maps:put(DiffId, delta, ModeMap2),

    {Nodes4, NextId1 + 1, ModeMap3}.

insert_integrates([], [], _ParentId, AccNodes, AccNextId, ModeMap) ->
    {[], AccNodes, AccNextId, ModeMap};
insert_integrates([InputId | RestInputs], [Mode | RestModes], ParentId,
                   AccNodes, AccNextId, ModeMap) ->
    {RestNewInputs, Nodes1, NextId1, ModeMap1} =
        insert_integrates(RestInputs, RestModes, ParentId, AccNodes, AccNextId, ModeMap),
    case Mode of
        delta ->
            IntId = NextId1,
            IntNode = #circuit_node{id = IntId, op = {integrate},
                                    inputs = [InputId],
                                    meta = #{serves => ParentId}},
            Nodes2 = maps:put(IntId, IntNode, Nodes1),
            ModeMap2 = maps:put(IntId, full, ModeMap1),
            {[IntId | RestNewInputs], Nodes2, NextId1 + 1, ModeMap2};
        full ->
            {[InputId | RestNewInputs], Nodes1, NextId1, ModeMap1}
    end.
