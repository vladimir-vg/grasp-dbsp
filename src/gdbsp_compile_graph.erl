%%%-------------------------------------------------------------------
%%% @doc Circuit graph construction from parsed GDBSP program.
%%%
%%% Transforms #gdbsp_program{} into #circuit_graph{}.
%%% Handles name resolution, topological sort, operator mapping,
%%% and schema computation.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_graph).

-export([build_from_lowered/4]).

-include("gdbsp_circuit.hrl").
-include("gdbsp_lowered.hrl").
-include("gdbsp_type.hrl").
-include("gdbsp_expr.hrl").
-include("gdbsp_op.hrl").

-import(gdbsp_string_util, [trim/1, dequote/1, split_top/2, parse_string_list/1]).

-type fn_registry() :: #{binary() := jsx:json_term()}.
-type fn_params() :: #{binary() => #{pos := [binary()], kw := [{binary(), binary()}]}}.
-type kwarg_order() :: #{binary() => [binary()]}.

-spec build_from_lowered(#lowered_graph{}, fn_registry(), fn_params(), kwarg_order()) ->
    {ok, #circuit_graph{}, #{binary() => node_id()}} | {error, term()}.
build_from_lowered(#lowered_graph{nodes = LNodes, tag_map = TagMap,
                                  fixpoints = Fixpoints}, FnReg, FnParams, KwargOrder) ->
    NodeList = maps:to_list(LNodes),
    case lowered_topo_sort(NodeList) of
        {ok, Order} ->
            {Graph0, LnIdMap, CircuitFixpointInputs, CircuitFixpointOutputs} =
                construct_from_lowered(NodeList, Order, FnReg, FnParams, KwargOrder),
            {Graph1, RecOutputTags} = construct_fixpoints(Graph0, Fixpoints, LnIdMap,
                                          CircuitFixpointInputs, CircuitFixpointOutputs),
            ok = validate_rec_source_inputs(Graph1),
            ok = validate_graph(Graph1),
            TagToId0 = build_tag_to_id(TagMap, LnIdMap),
            TagToId = maps:merge(TagToId0, RecOutputTags),
            {ok, Graph1, TagToId};
        {error, _} = Err -> Err
    end.

%%====================================================================
%% Lowered topological sort
%%====================================================================

lowered_topo_sort(NodeList) ->
    InDeg = maps:from_list(
        lists:map(
            fun({LId, #lnode{op = Op, inputs = Ins}}) ->
                Refs = case Op of
                    delay -> [R || R <- Ins, R =/= LId];
                    _ -> Ins
                end,
                {LId, length(Refs)}
            end, NodeList)),
    Consumers = lists:foldl(
        fun({LId, #lnode{inputs = Ins}}, Acc) ->
            lists:foldl(
                fun(InId, A) ->
                    maps:update_with(InId, fun(L) -> [LId | L] end, [LId], A)
                end, Acc, Ins)
        end, #{}, NodeList),
    AllIds = [Id || {Id, _} <- NodeList],
    Queue = [Id || Id <- AllIds, maps:get(Id, InDeg, 0) =:= 0],
    lowered_topo_loop(queue:from_list(Queue), InDeg, Consumers,
                      length(AllIds), []).

lowered_topo_loop(Q, InDeg, Consumers, Total, Acc) ->
    case queue:out(Q) of
        {empty, _} ->
            case length(Acc) =:= Total of
                true -> {ok, lists:reverse(Acc)};
                false -> {error, cycle_in_graph}
            end;
        {{value, Id}, RestQ} ->
            NewAcc = [Id | Acc],
            Dependents = maps:get(Id, Consumers, []),
            {NewQ, NewIndeg} = lists:foldl(
                fun(Dep, {QI, ID}) ->
                    NewD = maps:get(Dep, ID) - 1,
                    ID2 = maps:put(Dep, NewD, ID),
                    case NewD of
                        0 -> {queue:in(Dep, QI), ID2};
                        _ -> {QI, ID2}
                    end
                end, {RestQ, InDeg}, Dependents),
            lowered_topo_loop(NewQ, NewIndeg, Consumers, Total, NewAcc)
    end.

%%====================================================================
%% Circuit graph construction from lowered nodes
%%====================================================================

construct_from_lowered(NodeList, Order, FnReg, FnParams, KwargOrder) ->
    LNodeById = maps:from_list(NodeList),
    {G, LnIdMap, FixInMap, FixOutMap} = lists:foldl(
        fun(LId, {GAcc, IdMapAcc, FIMAcc, FOMAcc}) ->
            #lnode{op = Op, inputs = LInputs, args = Args, type = Type} =
                maps:get(LId, LNodeById),
            CInputIds = [maps:get(InId, IdMapAcc, InId) || InId <- LInputs],
            case Op of
                fixpoint_input ->
                    {G2, NodeId} = add_circuit_node(GAcc, {integrate}, CInputIds, #{}),
                    Schema = compute_schema_lowered(integrate, [], CInputIds, Type, G2),
                    G3 = set_schema(G2, NodeId, Schema),
                    G4 = set_type(G3, NodeId, Type),
                    {G4, IdMapAcc#{LId => NodeId},
                     maps:put(LId, NodeId, FIMAcc), FOMAcc};
                fixpoint_output ->
                    %% Pass through to body output circuit node.
                    %% Will be wrapped with rec_output during fixpoint construction.
                    InId = case LInputs of
                        [I] -> I;
                        [] -> throw({compile_error, {fixpoint_output_no_input}})
                    end,
                    case maps:find(InId, IdMapAcc) of
                        {ok, CId} ->
                            {GAcc, IdMapAcc#{LId => CId}, FIMAcc,
                             maps:put(LId, CId, FOMAcc)};
                        error ->
                            throw({compile_error, {unresolved_fixpoint_output_input}})
                    end;
                join ->
                    {G2, NodeId} = build_join_graph_lowered(GAcc, Args, CInputIds),
                    Schema = compute_schema_lowered(Op, Args, CInputIds, Type, G2),
                    G3 = set_schema(G2, NodeId, Schema),
                    G4 = set_type(G3, NodeId, Type),
                    {G4, IdMapAcc#{LId => NodeId}, FIMAcc, FOMAcc};
                aggregate ->
                    {G2, NodeId} = build_aggregate_graph_lowered(GAcc, Args, CInputIds, FnReg),
                    Schema = compute_schema_lowered(Op, Args, CInputIds, Type, G2),
                    G3 = set_schema(G2, NodeId, Schema),
                    G4 = set_type(G3, NodeId, Type),
                    {G4, IdMapAcc#{LId => NodeId}, FIMAcc, FOMAcc};
                _ ->
                    {OpTuple, SubNodes} = make_operator_lowered(
                        GAcc, Op, Args, CInputIds, Type, FnReg, FnParams, KwargOrder),
                    {G2, FinalId} = add_with_sub_nodes(GAcc, OpTuple, CInputIds, SubNodes),
                    Schema = compute_schema_lowered(Op, Args, CInputIds, Type, G2),
                    G3 = set_schema(G2, FinalId, Schema),
                    G4 = set_type(G3, FinalId, Type),
                    {G4, IdMapAcc#{LId => FinalId}, FIMAcc, FOMAcc}
            end
        end,
        {new_graph(), #{}, #{}, #{}},
        Order),
    {G, LnIdMap, FixInMap, FixOutMap}.

%%--------------------------------------------------------------------
%% Join lowered — creates map_index nodes
%%--------------------------------------------------------------------

build_join_graph_lowered(G, Args, InputIds) ->
    [LId, RId] = InputIds,
    LSchema = get_schema(G, LId),
    RSchema = get_schema(G, RId),
    {on, OnFields} = get_kw_arg(Args, on, []),
    Shared = lists:filter(fun(F) -> lists:member(F, RSchema) end, LSchema),
    LeftVal = LSchema -- Shared,
    RightVal = RSchema -- Shared,
    LType = get_input_row_type([LId], G),
    RType = get_input_row_type([RId], G),
    Merged = build_merged_fields(Shared, LeftVal, RightVal, LType, RType),

    LeftIdxSpec = #{key_vars => Shared, val_vars => LeftVal},
    NextId0 = G#circuit_graph.next_id,
    LIdxNode = #circuit_node{id = NextId0, op = {map_index, LeftIdxSpec},
                              inputs = [LId], meta = #{}},
    G0 = G#circuit_graph{next_id = NextId0 + 1,
                         nodes = maps:put(NextId0, LIdxNode, G#circuit_graph.nodes)},
    G1 = set_schema(G0, NextId0, Shared ++ LeftVal),

    NextId1 = G1#circuit_graph.next_id,
    RightIdxSpec = #{key_vars => Shared, val_vars => RightVal},
    RIdxNode = #circuit_node{id = NextId1, op = {map_index, RightIdxSpec},
                              inputs = [RId], meta = #{}},
    G2 = G1#circuit_graph{next_id = NextId1 + 1,
                          nodes = maps:put(NextId1, RIdxNode, G1#circuit_graph.nodes)},
    G3 = set_schema(G2, NextId1, Shared ++ RightVal),

    JoinId = G3#circuit_graph.next_id,
    JoinOp = {join, #{shared_vars => Shared, left_val_vars => LeftVal,
                      right_val_vars => RightVal, merged_fields => Merged}},
    JoinNode = #circuit_node{id = JoinId, op = JoinOp,
                              inputs = [NextId0, NextId1], meta = #{}},
    G4 = G3#circuit_graph{next_id = JoinId + 1,
                          nodes = maps:put(JoinId, JoinNode, G3#circuit_graph.nodes)},
    Schema = OnFields ++ LeftVal ++ RightVal,
    G5 = set_schema(G4, JoinId, Schema),
    {G5, JoinId}.

%%--------------------------------------------------------------------
%% Aggregate lowered — creates map_index → aggregate → map(unwrap)
%%--------------------------------------------------------------------

build_aggregate_graph_lowered(G, Args, InputIds, FnReg) ->
    FnName = get_var_arg(Args, 2),
    AggBin = resolve_agg_fn_name(FnName, FnReg),
    {by, ByFields} = get_kw_arg(Args, by, []),
    {value, ValField} = get_kw_arg(Args, value, <<>>),
    {as, AsField} = get_kw_arg(Args, 'as', <<>>),
    IdxSpec = #{key_vars => ByFields, agg_col => ValField},
    OutRowType = {struct, maps:from_list([{F, dynamic} || F <- ByFields] ++
                                          [{AsField, dynamic}]), exact},
    UnwrapSpec = #{kind => agg_unwrap, group_by => ByFields,
                   output_var => AsField, row_type => OutRowType},

    {G1, AggId} = add_with_sub_nodes(G, {aggregate, AggBin}, InputIds,
                                     [{map_index, IdxSpec}]),
    AggSchema = ByFields ++ [AsField],
    G2 = set_schema(G1, AggId, AggSchema),

    UnwrapId = G2#circuit_graph.next_id,
    UnwrapNode = #circuit_node{id = UnwrapId, op = {map, UnwrapSpec},
                                inputs = [AggId], meta = #{}},
    G3 = G2#circuit_graph{next_id = UnwrapId + 1,
                          nodes = maps:put(UnwrapId, UnwrapNode, G2#circuit_graph.nodes)},
    G4 = set_schema(G3, UnwrapId, AggSchema),
    {G4, UnwrapId}.

%%--------------------------------------------------------------------
%% Operator mapping from lowered args
%%--------------------------------------------------------------------

make_operator_lowered(G, Op, Args, InputIds, _TS, FnReg, FnParams, KwargOrder) ->
    case Op of
        source ->
            TableName = get_string_arg(Args, 1),
            {{source, TableName}, []};
        integrate ->
            {{integrate}, []};
        differentiate ->
            {{differentiate}, []};
        delay ->
            {{delay}, []};
        distinct ->
            {{distinct}, []};
        plus ->
            {{plus}, []};
        neg ->
            {{neg}, []};
        map ->
            FnName = get_var_arg(Args, 2),
            check_row_fn_arity(map, FnName, FnParams),
            {Expr, ArgName} = resolve_fn(FnName, FnReg, FnParams),
            RowType = get_input_row_type(InputIds, G),
            Spec = #{kind => expr, expr => Expr, row_type => RowType,
                     arg_name => ArgName, kwarg_order => KwargOrder},
            {{map, Spec}, []};
        filter ->
            FnName = get_var_arg(Args, 2),
            check_row_fn_arity(filter, FnName, FnParams),
            {Expr, ArgName} = resolve_fn(FnName, FnReg, FnParams),
            RowType = get_input_row_type(InputIds, G),
            {{filter, #{expr => Expr, row_type => RowType, arg_name => ArgName,
                        kwarg_order => KwargOrder}}, []};
        flat_map ->
            FnName = get_var_arg(Args, 2),
            check_row_fn_arity(flat_map, FnName, FnParams),
            {Expr, ArgName} = resolve_fn(FnName, FnReg, FnParams),
            RowType = get_input_row_type(InputIds, G),
            {{flat_map, #{expr => Expr, row_type => RowType, arg_name => ArgName,
                          kwarg_order => KwargOrder}}, []};
        project ->
            KeepFields = get_string_list_arg(Args, 2),
            {{map, #{kind => project, keep => KeepFields}}, []};
        antijoin ->
            {on, SharedVars} = get_kw_arg(Args, on, []),
            [_, RId] = InputIds,
            RSchema = get_schema(G, RId),
            LeftVal = case InputIds of
                [LId2, _] -> get_schema(G, LId2) -- SharedVars;
                _ -> []
            end,
            _ = RSchema,
            {{antijoin, SharedVars, LeftVal}, []};
        circuit_call ->
            error({unlowered_circuit_call, Args});
        circuit_access ->
            error({unlowered_circuit_access, Args})
    end.

%%====================================================================
%% Fixpoint construction from lowered metadata
%%====================================================================

check_row_fn_arity(Op, FnName, FnParams) ->
    case maps:find(FnName, FnParams) of
        {ok, #{pos := Pos}} when length(Pos) =:= 1 ->
            ok;
        {ok, #{pos := Pos}} ->
            throw({compile_error, {row_fn_arity, Op, FnName, length(Pos)}});
        error ->
            ok
    end.

construct_fixpoints(G, Fixpoints, LnIdMap, CircuitFixpointInputs,
                     CircuitFixpointOutputs) ->
    {G1, AllRecOutputIds} = maps:fold(
        fun(FpHmac, FixInfo, {GAcc, ROIdsAcc}) ->
            construct_one_fixpoint(GAcc, FpHmac, FixInfo, LnIdMap,
                                    CircuitFixpointInputs, CircuitFixpointOutputs,
                                    ROIdsAcc)
        end,
        {G, #{}},
        Fixpoints),
    {G1, AllRecOutputIds}.

construct_one_fixpoint(G0, _FpHmac, FixInfo, LnIdMap, CInputMap,
                        _COutputMap, ROIdsAcc) ->
    #{params := ParamsInfo} = FixInfo,
    ParamsList = maps:to_list(ParamsInfo),
    SelfRefParams = [{K, V} || {K, V} <- ParamsList,
                                maps:get(kind, V) =:= self_ref],
    BaseParams = [{K, V} || {K, V} <- ParamsList,
                            maps:get(kind, V) =:= base],
    AllParams = SelfRefParams ++ BaseParams,
    SccId = G0#circuit_graph.next_id,
    Nodes = G0#circuit_graph.nodes,

    OrigIns    = original_inputs_for_params(AllParams, CInputMap, Nodes),
    DSet       = build_downstream_set(AllParams, CInputMap, Nodes),
    {G1, RIds} = create_rec_nodes(AllParams, OrigIns, DSet, LnIdMap, SccId, G0),
    {G2, ROIds, BodyToRO} = create_rec_output_nodes(SelfRefParams, LnIdMap, SccId, G1),

    RecIdList = maps:values(RIds) ++ maps:values(ROIds),
    ROIdSet   = maps:from_list([{Id, Id} || {_, Id} <- maps:to_list(ROIds)]),
    G3 = mark_scc_body_nodes(G2, RecIdList, ROIdSet, SccId),
    G4 = rewire_body_consumers(G3, BodyToRO, SccId),
    G5 = propagate_fixpoint_schemas(G4, BaseParams, CInputMap, RIds, ROIds),

    NewROAcc = maps:merge(ROIdsAcc, maps:from_list(
        [{maps:get(label, maps:get(KwBin, ParamsInfo)), ROId}
         || {KwBin, ROId} <- maps:to_list(ROIds)])),
    {G5, NewROAcc}.

%%--------------------------------------------------------------------
%% Fixpoint helpers
%%--------------------------------------------------------------------

-spec original_inputs_for_params([{binary(), map()}], map(), map()) ->
    map().
original_inputs_for_params(AllParams, CInputMap, Nodes) ->
    maps:from_list(
        [{K, begin
            PlaceholderId = maps:get(maps:get(input, ParamInfo), CInputMap),
            case maps:find(PlaceholderId, Nodes) of
                {ok, #circuit_node{inputs = Ins}} -> {PlaceholderId, Ins};
                error -> {PlaceholderId, []}
            end
         end} || {K, ParamInfo} <- AllParams]).

-spec build_downstream_set([{binary(), map()}], map(), map()) ->
    sets:set().
build_downstream_set(AllParams, CInputMap, Nodes) ->
    DownstreamIds = [
        begin
            PlaceholderId = maps:get(maps:get(input, ParamInfo), CInputMap),
            {PlaceholderId, has_downstream_consumers(PlaceholderId, Nodes)}
        end || {_K, ParamInfo} <- AllParams],
    sets:from_list([Id || {Id, true} <- DownstreamIds]).

-spec create_rec_nodes([{binary(), map()}], map(), sets:set(),
                       map(), non_neg_integer(), #circuit_graph{}) ->
    {#circuit_graph{}, map()}.
create_rec_nodes(AllParams, OriginalInputs, DownstreamSet,
                 LnIdMap, SccId, G) ->
    lists:foldl(
        fun({KwBin, ParamInfo}, {GA, RIds}) ->
            {PlaceholderId, OrigIns} = maps:get(KwBin, OriginalInputs),
            IsSelfRef = maps:get(kind, ParamInfo) =:= self_ref,
            IsBase = not IsSelfRef,
            case IsBase andalso not sets:is_element(PlaceholderId, DownstreamSet) of
                true ->
                    {GA, RIds};
                false ->
                    RecName = maps:get(label, ParamInfo),
                    BodyOutAddon = case IsSelfRef of
                        true ->
                            BodyOutLId = maps:get(body_out, ParamInfo),
                            [maps:get(BodyOutLId, LnIdMap)];
                        false -> []
                    end,
                    RecInputs = lists:usort(OrigIns) ++ BodyOutAddon,
                    HasSource = OrigIns =/= [],
                    RecMeta = #{sourced => HasSource, scc_id => SccId},
                    RecMeta2 = case IsSelfRef of
                        true -> RecMeta#{has_body_out => true};
                        false -> RecMeta
                    end,
                    RecNode = #circuit_node{
                        id = PlaceholderId,
                        op = {rec, RecName, SccId},
                        inputs = RecInputs,
                        meta = RecMeta2},
                    Nodes2 = maps:put(PlaceholderId, RecNode, GA#circuit_graph.nodes),
                    {GA#circuit_graph{nodes = Nodes2}, RIds#{KwBin => PlaceholderId}}
            end
        end,
        {G, #{}},
        AllParams).

-spec create_rec_output_nodes([{binary(), map()}], map(),
                              non_neg_integer(), #circuit_graph{}) ->
    {#circuit_graph{}, map(), map()}.
create_rec_output_nodes(SelfRefParams, LnIdMap, SccId, G) ->
    lists:foldl(
        fun({KwBin, ParamInfo}, {GA, OutIds, BToR}) ->
            BodyOutLId = maps:get(body_out, ParamInfo),
            BodyOutCId = maps:get(BodyOutLId, LnIdMap),
            RecOutName = maps:get(label, ParamInfo),
            RecOutId = GA#circuit_graph.next_id,
            RONode = #circuit_node{
                id = RecOutId,
                op = {rec_output, RecOutName, SccId},
                inputs = [BodyOutCId],
                meta = #{scc_id => SccId}},
            Nodes3 = maps:put(RecOutId, RONode, GA#circuit_graph.nodes),
            GA2 = GA#circuit_graph{next_id = RecOutId + 1, nodes = Nodes3},
            Schema = get_schema(GA, BodyOutCId),
            GA3 = set_schema(GA2, RecOutId, Schema),
            {GA3, OutIds#{KwBin => RecOutId}, BToR#{BodyOutCId => RecOutId}}
        end,
        {G, #{}, #{}},
        SelfRefParams).

-spec rewire_body_consumers(#circuit_graph{}, map(), non_neg_integer()) ->
    #circuit_graph{}.
rewire_body_consumers(G, BodyToRecOut, _SccId) when map_size(BodyToRecOut) =:= 0 ->
    G;
rewire_body_consumers(G, BodyToRecOut, SccId) ->
    FixedNodes = maps:map(
        fun(_NId, CNode = #circuit_node{inputs = CIns, meta = CMeta}) ->
            case is_same_scc_body(CMeta, SccId) of
                true -> CNode;
                false ->
                    NewIns = lists:map(
                        fun(InId) ->
                            case maps:find(InId, BodyToRecOut) of
                                {ok, RecOutId} -> RecOutId;
                                error -> InId
                            end
                        end, CIns),
                    case NewIns =:= CIns of
                        true -> CNode;
                        false -> CNode#circuit_node{inputs = NewIns}
                    end
            end
        end, G#circuit_graph.nodes),
    G#circuit_graph{nodes = FixedNodes}.

-spec is_same_scc_body(map(), non_neg_integer()) -> boolean().
is_same_scc_body(#{scc_id := NodeSccId}, CurrentSccId) ->
    NodeSccId =:= CurrentSccId;
is_same_scc_body(_, _) -> false.

-spec validate_rec_source_inputs(#circuit_graph{}) -> ok.
validate_rec_source_inputs(#circuit_graph{nodes = Nodes}) ->
    BodyToRecOut = build_body_to_rec_out(Nodes),
    Errors = maps:fold(
        fun(NodeId, #circuit_node{op = {rec, Name, RecSccId}, inputs = Ins}, Acc) ->
            Bad = lists:filter(
                fun(InId) ->
                    case maps:find(InId, BodyToRecOut) of
                        {ok, RecOutId} ->
                            case maps:find(RecOutId, Nodes) of
                                {ok, #circuit_node{op = {rec_output, _, ROutSccId}}} ->
                                    ROutSccId =/= RecSccId;
                                error -> false
                            end;
                        error -> false
                    end
                end, Ins),
            case Bad of
                [] -> Acc;
                _ -> [{Name, RecSccId, NodeId, Bad} | Acc]
            end;
           (_, _, Acc) -> Acc
        end, [], Nodes),
    case Errors of
        [] -> ok;
        _ -> error({rec_source_bypasses_rec_output, Errors})
    end.

-spec build_body_to_rec_out(#{node_id() => #circuit_node{}}) ->
    #{node_id() => node_id()}.
build_body_to_rec_out(Nodes) ->
    maps:fold(
        fun(RecOutId, #circuit_node{op = {rec_output, _, _}, inputs = [BodyId]}, Acc) ->
            Acc#{BodyId => RecOutId};
           (_, _, Acc) -> Acc
        end, #{}, Nodes).

-spec propagate_fixpoint_schemas(#circuit_graph{}, [{binary(), map()}],
                                 map(), map(), map()) -> #circuit_graph{}.
propagate_fixpoint_schemas(G, BaseParams, CInputMap, RecIds, RecOutputIds) ->
    BaseInputIds = [maps:get(maps:get(input, V), CInputMap)
                    || {_K, V} <- BaseParams],
    {BaseSchema, BaseType} = case BaseInputIds of
        [FirstBaseId | _] ->
            {get_schema(G, FirstBaseId), get_type(G, FirstBaseId)};
        [] ->
            {[], undefined}
    end,
    G1 = lists:foldl(
        fun(RecId, GAcc) ->
            GA = set_schema(GAcc, RecId, BaseSchema),
            set_type(GA, RecId, BaseType)
        end, G, maps:values(RecIds)),
    lists:foldl(
        fun(ROId, GAcc) ->
            GA = set_schema(GAcc, ROId, BaseSchema),
            set_type(GA, ROId, BaseType)
        end, G1, maps:values(RecOutputIds)).

%% @doc Does the integrate node at PlaceholderId have any downstream
%% consumers in the circuit graph (any node with PlaceholderId in its
%% input list)?
has_downstream_consumers(PlaceholderId, Nodes) ->
    lists:any(
        fun({_Id, #circuit_node{inputs = Ins}}) ->
            lists:member(PlaceholderId, Ins)
        end, maps:to_list(Nodes)).

%%====================================================================
%% Schema computation for lowered nodes
%%====================================================================

compute_schema_lowered(Op, Args, InputIds, TS, G) ->
    case Op of
        source ->
            case TS of
                {struct, Fields, _} -> maps:keys(Fields);
                _ -> []
            end;
        flat_map ->
            _FnName = get_var_arg(Args, 2),
            OutSchema = case TS of
                {struct, Fields, _} -> maps:keys(Fields);
                _ -> []
            end,
            InputCols = get_schema(G, hd(InputIds)),
            OutSchema ++ (OutSchema -- InputCols);
        aggregate ->
            {by, ByFields} = get_kw_arg(Args, by, []),
            {as, AsField} = get_kw_arg(Args, 'as', <<>>),
            ByFields ++ [AsField];
        join ->
            case TS of
                {struct, Fields, _} when map_size(Fields) > 0 ->
                    maps:keys(Fields);
                _ ->
                    {on, OnFields} = get_kw_arg(Args, on, []),
                    LSchema = get_schema(G, hd(InputIds)),
                    RSchema = get_schema(G, lists:nth(2, InputIds)),
                    LeftVal = LSchema -- OnFields,
                    RightVal = RSchema -- OnFields,
                    OnFields ++ LeftVal ++ RightVal
            end;
        project ->
            get_string_list_arg(Args, 2);
        distinct -> inherit_schema(InputIds, G);
        plus     -> inherit_schema(InputIds, G);
        map      -> inherit_schema(InputIds, G);
        filter   -> inherit_schema(InputIds, G);
        neg      -> inherit_schema(InputIds, G);
        integrate   -> inherit_schema(InputIds, G);
        differentiate -> inherit_schema(InputIds, G);
        delay -> inherit_schema(InputIds, G);
        antijoin -> inherit_schema(InputIds, G);
        _ -> inherit_schema(InputIds, G)
    end.

%%====================================================================
%% Tag → circuit ID mapping
%%====================================================================

build_tag_to_id(TagMap, LnIdMap) ->
    maps:fold(
        fun(Tag, LId, Acc) ->
            case maps:find(LId, LnIdMap) of
                {ok, CId} -> Acc#{Tag => CId};
                error -> Acc
            end
        end,
        #{},
        TagMap).

add_circuit_node(G, OpTuple, InputIds, Meta) ->
    Id = G#circuit_graph.next_id,
    Node = #circuit_node{id = Id, op = OpTuple, inputs = InputIds, meta = Meta},
    G2 = G#circuit_graph{next_id = Id + 1,
                         nodes = maps:put(Id, Node, G#circuit_graph.nodes)},
    {G2, Id}.

validate_graph(#circuit_graph{nodes = Nodes}) ->
    NodeIds = sets:from_list(maps:keys(Nodes), [{version, 2}]),
    maps:foreach(
        fun(NodeId, #circuit_node{op = Op, inputs = Inputs}) ->
            validate_node_inputs(NodeId, Op, Inputs, NodeIds)
        end, Nodes),
    ok.

validate_node_inputs(NodeId, Op, Inputs, ValidIds) ->
    lists:foreach(
        fun(InId) ->
            case sets:is_element(InId, ValidIds) of
                false ->
                    io:format(standard_error,
                              "validate_graph: node ~p references unknown input ~p~n",
                              [NodeId, InId]);
                true -> ok
            end
        end, Inputs),
    case element(1, Op) of
        rec ->
            case Inputs of
                [] ->
                    io:format(standard_error,
                              "validate_graph: Rec node ~p has no inputs~n",
                              [NodeId]);
                _ -> ok
            end;
        rec_output ->
            case Inputs of
                [_Single] -> ok;
                _ ->
                    io:format(standard_error,
                              "validate_graph: rec_output ~p has ~w inputs, expected 1~n",
                              [NodeId, length(Inputs)])
            end;
        _ -> ok
    end.

new_graph() ->
    #circuit_graph{next_id = 1, nodes = #{}, schemas = #{}}.


%%--------------------------------------------------------------------
%% Mark body operators as scc_body (downstream of Rec, stops at RecOutput)
%%--------------------------------------------------------------------

mark_scc_body_nodes(#circuit_graph{nodes = Nodes} = G, RecIds, RecOutputIds, SccId) ->
    RecOutputIdSet = sets:from_list(maps:values(RecOutputIds), [{version, 2}]),
    RecIdSet = sets:from_list(RecIds, [{version, 2}]),
    ConsumerIndex = build_consumer_index(Nodes),
    Nodes2 = mark_forward(Nodes, RecIds, RecIdSet, RecOutputIdSet, ConsumerIndex,
                          sets:new([{version, 2}]), SccId),
    G#circuit_graph{nodes = Nodes2}.

mark_forward(Nodes, [], _RecIdSet, _RecOutputIdSet, _ConsumerIndex, _Visited, _SccId) ->
    Nodes;
mark_forward(Nodes, [Id | Rest], RecIdSet, RecOutputIdSet, ConsumerIndex, Visited, SccId) ->
    case sets:is_element(Id, Visited) of
        true ->
            mark_forward(Nodes, Rest, RecIdSet, RecOutputIdSet, ConsumerIndex, Visited, SccId);
        false ->
            Visited1 = sets:add_element(Id, Visited),
            #circuit_node{op = Op, meta = Meta} = maps:get(Id, Nodes),
            OpTag = element(1, Op),
            IsRec = OpTag =:= rec,
            IsRecOutput = OpTag =:= rec_output,
            IsForeignRec = IsRec andalso not sets:is_element(Id, RecIdSet),
            AlreadyMarked = maps:is_key(scc_id, Meta),
            case AlreadyMarked orelse IsForeignRec orelse IsRecOutput of
                true ->
                    mark_forward(Nodes, Rest, RecIdSet, RecOutputIdSet, ConsumerIndex, Visited1, SccId);
                false ->
                    NewMeta = maps:put(scc_id, SccId, Meta),
                    Nodes1 = maps:put(Id, (maps:get(Id, Nodes))#circuit_node{meta = NewMeta}, Nodes),
                    Children = maps:get(Id, ConsumerIndex, []),
                    mark_forward(Nodes1, Rest ++ Children, RecIdSet, RecOutputIdSet,
                                 ConsumerIndex, Visited1, SccId)
            end
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

%%====================================================================

resolve_fn(FnName, FnReg, FnParams) ->
    case maps:find(FnName, FnReg) of
        {ok, ExprJson} ->
            case gdbsp_expr:json_to_expr(ExprJson) of
                {ok, Expr} ->
                    Reduced = beta_reduce(Expr, FnReg, FnParams,
                                          sets:from_list([FnName])),
                    {Reduced, fn_arg_name(FnName, FnParams)};
                {error, _} = Err -> throw({compile_error, {invalid_fn_expr, FnName, Err}})
            end;
        error ->
            throw({compile_error, {missing_function, FnName}})
    end.

fn_arg_name(FnName, FnParams) ->
    case maps:find(FnName, FnParams) of
        {ok, #{pos := [ArgName | _]}} -> ArgName;
        _ -> <<"row">>
    end.

%%====================================================================
%% Inline-function call beta-reduction
%%====================================================================

beta_reduce({call, Name, PosArgs, KwArgs}, FnReg, FnParams, InProgress) ->
    RedPos = [beta_reduce(A, FnReg, FnParams, InProgress) || A <- PosArgs],
    RedKw = maps:map(fun(_K, V) -> beta_reduce(V, FnReg, FnParams, InProgress) end, KwArgs),
    case maps:is_key(Name, FnReg) of
        true ->
            case sets:is_element(Name, InProgress) of
                true ->
                    throw({compile_error, {recursive_function, Name}});
                false ->
                    case gdbsp_expr:json_to_expr(maps:get(Name, FnReg)) of
                        {ok, CalleeExpr} ->
                            CalleeRed = beta_reduce(CalleeExpr, FnReg, FnParams,
                                                    sets:add_element(Name, InProgress)),
                            substitute(CalleeRed, RedPos, RedKw, Name, FnParams);
                        {error, _} ->
                            {call, Name, RedPos, RedKw}
                    end
            end;
        false ->
            {call, Name, RedPos, RedKw}
    end;
beta_reduce({get, Obj, Keys}, FnReg, FnParams, InProgress) ->
    {get, beta_reduce(Obj, FnReg, FnParams, InProgress),
     [beta_reduce(K, FnReg, FnParams, InProgress) || K <- Keys]};
beta_reduce({slice, Obj, Start, Stop, Step}, FnReg, FnParams, InProgress) ->
    {slice, beta_reduce(Obj, FnReg, FnParams, InProgress),
            beta_reduce_opt(Start, FnReg, FnParams, InProgress),
            beta_reduce_opt(Stop, FnReg, FnParams, InProgress),
            beta_reduce_opt(Step, FnReg, FnParams, InProgress)};
beta_reduce(Other, _FnReg, _FnParams, _InProgress) ->
    Other.

beta_reduce_opt(undefined, _FnReg, _FnParams, _InProgress) -> undefined;
beta_reduce_opt(E, FnReg, FnParams, InProgress) ->
    beta_reduce(E, FnReg, FnParams, InProgress).

%% Substitute a callee's declared positional/kw parameters (by exact name)
%% with the caller's argument expressions.
substitute(Body, PosArgs, KwArgs, CalleeName, FnParams) ->
    #{pos := PosNames, kw := KwParams} = fn_params_for(CalleeName, FnParams),
    PosBindings = lists:zip(PosNames, PosArgs),
    KwBindings = maps:from_list(
        [{Var, maps:get(Key, KwArgs)}
         || {Key, Var} <- KwParams, maps:is_key(Key, KwArgs)]),
    do_substitute(Body, PosBindings, KwBindings).

fn_params_for(Name, FnParams) ->
    maps:get(Name, FnParams, #{pos => [<<"row">>], kw => []}).

do_substitute({arg, Name}, PosBindings, KwBindings) ->
    case lists:keyfind(Name, 1, PosBindings) of
        {Name, ArgExpr} -> ArgExpr;
        false ->
            case maps:find(Name, KwBindings) of
                {ok, ArgExpr} -> ArgExpr;
                error -> {arg, Name}
            end
    end;
do_substitute({call, Name, PosArgs, KwArgs}, PB, KB) ->
    {call, Name, [do_substitute(A, PB, KB) || A <- PosArgs],
           maps:map(fun(_K, V) -> do_substitute(V, PB, KB) end, KwArgs)};
do_substitute({get, Obj, Keys}, PB, KB) ->
    {get, do_substitute(Obj, PB, KB), [do_substitute(K, PB, KB) || K <- Keys]};
do_substitute({slice, Obj, Start, Stop, Step}, PB, KB) ->
    {slice, do_substitute(Obj, PB, KB),
            do_substitute_opt(Start, PB, KB),
            do_substitute_opt(Stop, PB, KB),
            do_substitute_opt(Step, PB, KB)};
do_substitute(Other, _PB, _KB) ->
    Other.

do_substitute_opt(undefined, _PB, _KB) -> undefined;
do_substitute_opt(E, PB, KB) -> do_substitute(E, PB, KB).

resolve_agg_fn_name(FnName, FnReg) ->
    case maps:find(FnName, FnReg) of
        {ok, #{<<"aggregate">> := AggName}} when is_binary(AggName) ->
            AggName;
        {ok, _} ->
            throw({compile_error, {invalid_agg_fn, FnName}});
        error ->
            FnName
    end.

inherit_schema([Id | _], G) -> get_schema(G, Id);
inherit_schema(_, _) -> [].

%%====================================================================
%% Graph helpers
%%====================================================================

add_with_sub_nodes(G, OpTuple, InputIds, SubNodes) ->
    add_sub_nodes(G, SubNodes, InputIds, OpTuple).

add_sub_nodes(G, [], InputIds, OpTuple) ->
    Id = G#circuit_graph.next_id,
    Node = #circuit_node{id = Id, op = OpTuple, inputs = InputIds, meta = #{}},
    G2 = G#circuit_graph{next_id = Id + 1,
                         nodes = maps:put(Id, Node, G#circuit_graph.nodes)},
    {G2, Id};
add_sub_nodes(G, [{SubOp, SubSpec} | Rest], PrevInputs, FinalOp) ->
    Id = G#circuit_graph.next_id,
    OpTuple = case SubOp of
        map_index -> {map_index, SubSpec};
        map -> {map, SubSpec}
    end,
    Node = #circuit_node{id = Id, op = OpTuple, inputs = PrevInputs, meta = #{}},
    G2 = G#circuit_graph{next_id = Id + 1,
                         nodes = maps:put(Id, Node, G#circuit_graph.nodes)},
    add_sub_nodes(G2, Rest, [Id], FinalOp).

set_schema(G, NodeId, Columns) ->
    G#circuit_graph{schemas = maps:put(NodeId, Columns, G#circuit_graph.schemas)}.

get_schema(G, NodeId) ->
    maps:get(NodeId, G#circuit_graph.schemas, []).

set_type(G, NodeId, Type) when Type =/= undefined, Type =/= dynamic ->
    G#circuit_graph{types = maps:put(NodeId, Type, G#circuit_graph.types)};
set_type(G, _NodeId, _Type) ->
    G.

get_type(G, NodeId) ->
    maps:get(NodeId, G#circuit_graph.types, undefined).

%%====================================================================
%% Type helpers
%%====================================================================

get_input_row_type([Id | _], G) ->
    %% Traverse back to find the typespec from the chain of nodes.
    %% For now, return a simple type based on schema.
    %% In a full implementation, this would carry types through the graph.
    Cols = get_schema(G, Id),
    case Cols of
        [] -> undefined;
        _ ->
            FieldMap = maps:from_list([{C, dynamic} || C <- Cols]),
            {struct, FieldMap, exact}
    end.


struct_field_names({struct, Fields, _}) -> maps:keys(Fields);
struct_field_names(_) -> [].

build_merged_fields(Shared, LeftVal, RightVal, LType, RType) ->
    KeyFields = get_fields(LType, Shared),
    LFields = get_fields(LType, LeftVal),
    RFields = get_fields(RType, RightVal),
    maps:from_list(KeyFields ++ LFields ++ RFields).

get_fields({struct, Fs, _}, Names) ->
    [{K, maps:get(K, Fs, dynamic)} || K <- Names];
get_fields(_, Names) ->
    [{K, dynamic} || K <- Names].

%%====================================================================
%% Arg helpers
%%====================================================================

get_var_arg(Args, Pos) ->
    case lists:nth(Pos, Args) of
        {var, N} when is_binary(N) -> N;
        _ -> error({bad_arg, Pos, var})
    end.

get_string_arg(Args, Pos) ->
    case lists:nth(Pos, Args) of
        {string, S} when is_binary(S) -> S;
        _ -> error({bad_arg, Pos, string})
    end.

get_kw_arg(Args, Key, Default) ->
    case lists:keyfind(Key, 1, Args) of
        {Key, Val} -> {Key, Val};
        false -> {Key, Default}
    end.

get_string_list_arg(Args, Pos) ->
    case lists:nth(Pos, Args) of
        {var, Bin} when is_binary(Bin) ->
            case binary:match(Bin, <<"[">>) of
                nomatch -> [Bin];
                _ -> parse_string_list(Bin)
            end;
        L when is_list(L) -> L;
        _ -> error({bad_arg, Pos, string_list})
    end.

