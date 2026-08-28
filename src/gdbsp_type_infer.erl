%%%-------------------------------------------------------------------
%%% @doc Type inference for GDBSP programs.
%%%
%%% Computes the output type of every node in a parsed program,
%%% propagating types from explicitly-typed source nodes through
%%% operators (filter, map, join, aggregate, etc.).
%%%
%%% Expression-level typing is delegated to gdbsp_type_infer_expr, the
%%% single shared engine operating on `expr()` / gdbsp_column_type().
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_type_infer).

-include("gdbsp_parse.hrl").
-include("gdbsp_type.hrl").
-include("gdbsp_lowered.hrl").

-import(gdbsp_string_util, [parse_string_list/1]).

-export([infer_lowered/6]).

-type fn_registry() :: #{binary() => map()}.
-type fn_params() :: #{binary() => #{pos := [binary()], kw := [{binary(), binary()}]}}.

%%====================================================================
%% Project
%%====================================================================

project_struct({struct, Fields, _Rest}, KeepFields) when is_list(KeepFields) ->
    NewFields = maps:with(KeepFields, Fields),
    {struct, NewFields, exact};
project_struct(_NonStruct, _KeepFields) ->
    error(#{<<"class">> => <<"type_conflict">>,
            <<"message">> => <<"project on non-struct">>}).

%%====================================================================
%% Join
%%====================================================================

merge_join_type(LType, RType, OnFields) ->
    LFields = struct_fields(LType),
    RFields = struct_fields(RType),
    Shared = maps:with(OnFields, LFields),
    LOnly = maps:without(OnFields, LFields),
    ROnly = maps:without(OnFields, RFields),
    Merged = maps:merge(maps:merge(Shared, LOnly), ROnly),
    {struct, Merged, exact}.

struct_fields({struct, Fields, _}) -> Fields;
struct_fields(_) -> #{}.

is_type_var({type_var, _}) -> true;
is_type_var(_) -> false.

%%====================================================================
%% Aggregate helpers
%%====================================================================

aggregate_result_fields(FnRef, Plan) ->
    case maps:get(result_type, Plan, undefined) of
        {struct, Fields, _} -> Fields;
        _ ->
            error(#{<<"class">> => <<"type_conflict">>,
                    <<"message">> => <<"aggregate function must return a struct">>,
                    <<"node">> => FnRef})
    end.

check_by_result_clash(ByFields, ResultFields, _FnRef) ->
    lists:foreach(
        fun(F) ->
            case maps:is_key(F, ResultFields) of
                true ->
                    error(#{<<"class">> => <<"type_conflict">>,
                            <<"message">> => <<"by-field clashes with aggregate result field">>,
                            <<"field">> => F});
                false -> ok
            end
        end, ByFields).

%%====================================================================
%% Order helpers
%%====================================================================

validate_order_keys([], _InputFields) ->
    error(#{<<"class">> => <<"type_conflict">>,
            <<"message">> => <<"order requires a non-empty by list">>});
validate_order_keys(By, InputFields) ->
    lists:foreach(
        fun
            ([Field, Dir]) when is_binary(Field), is_binary(Dir) ->
                case maps:is_key(Field, InputFields) of
                    false ->
                        error(#{<<"class">> => <<"missing_field">>,
                                <<"field">> => Field});
                    true ->
                        case lists:member(Dir, [<<"asc">>, <<"desc">>]) of
                            true -> ok;
                            false ->
                                error(#{<<"class">> => <<"type_conflict">>,
                                        <<"message">> => <<"order direction must be asc or desc">>,
                                        <<"field">> => Field,
                                        <<"direction">> => Dir})
                        end
                end;
            (Other) ->
                error(#{<<"class">> => <<"type_conflict">>,
                        <<"message">> => <<"order by entry must be [field, direction]">>,
                        <<"entry">> => Other})
        end, By).

validate_order_columns(RankCol, RowNumCol, InputFields) ->
    validate_order_column(rank_column, RankCol, InputFields),
    validate_order_column(row_number_column, RowNumCol, InputFields),
    case RankCol =:= RowNumCol of
        true ->
            error(#{<<"class">> => <<"type_conflict">>,
                    <<"message">> => <<"rank_column and row_number_column must differ">>});
        false -> ok
    end.

validate_order_column(_Kind, undefined, _InputFields) ->
    error(#{<<"class">> => <<"type_conflict">>,
            <<"message">> => <<"order requires an explicit column name">>});
