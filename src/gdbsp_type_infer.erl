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

-export([infer_lowered/5]).

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

%%====================================================================
%% Aggregate return type
%%====================================================================

infer_agg_return_type(FnRef, _ValType, _FnReg, StdlibMap) ->
    case maps:find(FnRef, StdlibMap) of
        {ok, [#gdbsp_typespec{spec = {aggregate_function, _Pos, _Kw, Ret}} | _]} ->
            Ret;
        _ ->
            error(#{<<"class">> => <<"missing_typespec">>,
                    <<"node">> => FnRef,
                    <<"message">> => <<"aggregate function not found in stdlib">>})
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
                    fn_registry(), fn_params(), gdbsp_builtins:stdlib_map()) ->
    {ok, #lowered_graph{}} | {error, term()}.
infer_lowered(#lowered_graph{nodes = Nodes} = LG, TSMap, FnReg, FnParams, StdlibMap) ->
    try
        NodeList = maps:to_list(Nodes),
        Sorted = lowered_topo_sort(NodeList),
        {NewNodes, _TypeAcc} = lists:foldl(
            fun(LId, {AccNodes, TypeAcc}) ->
                #lnode{op = Op, inputs = InputIds, args = Args, tags = Tags,
                       type = ExistingType} = maps:get(LId, AccNodes),
                Type = case is_concrete_type(ExistingType) of
                    true -> ExistingType;
                    false ->
                        infer_lnode_type(Op, Args, InputIds, Tags, TypeAcc,
                                          TSMap, FnReg, FnParams, StdlibMap)
                end,
                Node = (maps:get(LId, AccNodes))#lnode{type = Type},
                {maps:put(LId, Node, AccNodes), TypeAcc#{LId => Type}}
            end,
            {Nodes, #{}},
            Sorted),
        {ok, LG#lowered_graph{nodes = NewNodes}}
    catch
        error:Reason when is_map(Reason) ->
            {error, Reason}
    end.

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

infer_lnode_type(source, _Args, _InputIds, Tags, _TypeAcc, TSMap, _FnReg, _FnParams, _StdlibMap) ->
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

infer_lnode_type(fixpoint_input, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _FnParams, _StdlibMap) ->
    lowered_input_type(InputIds, TypeAcc);

infer_lnode_type(fixpoint_output, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _FnParams, _StdlibMap) ->
    lowered_input_type(InputIds, TypeAcc);

infer_lnode_type(plus, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _FnParams, _StdlibMap) ->
    Types = [maps:get(Id, TypeAcc, dynamic) || Id <- InputIds],
    case Types of
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
        [] -> dynamic
    end;

infer_lnode_type(join, Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _FnParams, _StdlibMap) ->
    LType = lowered_nth_input_type(1, InputIds, TypeAcc),
    RType = lowered_nth_input_type(2, InputIds, TypeAcc),
    {on, OnFields} = get_kw_arg(Args, on, []),
    check_join_key_types(OnFields, LType, RType),
    merge_join_type(LType, RType, OnFields);

infer_lnode_type(aggregate, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg, _FnParams, StdlibMap) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    FnRef = get_var_arg(Args, 2),
    {by, ByFields} = get_kw_arg(Args, by, []),
    {value, ValField} = get_kw_arg(Args, value, <<>>),
    {as, AsField} = get_kw_arg(Args, 'as', <<>>),
    ValType = field_type(ValField, InputType),
    AggRetType = infer_agg_return_type(FnRef, ValType, FnReg, StdlibMap),
    ByPairs = [{F, field_type(F, InputType)} || F <- ByFields],
    AllFields = ByPairs ++ [{AsField, AggRetType}],
    {struct, maps:from_list(AllFields), exact};

infer_lnode_type(map, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg, FnParams, StdlibMap) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    {var, FnName} = lists:nth(2, Args),
    infer_row_fn_output_type(FnName, InputType, FnReg, FnParams, StdlibMap);

infer_lnode_type(filter, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg, FnParams, StdlibMap) ->
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

infer_lnode_type(flat_map, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg, FnParams, StdlibMap) ->
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

infer_lnode_type(project, Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _FnParams, _StdlibMap) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    KeepFields = get_string_list_arg(Args, 2),
    project_struct(InputType, KeepFields);

infer_lnode_type(_Op, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg, _FnParams, _StdlibMap) ->
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
    case maps:find(FnName, FnReg) of
        {ok, FnJson} ->
            infer_fn_body_output_type(FnName, FnJson, FnParams, InputType, StdlibMap);
        error ->
            case gdbsp_builtins:resolve_call(FnName, [InputType], [], StdlibMap) of
                {ok, RetType, _Concrete} -> RetType;
                {error, _} ->
                    error(#{<<"class">> => <<"missing_typespec">>,
                            <<"node">> => FnName,
                            <<"message">> => <<"function not found">>})
            end
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
