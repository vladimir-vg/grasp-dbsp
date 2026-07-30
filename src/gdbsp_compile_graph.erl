%%%-------------------------------------------------------------------
%%% @doc Circuit graph construction from parsed GDBSP program.
%%%
%%% Transforms #gdbsp_program{} into #circuit_graph{}.
%%% Handles name resolution, topological sort, operator mapping,
%%% and schema computation.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_graph).

-export([build/4, build_from_lowered/2]).

-include("gdbsp_parse.hrl").
-include("gdbsp_circuit.hrl").
-include("gdbsp_lowered.hrl").
-include("gdbsp_type.hrl").
-include("gdbsp_expr.hrl").
-include("gdbsp_op.hrl").

-define(EPS, 1.0e-12).

%%====================================================================
%% Public API
%%====================================================================

-type fn_registry() :: #{binary() := jsx:json_term()}.

-spec build([#gdbsp_node_def{}], [#gdbsp_typespec{}], fn_registry(),
              [#gdbsp_circuit_def{}]) ->
    {ok, #circuit_graph{}, #{binary() => node_id()}} | {error, term()}.
build(Nodes, Typespecs, FnReg, CircuitDefs) ->
    case resolve_names(Nodes, Typespecs) of
        {ok, NameTable} ->
            case topo_sort(NameTable) of
                {ok, Order} ->
                    {Graph, NameToId} = construct(NameTable, Order, FnReg, CircuitDefs),
                    ok = validate_graph(Graph),
                    {ok, Graph, NameToId};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end.

%%====================================================================
%% Name resolution
%%====================================================================

-record(node_info, {
    name      :: binary(),
    op        :: atom(),
    args      :: list(),
    typespec  :: gdbsp_column_type() | undefined,
    line      :: pos_integer()
}).

resolve_names(Nodes, Typespecs) ->
    TSMap = typespecs_to_map(Typespecs),
    resolve_names(Nodes, TSMap, #{}, []).

resolve_names([], _TSMap, Acc, _Order) ->
    {ok, Acc};
resolve_names([#gdbsp_node_def{name = N, op = Op, args = Args, line = L} | Rest],
              TSMap, Acc, Order) ->
    case maps:is_key(N, Acc) of
        true -> {error, {duplicate_node, N}};
        false ->
            TS = maps:get(N, TSMap, undefined),
            Info = #node_info{name = N, op = Op, args = Args, typespec = TS, line = L},
            resolve_names(Rest, TSMap, Acc#{N => Info}, [N | Order])
    end.

typespecs_to_map(Typespecs) ->
    lists:foldl(fun(#gdbsp_typespec{name = N, spec = {type, {stream, Inner}}}, Acc) ->
                         maps:put(N, Inner, Acc);
                    (#gdbsp_typespec{name = N, spec = {type, T}}, Acc) ->
                         maps:put(N, T, Acc);
                    (#gdbsp_typespec{name = N, spec = {Kind, Params, Ret}}, Acc) ->
                         maps:put(N, {Kind, Params, Ret}, Acc)
                end, #{}, Typespecs).

%%====================================================================
%% Topological sort
%%====================================================================

topo_sort(NameTable) ->
    InDeg = maps:map(fun(_N, Info) ->
        Refs = node_refs_from_args(Info#node_info.args, NameTable),
        case Info#node_info.op of
            delay ->
                length([R || R <- Refs, R =/= Info#node_info.name]);
            _ -> length(Refs)
        end
    end, NameTable),
    Consumers = build_consumers(NameTable),
    AllNames = maps:keys(NameTable),
    Queue = [N || N <- AllNames, maps:get(N, InDeg) =:= 0],
    topo_loop(queue:from_list(Queue), InDeg, Consumers, NameTable, []).

build_consumers(NameTable) ->
    lists:foldl(fun({N, Info}, Acc) ->
        Refs = node_refs_from_args(Info#node_info.args, NameTable),
        lists:foldl(fun(Ref, A) ->
            maps:update_with(Ref, fun(L) -> [N | L] end, [N], A)
        end, Acc, Refs)
    end, #{}, maps:to_list(NameTable)).

node_refs_from_args(Args, NameTable) ->
    lists:filtermap(fun
        ({var, Name}) when is_binary(Name) ->
            case maps:is_key(Name, NameTable) of true -> {true, Name}; false -> false end;
        ({_Kw, {var, Name}}) when is_binary(Name) ->
            case maps:is_key(Name, NameTable) of true -> {true, Name}; false -> false end;
        (_) -> false
    end, Args).

topo_loop(Queue, InDeg, Consumers, NameTable, Acc) ->
    case queue:out(Queue) of
        {empty, _} ->
            case length(Acc) =:= map_size(NameTable) of
                true -> {ok, lists:reverse(Acc)};
                false -> {error, cycle_in_graph}
            end;
        {{value, Name}, RestQ} ->
            NewAcc = [Name | Acc],
            Dependents = maps:get(Name, Consumers, []),
            {NewQ, NewIndeg} = lists:foldl(fun(Dep, {Q, ID}) ->
                NewD = maps:get(Dep, ID) - 1,
                ID2 = maps:put(Dep, NewD, ID),
                case NewD of
                    0 -> {queue:in(Dep, Q), ID2};
                    _ -> {Q, ID2}
                end
            end, {RestQ, InDeg}, Dependents),
            topo_loop(NewQ, NewIndeg, Consumers, NameTable, NewAcc)
    end.

%%====================================================================
%% Graph construction
%%====================================================================

construct(NameTable, Order, FnReg, CircuitDefs) ->
    {Graph0, IdMap} = lists:foldl(
        fun(Name, {G, IdMapAcc}) ->
            Info = maps:get(Name, NameTable),
            {G2, NodeId, ExtraIds} = build_node(G, Info, IdMapAcc,
                                                  NameTable, FnReg, CircuitDefs),
            Merged = maps:merge(IdMapAcc#{Name => NodeId}, ExtraIds),
            {G2, Merged}
        end,
        {new_graph(), #{}},
        Order
    ),
    {Graph0, IdMap}.

-spec build_from_lowered(#lowered_graph{}, fn_registry()) ->
    {ok, #circuit_graph{}, #{binary() => node_id()}} | {error, term()}.
build_from_lowered(#lowered_graph{nodes = LNodes, tag_map = TagMap,
                                  fixpoints = Fixpoints}, FnReg) ->
    NodeList = maps:to_list(LNodes),
    case lowered_topo_sort(NodeList) of
        {ok, Order} ->
            {Graph0, LnIdMap, CircuitFixpointInputs, CircuitFixpointOutputs} =
                construct_from_lowered(NodeList, Order, FnReg),
            {Graph1, RecOutputTags} = construct_fixpoints(Graph0, Fixpoints, LnIdMap,
                                          CircuitFixpointInputs, CircuitFixpointOutputs),
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
                end, {RestQ, InDeg}, sets:to_list(sets:from_list(Dependents))),
            lowered_topo_loop(NewQ, NewIndeg, Consumers, Total, NewAcc)
    end.

%%====================================================================
%% Circuit graph construction from lowered nodes
%%====================================================================

construct_from_lowered(NodeList, Order, FnReg) ->
    LNodeById = maps:from_list(NodeList),
    {G, LnIdMap, FixInMap, FixOutMap} = lists:foldl(
        fun(LId, {GAcc, IdMapAcc, FIMAcc, FOMAcc}) ->
            #lnode{op = Op, inputs = LInputs, args = Args, type = Type} =
                maps:get(LId, LNodeById),
            CInputIds = [maps:get(InId, IdMapAcc, InId) || InId <- LInputs],
            case Op of
                fixpoint_input ->
                    {G2, NodeId} = add_circuit_node(GAcc, {integrate}, CInputIds, #{}),
                    {G2, IdMapAcc#{LId => NodeId},
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
                    {G3, IdMapAcc#{LId => NodeId}, FIMAcc, FOMAcc};
                aggregate ->
                    {G2, NodeId} = build_aggregate_graph_lowered(GAcc, Args, CInputIds, FnReg),
                    Schema = compute_schema_lowered(Op, Args, CInputIds, Type, G2),
                    G3 = set_schema(G2, NodeId, Schema),
                    {G3, IdMapAcc#{LId => NodeId}, FIMAcc, FOMAcc};
                _ ->
                    {OpTuple, SubNodes} = make_operator_lowered(
                        GAcc, Op, Args, CInputIds, Type, FnReg),
                    {G2, FinalId} = add_with_sub_nodes(GAcc, OpTuple, CInputIds, SubNodes),
                    Schema = compute_schema_lowered(Op, Args, CInputIds, Type, G2),
                    G3 = set_schema(G2, FinalId, Schema),
                    {G3, IdMapAcc#{LId => FinalId}, FIMAcc, FOMAcc}
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

make_operator_lowered(G, Op, Args, InputIds, TS, FnReg) ->
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
            Expr = resolve_fn(FnName, FnReg),
            RowType = get_input_row_type(InputIds, G),
            Spec = #{kind => expr, expr => Expr, row_type => RowType},
            {{map, Spec}, []};
        filter ->
            FnName = get_var_arg(Args, 2),
            Expr = resolve_fn(FnName, FnReg),
            RowType = get_input_row_type(InputIds, G),
            {{filter, #{expr => Expr, row_type => RowType}}, []};
        flat_map ->
            FnName = get_var_arg(Args, 2),
            Expr = resolve_fn(FnName, FnReg),
            RowType = get_input_row_type(InputIds, G),
            OutType = case TS of
                {struct, _, _} = Struct -> Struct;
                undefined -> dynamic;
                _ -> TS
            end,
            AllCols = struct_field_names(OutType),
            InputCols = get_schema(G, hd(InputIds)),
            NewCols = AllCols -- InputCols,
            {{flat_map, #{expr => Expr, row_type => RowType,
                          unnest_outs => NewCols}}, []};
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
            {{antijoin, SharedVars, LeftVal}, []}
    end.

%%====================================================================
%% Fixpoint construction from lowered metadata
%%====================================================================

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
    #{circuit_name := _CName, params := ParamsInfo} = FixInfo,
    ParamsList = maps:to_list(ParamsInfo),
    SelfRefParams = [{K, V} || {K, V} <- ParamsList,
                                maps:get(kind, V) =:= self_ref],
    BaseParams = [{K, V} || {K, V} <- ParamsList,
                            maps:get(kind, V) =:= base],

    SccId = G0#circuit_graph.next_id,

    BaseInputIds = [maps:get(maps:get(input, V), CInputMap)
                    || {_K, V} <- BaseParams],
    BodyInputPlaceholders = maps:from_list(
        [{K, maps:get(maps:get(input, V), CInputMap)} || {K, V} <- SelfRefParams]),

    %% Create Rec nodes (rewrite fixpoint_input placeholders)
    {G1, RecIds} = lists:foldl(
        fun({KwBin, ParamInfo}, {GA, RIds}) ->
            PlaceholderId = maps:get(KwBin, BodyInputPlaceholders),
            BodyOutLId = maps:get(body_out, ParamInfo),
            BodyOutCId = maps:get(BodyOutLId, LnIdMap),
            RecName = maps:get(label, ParamInfo),
            RecInputs = lists:usort(BaseInputIds ++ [BodyOutCId]),
            HasBase = BaseInputIds =/= [],
            RecNode = #circuit_node{
                id = PlaceholderId,
                op = {rec, RecName, SccId},
                inputs = RecInputs,
                meta = #{sourced => HasBase, scc_body => true}},
            Nodes2 = maps:put(PlaceholderId, RecNode, GA#circuit_graph.nodes),
            {GA#circuit_graph{nodes = Nodes2}, RIds#{KwBin => PlaceholderId}}
        end,
        {G0, #{}},
        SelfRefParams),

    %% Create RecOutput nodes
    {G2, RecOutputIds, BodyToRecOut} = lists:foldl(
        fun({KwBin, ParamInfo}, {GA, OutIds, BToR}) ->
            BodyOutLId = maps:get(body_out, ParamInfo),
            BodyOutCId = maps:get(BodyOutLId, LnIdMap),
            RecOutName = maps:get(label, ParamInfo),
            RecOutId = GA#circuit_graph.next_id,
            RONode = #circuit_node{
                id = RecOutId,
                op = {rec_output, RecOutName, SccId},
                inputs = [BodyOutCId],
                meta = #{}},
            Nodes3 = maps:put(RecOutId, RONode, GA#circuit_graph.nodes),
            GA2 = GA#circuit_graph{next_id = RecOutId + 1, nodes = Nodes3},

            Schema = get_schema(GA, BodyOutCId),
            GA3 = set_schema(GA2, RecOutId, Schema),
            {GA3, OutIds#{KwBin => RecOutId}, BToR#{BodyOutCId => RecOutId}}
        end,
        {G1, #{}, #{}},
        SelfRefParams),

    RecIdList = [Id || {_, Id} <- maps:to_list(RecIds)] ++
               [Id || {_, Id} <- maps:to_list(RecOutputIds)],
    RecOutputIdSet = maps:from_list(
        [{Id, Id} || {_, Id} <- maps:to_list(RecOutputIds)]),
    G3 = mark_scc_body_nodes(G2, RecIdList, RecOutputIdSet),

    G4 = case map_size(BodyToRecOut) of
        0 -> G3;
        _ ->
            FixedNodes = maps:map(
                fun(_NId, CNode = #circuit_node{inputs = CIns, meta = CMeta}) ->
                    case maps:is_key(scc_body, CMeta) of
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
                end, G3#circuit_graph.nodes),
            G3#circuit_graph{nodes = FixedNodes}
    end,

    BaseSchema = case BaseInputIds of
        [FirstBaseId | _] -> get_schema(G4, FirstBaseId);
        [] -> []
    end,
    G5 = lists:foldl(
        fun({_, RecId}, GAcc) -> set_schema(GAcc, RecId, BaseSchema) end,
        G4, RecIds),
    G6 = lists:foldl(
        fun({_, ROId}, GAcc) -> set_schema(GAcc, ROId, BaseSchema) end,
        G5, RecOutputIds),

    NewROAcc = maps:merge(ROIdsAcc, maps:from_list(
        [{maps:get(label, maps:get(KwBin, ParamsInfo)), ROId}
         || {KwBin, ROId} <- maps:to_list(RecOutputIds)])),
    {G6, NewROAcc}.

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
            {on, OnFields} = get_kw_arg(Args, on, []),
            LSchema = get_schema(G, hd(InputIds)),
            RSchema = get_schema(G, lists:nth(2, InputIds)),
            LeftVal = LSchema -- OnFields,
            RightVal = RSchema -- OnFields,
            OnFields ++ LeftVal ++ RightVal;
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

build_node(G, Info, IdMap, NameTable, FnReg, CircuitDefs) ->
    #node_info{name = Name, op = Op, args = Args, typespec = TS} = Info,
    InputIds = resolve_input_ids(Args, IdMap, NameTable),
    case Op of
        fixpoint ->
            build_fixpoint_graph(G, Name, Args, TS, NameTable, FnReg, CircuitDefs, IdMap);
        fixpoint_rec ->
            build_fixpoint_rec(G, Name);
        join ->
            build_join_graph(G, Args, InputIds, TS, NameTable, FnReg);
        aggregate ->
            build_aggregate_graph(G, Args, InputIds, NameTable, FnReg);
        circuit_access ->
            build_legacy_circuit_access(G, Name, Args, IdMap, NameTable);
        _ ->
            {OpTuple, SubNodes} = make_operator(G, Name, Op, Args, InputIds, TS, NameTable, IdMap, FnReg),
            {G2, FinalId} = add_with_sub_nodes(G, OpTuple, InputIds, SubNodes),
            Schema = compute_schema(Op, Args, InputIds, TS, NameTable, G2),
            G3 = set_schema(G2, FinalId, Schema),
            {G3, FinalId, #{}}
    end.

build_fixpoint_rec(G, _Name) ->
    {G2, FinalId} = add_with_sub_nodes(G, {integrate}, [], []),
    {G2, FinalId, #{}}.

%%====================================================================
%% Input resolution
%%====================================================================

resolve_input_ids(Args, IdMap, _NameTable) ->
    lists:filtermap(fun
        ({var, Name}) ->
            case maps:find(Name, IdMap) of
                {ok, Id} -> {true, Id};
                error -> false
            end;
        (_) -> false
    end, Args).

%%====================================================================
%% Operator mapping
%%====================================================================

-spec make_operator(_, binary(), binary(), _, [node_id()], _, _, _, _) -> {operator(), [{binary(), map()}]}.
make_operator(G, _Name, Op, Args, InputIds, TS, NameTable, _IdMap, FnReg) ->
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
            Expr = resolve_fn(FnName, FnReg),
            RowType = get_input_row_type(InputIds, G),
            Spec = #{kind => expr, expr => Expr, row_type => RowType},
            {{map, Spec}, []};
        filter ->
            FnName = get_var_arg(Args, 2),
            Expr = resolve_fn(FnName, FnReg),
            RowType = get_input_row_type(InputIds, G),
            {{filter, #{expr => Expr, row_type => RowType}}, []};
        flat_map ->
            FnName = get_var_arg(Args, 2),
            Expr = resolve_fn(FnName, FnReg),
            RowType = get_input_row_type(InputIds, G),
            OutType = get_flat_map_out_type(FnName, TS, NameTable),
            AllCols = struct_field_names(OutType),
            InputCols = get_schema(G, hd(InputIds)),
            NewCols = AllCols -- InputCols,
            {{flat_map, #{expr => Expr, row_type => RowType,
                          unnest_outs => NewCols}}, []};
        join ->
            {on, _OnFields} = get_kw_arg(Args, on, []),
            [LId, RId] = InputIds,
            LSchema = get_schema(G, LId),
            RSchema = get_schema(G, RId),
            LType = get_input_row_type([LId], G),
            RType = get_input_row_type([RId], G),
            Shared = lists:filter(fun(F) -> lists:member(F, RSchema) end, LSchema),
            LeftVal = LSchema -- Shared,
            RightVal = RSchema -- Shared,
            Merged = build_merged_fields(Shared, LeftVal, RightVal, LType, RType),
            {{join, #{shared_vars => Shared,
                      left_val_vars => LeftVal,
                      right_val_vars => RightVal,
                      merged_fields => Merged}}, []};
        aggregate ->
            FnName = get_var_arg(Args, 2),
            AggBin = resolve_agg_fn_name(FnName, FnReg),
            {by, ByFields} = get_kw_arg(Args, by, []),
            {value, ValField} = get_kw_arg(Args, value, <<>>),
            {as, AsField} = get_kw_arg(Args, 'as', <<>>),
            RowType = get_input_row_type(InputIds, G),
            IdxSpec = #{key_vars => ByFields, agg_col => ValField},
            UnwrapSpec = #{kind => agg_unwrap, group_by => ByFields,
                           output_var => AsField, row_type => RowType},
            {{aggregate, AggBin}, [{map_index, IdxSpec}, {map, UnwrapSpec}]};
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
            {{antijoin, SharedVars, LeftVal}, []}
    end.

%%--------------------------------------------------------------------
%% Join graph construction — inserts map_index nodes for each input
%%--------------------------------------------------------------------

build_join_graph(G, Args, InputIds, _TS, _NameTable, _FnReg) ->
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

    %% Insert map_index for left input
    LeftIdxSpec = #{key_vars => Shared, val_vars => LeftVal},
    NextId0 = G#circuit_graph.next_id,
    LIdxNode = #circuit_node{id = NextId0, op = {map_index, LeftIdxSpec},
                              inputs = [LId], meta = #{}},
    G0 = G#circuit_graph{next_id = NextId0 + 1,
                         nodes = maps:put(NextId0, LIdxNode, G#circuit_graph.nodes)},
    G1 = set_schema(G0, NextId0, Shared ++ LeftVal),

    %% Insert map_index for right input
    NextId1 = G1#circuit_graph.next_id,
    RightIdxSpec = #{key_vars => Shared, val_vars => RightVal},
    RIdxNode = #circuit_node{id = NextId1, op = {map_index, RightIdxSpec},
                              inputs = [RId], meta = #{}},
    G2 = G1#circuit_graph{next_id = NextId1 + 1,
                          nodes = maps:put(NextId1, RIdxNode, G1#circuit_graph.nodes)},
    G3 = set_schema(G2, NextId1, Shared ++ RightVal),

    %% Build join node consuming both map_index outputs
    JoinId = G3#circuit_graph.next_id,
    JoinOp = {join, #{shared_vars => Shared, left_val_vars => LeftVal,
                      right_val_vars => RightVal, merged_fields => Merged}},
    JoinNode = #circuit_node{id = JoinId, op = JoinOp,
                              inputs = [NextId0, NextId1], meta = #{}},
    G4 = G3#circuit_graph{next_id = JoinId + 1,
                          nodes = maps:put(JoinId, JoinNode, G3#circuit_graph.nodes)},

    Schema = OnFields ++ LeftVal ++ RightVal,
    G5 = set_schema(G4, JoinId, Schema),
    {G5, JoinId, #{}}.

%%--------------------------------------------------------------------
%% Aggregate graph construction — map_index → aggregate → map(unwrap)
%%--------------------------------------------------------------------

build_aggregate_graph(G, Args, InputIds, _NameTable, FnReg) ->
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

    %% Create map_index → aggregate chain (pre-aggregate sub-nodes only)
    {G1, AggId} = add_with_sub_nodes(G, {aggregate, AggBin}, InputIds,
                                     [{map_index, IdxSpec}]),
    AggSchema = ByFields ++ [AsField],
    G2 = set_schema(G1, AggId, AggSchema),

    %% Create map(unwrap) node after aggregate
    UnwrapId = G2#circuit_graph.next_id,
    UnwrapNode = #circuit_node{id = UnwrapId, op = {map, UnwrapSpec},
                                inputs = [AggId], meta = #{}},
    G3 = G2#circuit_graph{next_id = UnwrapId + 1,
                          nodes = maps:put(UnwrapId, UnwrapNode, G2#circuit_graph.nodes)},
    G4 = set_schema(G3, UnwrapId, AggSchema),
    {G4, UnwrapId, #{}}.
%%====================================================================
%% Fixpoint graph construction — Rec/Coord subgraph
%%====================================================================

build_fixpoint_graph(G, FpName, Args, _TS, _NameTable, _FnReg, CircuitDefs, IdMap) ->
    [CircuitNameArg | KwArgs] = Args,
    CircuitName = case CircuitNameArg of
        {var, N} -> N;
        _ -> throw({compile_error, {fixpoint, bad_circuit_name}})
    end,
    DefMap = maps:from_list(
        [{D#gdbsp_circuit_def.name, D} || D <- CircuitDefs]),
    {ok, Def} = maps:find(CircuitName, DefMap),
    #gdbsp_circuit_def{params = Params, body = BodyNodes} = Def,
    BodyNodeNames = [N || #gdbsp_node_def{name = N} <- BodyNodes],
    BodyNodeMap = maps:from_list(
        [{N, D} || D = #gdbsp_node_def{name = N} <- BodyNodes]),

    Prefix = <<FpName/binary, "_">>,
    SccId = G#circuit_graph.next_id,
    SelfRefKws = [Kw || Kw <- maps:keys(Params),
                        lists:member(atom_to_binary(Kw, utf8), BodyNodeNames)],

    lists:foreach(
        fun(Kw) ->
            KwBin = atom_to_binary(Kw, utf8),
            NodeDef = maps:get(KwBin, BodyNodeMap),
            case NodeDef#gdbsp_node_def.op of
                distinct -> ok;
                _ -> throw({compile_error,
                            {fixpoint, {missing_distinct, KwBin}}})
            end
        end, SelfRefKws),

    BodyPrefixed = maps:from_list(
        [{BN, <<Prefix/binary, BN/binary>>} || BN <- BodyNodeNames]),
    BodyOpIds = maps:from_list(
        lists:filtermap(
            fun(BN) ->
                PN = maps:get(BN, BodyPrefixed),
                case maps:find(PN, IdMap) of
                    {ok, NodeId} -> {true, {BN, NodeId}};
                    error -> false
                end
            end,
            BodyNodeNames
        )
    ),

    KwArgsOnly = lists:filter(
        fun({K, _}) when is_atom(K) -> true; (_) -> false end, KwArgs),
    KwMap = maps:from_list(
        lists:map(
            fun({K, V}) -> {atom_to_binary(K, utf8), V} end, KwArgsOnly)),

    HasBase = lists:any(
        fun(Kw) -> not lists:member(Kw, SelfRefKws) end,
        maps:keys(Params)),

    BaseInputIds = lists:filtermap(
        fun(Kw) ->
            case lists:member(Kw, SelfRefKws) of
                true -> false;
                false ->
                    KwBin = atom_to_binary(Kw, utf8),
                    case maps:find(KwBin, KwMap) of
                        {ok, {var, VarName}} ->
                            case maps:find(VarName, IdMap) of
                                {ok, Id} -> {true, Id};
                                error ->
                                    throw({compile_error,
                                           {fixpoint, {unresolved_base_arg, VarName}}})
                            end;
                        _ -> false
                    end
            end
        end,
        maps:keys(Params)),

    {G1, RecIds} = lists:foldl(
        fun(Kw, {GA, RIds}) ->
            KwBin = atom_to_binary(Kw, utf8),
            RecRefName = <<Prefix/binary, KwBin/binary, "_rec">>,
            case maps:find(RecRefName, IdMap) of
                {ok, PlaceholderId} ->
                    BodyOpId = maps:get(KwBin, BodyOpIds),
                    RecName = <<Prefix/binary, KwBin/binary>>,
                    RecInputs = lists:usort(BaseInputIds ++ [BodyOpId]),
                    RecNode = #circuit_node{
                        id = PlaceholderId,
                        op = {rec, RecName, SccId},
                        inputs = RecInputs,
                        meta = #{sourced => HasBase, scc_body => true}},
                    Nodes2 = maps:put(PlaceholderId, RecNode, GA#circuit_graph.nodes),
                    GA2 = GA#circuit_graph{nodes = Nodes2},
                    {GA2, RIds#{Kw => PlaceholderId}};
                error ->
                    throw({compile_error,
                           {fixpoint, {missing_rec_ref, RecRefName}}})
            end
        end,
        {G, #{}},
        SelfRefKws
    ),

    {G2, RecOutputIds} = lists:foldl(
        fun(Kw, {GA, OutIds}) ->
            KwBin = atom_to_binary(Kw, utf8),
            RecId = maps:get(Kw, RecIds),
            RecOutName = <<Prefix/binary, KwBin/binary>>,
            RecOutId = GA#circuit_graph.next_id,
            RecOutNode = #circuit_node{
                id = RecOutId,
                op = {rec_output, RecOutName, SccId},
                inputs = [RecId],
                meta = #{}},
            Nodes2 = maps:put(RecOutId, RecOutNode, GA#circuit_graph.nodes),
            GA2 = GA#circuit_graph{
                next_id = RecOutId + 1,
                nodes = Nodes2},
            Schema = get_schema(GA, maps:get(KwBin, BodyOpIds)),
            GA3 = set_schema(GA2, RecOutId, Schema),
            {GA3, OutIds#{KwBin => RecOutId}}
        end,
        {G1, #{}},
        SelfRefKws
    ),

    ExtraIds = maps:from_list(
        lists:filtermap(
            fun(BN) ->
                case maps:find(BN, RecOutputIds) of
                    {ok, RecOutId} ->
                        {true, {maps:get(BN, BodyPrefixed), RecOutId}};
                    error -> false
                end
            end,
            BodyNodeNames
        )
    ),

    RecNodeIds = [Id || {_, Id} <- maps:to_list(RecIds)],
    G3 = mark_scc_body_nodes(G2, RecNodeIds, RecOutputIds),

    BaseSchema = case BaseInputIds of
        [FirstBaseId | _] -> get_schema(G3, FirstBaseId);
        [] -> []
    end,
    G4 = lists:foldl(
        fun(RecId, GAcc) -> set_schema(GAcc, RecId, BaseSchema) end,
        G3, maps:values(RecIds)),
    G5 = case maps:size(RecOutputIds) of
        0 -> G4;
        _ -> lists:foldl(
            fun(ROId, GAcc) -> set_schema(GAcc, ROId, BaseSchema) end,
            G4, maps:values(RecOutputIds))
    end,
    FinalId = case maps:size(RecOutputIds) of
        0 -> hd(lists:reverse(maps:values(RecIds)));
        _ -> hd(lists:reverse(maps:values(RecOutputIds)))
    end,
    G6 = set_schema(G5, FinalId, BaseSchema),

    %% Fix up any nodes whose inputs still reference raw body operator IDs
    %% instead of their RecOutput wrappers.  This can happen when the output
    %% pass-through node (e.g. "out := plus(fp_result)") is compiled before
    %% the fixpoint node in the topological order — its inputs were resolved
    %% before build_fixpoint_graph had a chance to install RecOutput overrides
    %% in IdMap.
    BodyToRecOutput = maps:fold(
        fun(KwBin, RecOutId, Acc) ->
            case maps:find(KwBin, BodyOpIds) of
                {ok, BodyId} -> Acc#{BodyId => RecOutId};
                error -> Acc
            end
        end, #{}, RecOutputIds),
    G7 = case map_size(BodyToRecOutput) of
        0 -> G6;
        _ ->
            FixedNodes = maps:map(
                fun(_NId, CNode = #circuit_node{inputs = CIns, meta = CMeta}) ->
                    case maps:is_key(scc_body, CMeta) of
                        true -> CNode;
                        false ->
                            NewIns = lists:map(
                                fun(InId) ->
                                    case maps:find(InId, BodyToRecOutput) of
                                        {ok, RecOutId} -> RecOutId;
                                        error -> InId
                                    end
                                end, CIns),
                            case NewIns =:= CIns of
                                true -> CNode;
                                false -> CNode#circuit_node{inputs = NewIns}
                            end
                    end
                end, G6#circuit_graph.nodes),
            G6#circuit_graph{nodes = FixedNodes}
    end,

    {G7, FinalId, ExtraIds}.

%%--------------------------------------------------------------------
%% Mark body operators as scc_body (downstream of Rec, stops at RecOutput)
%%--------------------------------------------------------------------

mark_scc_body_nodes(#circuit_graph{nodes = Nodes} = G, RecIds, RecOutputIds) ->
    RecOutputIdSet = sets:from_list(maps:values(RecOutputIds), [{version, 2}]),
    RecIdSet = sets:from_list(RecIds, [{version, 2}]),
    ConsumerIndex = build_consumer_index(Nodes),
    Nodes2 = mark_forward(Nodes, RecIds, RecIdSet, RecOutputIdSet, ConsumerIndex,
                          sets:new([{version, 2}])),
    G#circuit_graph{nodes = Nodes2}.

mark_forward(Nodes, [], _RecIdSet, _RecOutputIdSet, _ConsumerIndex, _Visited) ->
    Nodes;
mark_forward(Nodes, [Id | Rest], RecIdSet, RecOutputIdSet, ConsumerIndex, Visited) ->
    case sets:is_element(Id, Visited) of
        true ->
            mark_forward(Nodes, Rest, RecIdSet, RecOutputIdSet, ConsumerIndex, Visited);
        false ->
            Visited1 = sets:add_element(Id, Visited),
            #circuit_node{op = Op, meta = Meta} = maps:get(Id, Nodes),
            OpTag = element(1, Op),
            IsRec = OpTag =:= rec,
            IsRecOutput = OpTag =:= rec_output,
            IsForeignRec = IsRec andalso not sets:is_element(Id, RecIdSet),
            AlreadyMarked = maps:is_key(scc_body, Meta),
            case AlreadyMarked orelse IsForeignRec orelse IsRecOutput of
                true ->
                    mark_forward(Nodes, Rest, RecIdSet, RecOutputIdSet, ConsumerIndex, Visited1);
                false ->
                    NewMeta = maps:put(scc_body, true, Meta),
                    Nodes1 = maps:put(Id, (maps:get(Id, Nodes))#circuit_node{meta = NewMeta}, Nodes),
                    Children = maps:get(Id, ConsumerIndex, []),
                    mark_forward(Nodes1, Rest ++ Children, RecIdSet, RecOutputIdSet,
                                 ConsumerIndex, Visited1)
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

%%--------------------------------------------------------------------
%% Legacy circuit_access — resolves via IdMap (fallback for non-fixpoint uses)
%%--------------------------------------------------------------------

build_legacy_circuit_access(G, _Name, Args, IdMap, _NameTable) ->
    [{var, VarName}, {var, FieldName}] = Args,
    ResolvedName = <<VarName/binary, "_", FieldName/binary>>,
    case maps:find(ResolvedName, IdMap) of
        {ok, NodeId} ->
            Id = G#circuit_graph.next_id,
            Node = #circuit_node{id = Id, op = {plus},
                                  inputs = [NodeId], meta = #{}},
            G2 = G#circuit_graph{next_id = Id + 1,
                                  nodes = maps:put(Id, Node, G#circuit_graph.nodes)},
            Schema = get_schema(G, NodeId),
            G3 = set_schema(G2, Id, Schema),
            {G3, Id, #{}};
        error ->
            throw({compile_error, {unresolved_circuit_access, VarName, FieldName}})
    end.

%%====================================================================

resolve_fn(FnName, FnReg) ->
    case maps:find(FnName, FnReg) of
        {ok, ExprJson} ->
            case gdbsp_expr:json_to_expr(ExprJson) of
                {ok, Expr} -> Expr;
                {error, _} = Err -> throw({compile_error, {invalid_fn_expr, FnName, Err}})
            end;
        error ->
            throw({compile_error, {missing_function, FnName}})
    end.

resolve_agg_fn_name(FnName, FnReg) ->
    case maps:find(FnName, FnReg) of
        {ok, #{<<"aggregate">> := AggName}} when is_binary(AggName) ->
            AggName;
        {ok, _} ->
            throw({compile_error, {invalid_agg_fn, FnName}});
        error ->
            throw({compile_error, {missing_function, FnName}})
    end.

%%====================================================================
%% Schema computation
%%====================================================================

compute_schema(Op, Args, InputIds, TS, NameTable, G) ->
    case Op of
        source ->
            case TS of
                {struct, Fields, _} -> maps:keys(Fields);
                _ -> []
            end;
        flat_map ->
            FnName = get_var_arg(Args, 2),
            OutType = get_flat_map_out_type(FnName, TS, NameTable),
            struct_field_names(OutType);
        aggregate ->
            {by, ByFields} = get_kw_arg(Args, by, []),
            {as, AsField} = get_kw_arg(Args, 'as', <<>>),
            ByFields ++ [AsField];
        join ->
            {on, OnFields} = get_kw_arg(Args, on, []),
            LSchema = get_schema(G, hd(InputIds)),
            RSchema = get_schema(G, lists:nth(2, InputIds)),
            LeftVal = LSchema -- OnFields,
            RightVal = RSchema -- OnFields,
            OnFields ++ LeftVal ++ RightVal;
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

get_flat_map_out_type(FnName, TS, NameTable) ->
    case maps:find(FnName, NameTable) of
        {ok, #node_info{typespec = {function, _Params, Ret}}} ->
            case Ret of
                {array, ElemType, _} -> ElemType;
                _ -> dynamic
            end;
        _ ->
            case TS of
                {struct, _, _} = Struct -> Struct;
                undefined -> dynamic;
                _ -> TS
            end
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
        _ -> error({bad_arg, Pos, string_list})
    end.

parse_string_list(Bin) ->
    Trimmed = trim(Bin),
    case Trimmed of
        <<"[", _/binary>> ->
            Inner = binary:part(Trimmed, 1, byte_size(Trimmed) - 2),
            Tokens = split_top(Inner, <<",">>),
            [dequote(trim(T)) || T <- Tokens, trim(T) =/= <<>>];
        _ -> [Trimmed]
    end.

%%--------------------------------------------------------------------
%% Ported string helpers (minimal subset needed for arg parsing here)
%%--------------------------------------------------------------------

trim(Bin) when is_binary(Bin) ->
    trim_left(trim_right(Bin)).

trim_left(<<>>) -> <<>>;
trim_left(<<$\s, Rest/binary>>) -> trim_left(Rest);
trim_left(<<$\t, Rest/binary>>) -> trim_left(Rest);
trim_left(Bin) -> Bin.

trim_right(<<>>) -> <<>>;
trim_right(Bin) ->
    Size = byte_size(Bin),
    case binary:at(Bin, Size - 1) of
        $\s -> trim_right(binary:part(Bin, 0, Size - 1));
        $\t -> trim_right(binary:part(Bin, 0, Size - 1));
        $\r -> trim_right(binary:part(Bin, 0, Size - 1));
        $\n -> trim_right(binary:part(Bin, 0, Size - 1));
        _ -> Bin
    end.

dequote(Bin) ->
    Trimmed = trim(Bin),
    Size = byte_size(Trimmed),
    if Size >= 2 ->
        case {binary:first(Trimmed), binary:last(Trimmed)} of
            {$", $"} -> binary:part(Trimmed, 1, Size - 2);
            _ -> Trimmed
        end;
       true -> Trimmed
    end.

split_top(Bin, Sep) ->
    split_top(Bin, Sep, 0, 0, [], <<>>).

split_top(<<>>, _Sep, _Depth, _Quote, Acc, Buf) ->
    case trim(Buf) of
        <<>> -> lists:reverse(Acc);
        _ -> lists:reverse([Buf | Acc])
    end;
split_top(<<C, Rest/binary>>, Sep, Depth, Quote, Acc, Buf) ->
    SepSize = byte_size(Sep),
    case {Depth, Quote} of
        {0, 0} when C =:= $" ->
            split_top(Rest, Sep, 0, 1, Acc, <<Buf/binary, C>>);
        {0, 1} when C =:= $" ->
            split_top(Rest, Sep, 0, 0, Acc, <<Buf/binary, C>>);
        {_, _} when C =:= $[ ->
            split_top(Rest, Sep, Depth + 1, Quote, Acc, <<Buf/binary, C>>);
        {_, _} when C =:= $] ->
            split_top(Rest, Sep, Depth - 1, Quote, Acc, <<Buf/binary, C>>);
        {_, _} when C =:= $( ->
            split_top(Rest, Sep, Depth + 1, Quote, Acc, <<Buf/binary, C>>);
        {_, _} when C =:= $) ->
            split_top(Rest, Sep, Depth - 1, Quote, Acc, <<Buf/binary, C>>);
        {0, 0} ->
            Remaining = <<C, Rest/binary>>,
            case binary:longest_common_prefix([Remaining, Sep]) of
                L when L >= SepSize ->
                    <<_:SepSize/binary, AfterSep/binary>> = Remaining,
                    case trim(Buf) of
                        <<>> -> split_top(AfterSep, Sep, 0, 0, Acc, <<>>);
                        BufTrim -> split_top(AfterSep, Sep, 0, 0, [BufTrim | Acc], <<>>)
                    end;
                _ ->
                    split_top(Rest, Sep, Depth, Quote, Acc, <<Buf/binary, C>>)
            end;
        _ ->
            split_top(Rest, Sep, Depth, Quote, Acc, <<Buf/binary, C>>)
    end.