validate_order_column(_Kind, Col, _InputFields) when not is_binary(Col) ->
    error(#{<<"class">> => <<"type_conflict">>,
            <<"message">> => <<"order column name must be a string">>});
validate_order_column(Kind, Col, InputFields) ->
    case maps:is_key(Col, InputFields) of
        true ->
            error(#{<<"class">> => <<"type_conflict">>,
                    <<"message">> => <<"order column clashes with input field">>,
                    <<"column">> => Kind,
                    <<"field">> => Col});
        false -> ok
    end.

%%====================================================================
%% Field helpers
%%====================================================================

field_type(FieldName, {struct, Fields, _Rest}) ->
    case maps:find(FieldName, Fields) of
        {ok, T} -> T;
        error ->
            error(#{<<"class">> => <<"missing_field">>,
                    <<"field">> => FieldName})
    end;
field_type(_FieldName, dynamic) ->
    dynamic;
field_type(_FieldName, {dynamic, _}) ->
    dynamic;
field_type(FieldName, _NonStruct) ->
    error(#{<<"class">> => <<"type_conflict">>,
            <<"message">> => <<"field access on non-struct">>,
            <<"field">> => FieldName}).

%%====================================================================
%% Arg helpers
%%====================================================================

get_kw_arg(Args, Key, Default) ->
    case lists:keyfind(Key, 1, Args) of
        {Key, Val} -> {Key, Val};
        false -> {Key, Default}
    end.

get_var_arg(Args, Pos) ->
    case lists:nth(Pos, Args) of
        {var, N} when is_binary(N) -> N;
        _ -> error({bad_arg, Pos, var})
    end.

get_string_list_arg(Args, Pos) ->
    case lists:nth(Pos, Args) of
        {var, Bin} when is_binary(Bin) ->
            case binary:match(Bin, <<"[">>) of
                nomatch -> [Bin];
                _ -> parse_string_list(Bin)
            end;
        [H | _] = L when is_binary(H) -> L;
        _ -> error({bad_arg, Pos, string_list})
    end.

%%====================================================================
%% Lowered graph type inference
%%====================================================================

