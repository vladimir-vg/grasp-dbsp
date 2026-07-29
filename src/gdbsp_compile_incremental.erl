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
    {NewNodes, NewNextId, _ModeMap} =
        lists:foldl(
            fun(NodeId, {AccNodes, AccNextId, ModeMap}) ->
                Node = maps:get(NodeId, AccNodes),
                InputModes = get_modes(Node#circuit_node.inputs, ModeMap),
                process(Node, InputModes, AccNodes, AccNextId, ModeMap)
            end,
            {Nodes, NextId, #{}},
            Sorted
        ),
    #circuit_graph{nodes = NewNodes, next_id = NewNextId}.

%%====================================================================
%% Topological sort
%%====================================================================

-spec topological_sort(#circuit_graph{}) -> {ok, [node_id()]} | {error, cycle}.
topological_sort(#circuit_graph{nodes = Nodes}) ->
    ConsumerIndex = build_consumer_index(Nodes),
    AllIds = maps:keys(Nodes),
    InDegree = init_indegree(Nodes),
    Queue = [Id || Id <- AllIds, maps:get(Id, InDegree) =:= 0],
    case topo_loop(queue:from_list(Queue), InDegree, Nodes,
                   ConsumerIndex, []) of
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

init_indegree(Nodes) ->
    maps:map(
        fun(_ToId, #circuit_node{inputs = ToInputs}) ->
            length(lists:usort(ToInputs))
        end,
        Nodes).

topo_loop(Queue, InDegree, Nodes, ConsumerIndex, Acc) ->
    case queue:out(Queue) of
        {empty, _} ->
            {sorted, Acc};
        {{value, Id}, RestQ} ->
            NewAcc = [Id | Acc],
            {NewQ, NewIndeg} = lists:foldl(
                fun(ConsumerId, {Q, Indeg}) ->
                    NewD = maps:get(ConsumerId, Indeg) - 1,
                    Indeg2 = maps:put(ConsumerId, NewD, Indeg),
                    case NewD of
                        0 -> {queue:in(ConsumerId, Q), Indeg2};
                        _ -> {Q, Indeg2}
                    end
                end,
                {RestQ, InDegree},
                maps:get(Id, ConsumerIndex, [])
            ),
            topo_loop(NewQ, NewIndeg, Nodes, ConsumerIndex, NewAcc)
    end.

%%====================================================================
%% Mode tracking
%%====================================================================

get_modes(Inputs, ModeMap) ->
    [maps:get(Id, ModeMap, delta) || Id <- Inputs].

merge_modes([]) -> delta;
merge_modes([M]) -> M;
merge_modes([M | Rest]) ->
    case lists:all(fun(X) -> X =:= M end, Rest) of
        true -> M;
        false -> error({mode_mismatch, [M | Rest]})
    end.

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

process(#circuit_node{id = Id, op = Op}, InputModes,
         AccNodes, AccNextId, ModeMap)
  when element(1, Op) =:= map; element(1, Op) =:= filter;
       element(1, Op) =:= flat_map; element(1, Op) =:= neg;
       element(1, Op) =:= plus; element(1, Op) =:= map_index;
       element(1, Op) =:= delay;
       element(1, Op) =:= rec; element(1, Op) =:= rec_output ->
    OutputMode = merge_modes(InputModes),
    {AccNodes, AccNextId, maps:put(Id, OutputMode, ModeMap)};

process(#circuit_node{id = Id, op = Op} = Node, InputModes,
        AccNodes, AccNextId, ModeMap)
  when element(1, Op) =:= join; element(1, Op) =:= distinct;
       element(1, Op) =:= aggregate; element(1, Op) =:= antijoin ->
    wrap_nonlinear(Id, Node, InputModes, AccNodes, AccNextId, ModeMap).

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
