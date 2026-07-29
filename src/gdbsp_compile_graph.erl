%%%-------------------------------------------------------------------
%%% @doc Circuit graph construction from parsed GDBSP program.
%%%
%%% Transforms #gdbsp_program{} into #circuit_graph{}.
%%% Handles name resolution, topological sort, operator mapping,
%%% and schema computation.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_graph).

-export([build/4]).

-include("gdbsp_parse.hrl").
-include("gdbsp_circuit.hrl").
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
        case Info#node_info.op of
            delay -> 0;
            _ -> length(node_refs_from_args(Info#node_info.args, NameTable))
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
    {Graph0, IdMap} = lists:foldl(fun(Name, {G, IdMapAcc}) ->
        Info = maps:get(Name, NameTable),
        {G2, NodeId} = build_node(G, Info, IdMapAcc, NameTable, FnReg, CircuitDefs),
        {G2, IdMapAcc#{Name => NodeId}}
    end, {new_graph(), #{}}, Order),
    {Graph0, IdMap}.

new_graph() ->
    #circuit_graph{next_id = 1, nodes = #{}, schemas = #{}}.

build_node(G, Info, IdMap, NameTable, FnReg, CircuitDefs) ->
    #node_info{name = Name, op = Op, args = Args, typespec = TS} = Info,
    InputIds = resolve_input_ids(Args, IdMap, NameTable),
    case Op of
        fixpoint ->
            build_fixpoint_graph(G, Name, Args, InputIds, TS, NameTable, FnReg, CircuitDefs);
        join ->
            build_join_graph(G, Args, InputIds, TS, NameTable, FnReg);
        aggregate ->
            build_aggregate_graph(G, Args, InputIds, NameTable, FnReg);
        _ ->
            {OpTuple, SubNodes} = make_operator(G, Name, Op, Args, InputIds, TS, NameTable, IdMap, FnReg),
            {G2, FinalId} = add_with_sub_nodes(G, OpTuple, InputIds, SubNodes),
            Schema = compute_schema(Op, Args, InputIds, TS, NameTable, G2),
            G3 = set_schema(G2, FinalId, Schema),
            {G3, FinalId}
    end.

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
    {G5, JoinId}.

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
    {G4, UnwrapId}.
%%====================================================================
%% Fixpoint graph construction — Rec/Coord subgraph
%%====================================================================

build_fixpoint_graph(G, FpName, Args, _InputIds, _TS, _NameTable, _FnReg, CircuitDefs) ->
    [CircuitNameArg | _KwArgs] = Args,
    CircuitName = case CircuitNameArg of
        {var, N} -> N;
        _ -> throw({compile_error, {fixpoint, bad_circuit_name}})
    end,
    DefMap = maps:from_list(
        [{D#gdbsp_circuit_def.name, D} || D <- CircuitDefs]),
    {ok, Def} = maps:find(CircuitName, DefMap),
    #gdbsp_circuit_def{params = Params, body = BodyNodes} = Def,
    BodyNodeNames = [N || #gdbsp_node_def{name = N} <- BodyNodes],

    Prefix = <<FpName/binary, "_">>,
    SccId = G#circuit_graph.next_id,
    SelfRefKws = [Kw || Kw <- maps:keys(Params),
                        lists:member(atom_to_binary(Kw, utf8), BodyNodeNames)],

    NextId0 = G#circuit_graph.next_id + 1000,
    {G1, RecIds, _NextId1} =
        lists:foldl(
            fun(Kw, {GA, RIds, NxId}) ->
                KwBin = atom_to_binary(Kw, utf8),
                RecName = <<Prefix/binary, KwBin/binary>>,
                RecId = NxId,
                RecNode = #circuit_node{
                    id = RecId,
                    op = {rec, RecName, SccId},
                    inputs = [],
                    meta = #{sourced => true, scc_body => true}},
                GA2 = GA#circuit_graph{
                    next_id = NxId + 1,
                    nodes = maps:put(RecId, RecNode, GA#circuit_graph.nodes)},
                {GA2, RIds#{Kw => RecId}, NxId + 1}
            end,
            {G, #{}, NextId0},
            SelfRefKws
        ),

    FinalId = case maps:size(RecIds) of
        0 -> G#circuit_graph.next_id;
        _ -> hd(lists:reverse(maps:values(RecIds)))
    end,

    Schema = [],
    G2 = set_schema(G1, FinalId, Schema),
    {G2, FinalId}.


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