-spec infer_lowered(#lowered_graph{}, #{binary() => gdbsp_column_type()},
                    fn_registry(), fn_registry(), fn_params(),
                    gdbsp_builtins:stdlib_map()) ->
    {ok, #lowered_graph{}} | {error, term()}.
infer_lowered(#lowered_graph{fixpoints = FPs} = LG, TSMap, FnReg, AggReg, FnParams, StdlibMap) ->
    try
        case self_ref_pairs(FPs) of
            [] ->
                infer_pass(LG, TSMap, FnReg, AggReg, FnParams, StdlibMap, #{});
            SelfRefs ->
                infer_selfrefs(LG, TSMap, FnReg, AggReg, FnParams, StdlibMap, SelfRefs)
        end
    catch
        error:Reason when is_map(Reason) ->
            {error, Reason}
    end.

%% A self-referential fixpoint param's type is the body output type, not its
%% (possibly empty) base argument. Resolve it by iterating inference to a
%% fixed point: seed each self-ref fixpoint_input with the body output type
%% from the previous pass until it stabilises.
self_ref_pairs(FPs) ->
    lists:append(
        [ [{maps:get(input, P), maps:get(body_out, P)}
           || {_Kw, P} <- maps:to_list(maps:get(params, Info)),
              maps:get(kind, P) =:= self_ref]
          || {_H, Info} <- maps:to_list(FPs) ]).

infer_selfrefs(LG, TSMap, FnReg, AggReg, FnParams, StdlibMap, SelfRefs) ->
    iterate_selfrefs(LG, TSMap, FnReg, AggReg, FnParams, StdlibMap, SelfRefs,
                     #{}, length(SelfRefs) + 1).

iterate_selfrefs(LG, TSMap, FnReg, AggReg, FnParams, StdlibMap, _SelfRefs, Seed, 0) ->
    infer_pass(LG, TSMap, FnReg, AggReg, FnParams, StdlibMap, Seed);
iterate_selfrefs(LG, TSMap, FnReg, AggReg, FnParams, StdlibMap, SelfRefs, Seed, Iter) ->
    {ok, NewLG} = infer_pass(LG, TSMap, FnReg, AggReg, FnParams, StdlibMap, Seed),
    NewSeed = self_ref_types(NewLG, SelfRefs),
    case NewSeed =:= Seed of
        true ->
            {ok, NewLG};
        false ->
            iterate_selfrefs(LG, TSMap, FnReg, AggReg, FnParams, StdlibMap,
                             SelfRefs, NewSeed, Iter - 1)
    end.

self_ref_types(#lowered_graph{nodes = Nodes}, SelfRefs) ->
    maps:from_list(
        [{InputId, node_type(Nodes, BodyOutId)} || {InputId, BodyOutId} <- SelfRefs]).

node_type(Nodes, Id) ->
    case maps:find(Id, Nodes) of
        {ok, #lnode{type = T}} -> T;
        error -> undefined
    end.

infer_pass(#lowered_graph{nodes = Nodes} = LG, TSMap, FnReg, AggReg, FnParams, StdlibMap, Seed) ->
    SeededNodes = maps:fold(
        fun(Id, Type, Acc) ->
            case maps:find(Id, Acc) of
                {ok, #lnode{} = N} -> maps:put(Id, N#lnode{type = Type}, Acc);
                error -> Acc
            end
        end,
        Nodes,
        Seed),
    NodeList = maps:to_list(SeededNodes),
    Sorted = lowered_topo_sort(NodeList),
    {NewNodes, _TypeAcc} = lists:foldl(
        fun(LId, {AccNodes, TypeAcc}) ->
            #lnode{op = Op, inputs = InputIds, args = Args, tags = Tags,
                   type = ExistingType} = maps:get(LId, AccNodes),
            Type = case is_concrete_type(ExistingType) of
                true -> ExistingType;
                false ->
                    infer_lnode_type(Op, Args, InputIds, Tags, TypeAcc,
                                      TSMap, FnReg, AggReg, FnParams, StdlibMap)
            end,
            Node = (maps:get(LId, AccNodes))#lnode{type = Type},
            {maps:put(LId, Node, AccNodes), TypeAcc#{LId => Type}}
        end,
        {SeededNodes, #{}},
        Sorted),
    {ok, LG#lowered_graph{nodes = NewNodes}}.

lowered_topo_sort(NodeList) ->
    NodeMap = maps:from_list(NodeList),
    InDeg = maps:map(fun(_LId, #lnode{inputs = Ins}) ->
        length(Ins)
    end, NodeMap),
    Consumers = lists:foldl(
        fun({LId, #lnode{inputs = Ins}}, Acc) ->
            lists:foldl(fun(InId, A) ->
                maps:update_with(InId, fun(L) -> [LId | L] end, [LId], A)
            end, Acc, Ins)
        end, #{}, NodeList),
    AllIds = [Id || {Id, _} <- NodeList],
    Queue = [Id || Id <- AllIds, maps:get(Id, InDeg, 0) =:= 0],
    lowered_topo_loop(queue:from_list(Queue), InDeg, Consumers, []).

lowered_topo_loop(Q, InDeg, Consumers, Acc) ->
    case queue:out(Q) of
        {empty, _} -> lists:reverse(Acc);
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
            lowered_topo_loop(NewQ, NewIndeg, Consumers, NewAcc)
    end.

is_concrete_type(undefined) -> false;
is_concrete_type(_) -> true.

infer_lnode_type(source, _Args, _InputIds, Tags, _TypeAcc, TSMap, _FnReg, _AggReg, _FnParams, _StdlibMap) ->
    Name = case Tags of [Tag | _] -> Tag; _ -> undefined end,
    case Name of
        undefined ->
            error(#{<<"class">> => <<"missing_typespec">>,
                    <<"node">> => <<"<unnamed_source>">>});
        _ ->
            case maps:find(Name, TSMap) of
                {ok, T} -> T;
                error ->
                    error(#{<<"class">> => <<"missing_typespec">>,
                            <<"node">> => Name})
            end
    end;

infer_lnode_type(fixpoint_input, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _AggReg, _FnParams, _StdlibMap) ->
    lowered_input_type(InputIds, TypeAcc);

infer_lnode_type(fixpoint_output, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _AggReg, _FnParams, _StdlibMap) ->
    lowered_input_type(InputIds, TypeAcc);

infer_lnode_type(empty, _Args, _InputIds, _Tags, _TypeAcc, _TSMap, _FnReg, _AggReg, _FnParams, _StdlibMap) ->
    {type_var, <<"Empty">>};

infer_lnode_type(plus, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _AggReg, _FnParams, _StdlibMap) ->
    Types = [maps:get(Id, TypeAcc, dynamic) || Id <- InputIds],
    Concrete = [T || T <- Types, not is_type_var(T)],
    case Concrete of
        [First | Rest] ->
            FirstText = gdbsp_type:canonical_text(First),
            case lists:all(
                fun(T) -> gdbsp_type:canonical_text(T) =:= FirstText end,
                Rest) of
                true -> First;
                false ->
                    error(#{<<"class">> => <<"type_conflict">>,
                            <<"message">> => <<"plus input type mismatch">>})
            end;
        [] ->
            case Types of
                [{type_var, _} = V | _] -> V;
                _ -> dynamic
            end
    end;

infer_lnode_type(join, Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _AggReg, _FnParams, _StdlibMap) ->
    LType = lowered_nth_input_type(1, InputIds, TypeAcc),
    RType = lowered_nth_input_type(2, InputIds, TypeAcc),
    {on, OnFields} = get_kw_arg(Args, on, []),
    check_join_key_types(OnFields, LType, RType),
    merge_join_type(LType, RType, OnFields);

infer_lnode_type(aggregate, Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, AggReg, _FnParams, _StdlibMap) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    FnRef = get_var_arg(Args, 2),
    {by, ByFields} = get_kw_arg(Args, by, []),
    case maps:find(FnRef, AggReg) of
        error ->
            error(#{<<"class">> => <<"missing_typespec">>,
                    <<"node">> => FnRef});
        {ok, Plan} ->
            ResultFields = aggregate_result_fields(FnRef, Plan),
            check_by_result_clash(ByFields, ResultFields, FnRef),
            ByPairs = [{F, field_type(F, InputType)} || F <- ByFields],
            {struct, maps:from_list(ByPairs ++ maps:to_list(ResultFields)), exact}
    end;

infer_lnode_type(order, Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _AggReg, _FnParams, _StdlibMap) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    {by, By} = get_kw_arg(Args, by, []),
    {rank_column, RankCol} = get_kw_arg(Args, rank_column, undefined),
    {row_number_column, RowNumCol} = get_kw_arg(Args, row_number_column, undefined),
    InputFields = struct_fields(InputType),
    ok = validate_order_keys(By, InputFields),
    ok = validate_order_columns(RankCol, RowNumCol, InputFields),
    {struct, (InputFields)#{RankCol => integer, RowNumCol => integer}, exact};

infer_lnode_type(map, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg, _AggReg, FnParams, StdlibMap) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    {var, FnName} = lists:nth(2, Args),
    infer_row_fn_output_type(FnName, InputType, FnReg, FnParams, StdlibMap);

infer_lnode_type(filter, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg, _AggReg, FnParams, StdlibMap) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    {var, FnName} = lists:nth(2, Args),
    RetType = infer_row_fn_output_type(FnName, InputType, FnReg, FnParams, StdlibMap),
    case is_boolean_subset(RetType) of
        true -> InputType;
        false ->
            error(#{<<"class">> => <<"non_boolean_filter">>,
                    <<"message">> => <<"filter function must return boolean">>,
                    <<"node">> => FnName,
                    <<"return_type">> => gdbsp_type:canonical_text(RetType)})
    end;

infer_lnode_type(flat_map, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg, _AggReg, FnParams, StdlibMap) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    {var, BaseFnName} = lists:nth(2, Args),
    case infer_row_fn_output_type(BaseFnName, InputType, FnReg, FnParams, StdlibMap) of
        {array, ElemType, _} -> ElemType;
        dynamic -> dynamic;
        {dynamic, _} -> dynamic;
        Other ->
            error(#{<<"class">> => <<"type_conflict">>,
                    <<"message">> => <<"flat_map function must return an array">>,
                    <<"node">> => BaseFnName,
                    <<"return_type">> => gdbsp_type:canonical_text(Other)})
    end;

infer_lnode_type(project, Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _AggReg, _FnParams, _StdlibMap) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    KeepFields = get_string_list_arg(Args, 2),
    project_struct(InputType, KeepFields);

infer_lnode_type(_Op, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _AggReg, _FnParams, _StdlibMap) ->
    lowered_input_type(InputIds, TypeAcc).

%%--------------------------------------------------------------------
%% Function body output type (decode registry JSON → shared engine)
%%--------------------------------------------------------------------

infer_fn_body_output_type(FnName, FnJson, FnParams, InputType, StdlibMap) ->
    ArgEnv = fn_arg_env(FnName, FnParams, InputType),
    case gdbsp_expr:json_to_expr(FnJson) of
        {ok, Expr} ->
            case gdbsp_type_infer_expr:infer_expr(Expr, ArgEnv, StdlibMap) of
                {ok, T} -> T;
                {error, [First | _]} -> throw_expr_error(First)
            end;
        {error, Reason} ->
            error(#{<<"class">> => <<"invalid_fn_expr">>,
                    <<"node">> => FnName,
                    <<"reason">> => Reason})
    end.

infer_row_fn_output_type(FnName, InputType, FnReg, FnParams, StdlibMap) ->
    case is_type_var(InputType) of
        true ->
            %% Unresolved self-ref input: fall back to the declared signature,
            %% which unifies the type_var against the declared param type.
            infer_declared_fn_output_type(FnName, InputType, StdlibMap);
        false ->
            case maps:find(FnName, FnReg) of
                {ok, FnJson} ->
                    infer_fn_body_output_type(FnName, FnJson, FnParams, InputType, StdlibMap);
                error ->
                    infer_declared_fn_output_type(FnName, InputType, StdlibMap)
            end
    end.

infer_declared_fn_output_type(FnName, InputType, StdlibMap) ->
    case gdbsp_builtins:resolve_call(FnName, [InputType], [], StdlibMap) of
        {ok, RetType, _Concrete} -> RetType;
        {error, _} ->
            error(#{<<"class">> => <<"missing_typespec">>,
                    <<"node">> => FnName,
                    <<"message">> => <<"function not found">>})
    end.

fn_arg_env(FnName, FnParams, InputType) ->
    ArgName = case maps:find(FnName, FnParams) of
        {ok, #{pos := [A | _]}} -> A;
        _ -> <<"row">>
    end,
    #{ArgName => InputType}.

throw_expr_error(Err) ->
    error(#{<<"class">> => expr_error_class(Err), <<"reason">> => Err}).

expr_error_class({fn_lookup_error, _, _}) -> <<"fn_lookup_error">>;
expr_error_class({non_literal_key, _}) -> <<"non_literal_key">>;
expr_error_class({missing_field, _}) -> <<"missing_field">>;
expr_error_class({type_conflict, _, _, _}) -> <<"type_conflict">>;
expr_error_class({non_struct_target, _}) -> <<"type_conflict">>;
expr_error_class({get_on_non_container, _}) -> <<"type_conflict">>;
expr_error_class({slice_on_non_sequence, _}) -> <<"type_conflict">>;
expr_error_class({map_key_type_mismatch, _, _}) -> <<"type_conflict">>;
expr_error_class({array_index_not_integer, _}) -> <<"type_conflict">>;
expr_error_class({unbound_var, _}) -> <<"unbound_var">>;
expr_error_class({map_merge_non_map}) -> <<"type_conflict">>;
expr_error_class({aggregates_not_allowed_in_fn_body}) -> <<"type_conflict">>;
expr_error_class(_) -> <<"expr_error">>.

is_boolean_subset({enum, S}) ->
    lists:all(fun(M) -> M =:= <<"false">> orelse M =:= <<"true">> end, S);
is_boolean_subset(_) -> false.

%%--------------------------------------------------------------------
%% Join key type conflict check
%%--------------------------------------------------------------------

check_join_key_types(OnFields, LType, RType) ->
    case is_type_var(LType) orelse is_type_var(RType) of
        true -> ok;
        false -> check_join_key_types_strict(OnFields, LType, RType)
    end.

check_join_key_types_strict(OnFields, LType, RType) ->
    LFields = struct_fields(LType),
    RFields = struct_fields(RType),
    lists:foreach(
        fun(Key) ->
            LT = maps:get(Key, LFields, dynamic),
            RT = maps:get(Key, RFields, dynamic),
            case gdbsp_type:canonical_text(LT) =:= gdbsp_type:canonical_text(RT) of
                true -> ok;
                false ->
                    error(#{<<"class">> => <<"type_conflict">>,
                            <<"message">> => <<"join key type mismatch">>,
                            <<"key">> => Key,
                            <<"left_type">> => gdbsp_type:canonical_text(LT),
                            <<"right_type">> => gdbsp_type:canonical_text(RT)})
            end
        end,
        OnFields).

lowered_input_type([InId | _], TypeAcc) ->
    maps:get(InId, TypeAcc, dynamic);
lowered_input_type(_, _TypeAcc) ->
    dynamic.

lowered_nth_input_type(N, InputIds, TypeAcc) ->
    case catch lists:nth(N, InputIds) of
        InId when is_binary(InId) -> maps:get(InId, TypeAcc, dynamic);
        _ -> dynamic
    end.
