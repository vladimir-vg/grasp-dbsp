%%%-------------------------------------------------------------------
%%% @doc Type inference for GDBSP programs.
%%%
%%% Computes the output type of every node in a parsed program,
%%% propagating types from explicitly-typed source nodes through
%%% operators (filter, map, join, aggregate, etc.).
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_type_infer).

-include("gdbsp_parse.hrl").
-include("gdbsp_type.hrl").
-include("gdbsp_lowered.hrl").

-export([infer_lowered/3]).

-type fn_registry() :: #{binary() => map()}.

%%====================================================================
%% Project
%%====================================================================

project_struct({struct, Fields, _Rest}, KeepFields) when is_list(KeepFields) ->
    NewFields = maps:with(KeepFields, Fields),
    {struct, NewFields, exact};
project_struct(_NonStruct, _KeepFields) ->
    dynamic.

%%====================================================================
%% Map — analyse function expression tree to determine output type
%%====================================================================

infer_map_output_type(#{<<"call">> := <<"struct">>,
                        <<"kwargs">> := KwArgs}, InputType)
  when is_map(KwArgs) ->
    Fields = maps:map(
        fun(_FieldName, ExprJson) ->
            infer_expr_output_type(ExprJson, InputType)
        end, KwArgs),
    {struct, Fields, exact};

infer_map_output_type(#{<<"type">> := TypeJson, <<"value">> := _ValJson},
                      _InputType) ->
    case gdbsp_type:parse_type(TypeJson) of
        {ok, T} -> T;
        {error, _} -> dynamic
    end;

infer_map_output_type(#{<<"arg">> := _ArgName}, InputType) ->
    InputType;

infer_map_output_type(#{<<"call">> := CallName} = CallJson, InputType) ->
    infer_call_output_type(bin(CallName), CallJson, InputType);

infer_map_output_type(_Other, InputType) ->
    InputType.

%%====================================================================
%% Expression output type (for sub-expressions inside map functions)
%%====================================================================

infer_expr_output_type(#{<<"type">> := TypeJson}, _InputType) ->
    case gdbsp_type:parse_type(TypeJson) of
        {ok, T} -> T;
        {error, _} -> dynamic
    end;

infer_expr_output_type(#{<<"arg">> := _ArgName}, InputType) ->
    InputType;

infer_expr_output_type(#{<<"call">> := CallName} = CallJson, InputType) ->
    infer_call_output_type(bin(CallName), CallJson, InputType);

infer_expr_output_type(#{<<"aggregate">> := _AggName}, _InputType) ->
    dynamic;

infer_expr_output_type(_Other, _InputType) ->
    dynamic.

%%====================================================================
%% Function call return type lookup
%%====================================================================

infer_call_output_type(<<"struct:get">>, CallJson, InputType) ->
    infer_struct_get_type(CallJson, InputType);

infer_call_output_type(<<"struct:set">>, CallJson, InputType) ->
    infer_struct_set_type(CallJson, InputType);

infer_call_output_type(<<"struct">>, #{<<"kwargs">> := KwArgs}, InputType)
  when is_map(KwArgs) ->
    Fields = maps:map(
        fun(_FieldName, ExprJson) ->
            infer_expr_output_type(ExprJson, InputType)
        end, KwArgs),
    {struct, Fields, exact};

infer_call_output_type(CallName, CallJson, InputType) ->
    PosArgs = maps:get(<<"args">>, CallJson, []),
    KwArgs = maps:get(<<"kwargs">>, CallJson, #{}),
    PosTypes = [infer_expr_output_type(A, InputType) || A <- PosArgs],
    KwPairs = [{K, infer_expr_output_type(V, InputType)} || {K, V} <- maps:to_list(KwArgs)],
    case gdbsp_builtins:lookup_fn(CallName, PosTypes, KwPairs) of
        {ok, RetType, _Impl} -> RetType;
        {error, _} -> call_return_type(CallName)
    end.

call_return_type(<<"integer:add">>) -> i64;
call_return_type(<<"integer:sub">>) -> i64;
call_return_type(<<"integer:mul">>) -> i64;
call_return_type(<<"integer:div">>) -> i64;
call_return_type(<<"integer:mod">>) -> i64;
call_return_type(<<"i64:add">>) -> i64;
call_return_type(<<"i64:sub">>) -> i64;
call_return_type(<<"i64:mul">>) -> i64;
call_return_type(<<"u64:add">>) -> u64;
call_return_type(<<"f64:add">>) -> f64;
call_return_type(<<"f64:sub">>) -> f64;
call_return_type(<<"f64:mul">>) -> f64;
call_return_type(<<"f64:div">>) -> f64;
call_return_type(<<"integer:gt">>) -> ?BOOL;
call_return_type(<<"integer:lt">>) -> ?BOOL;
call_return_type(<<"integer:gte">>) -> ?BOOL;
call_return_type(<<"integer:lte">>) -> ?BOOL;
call_return_type(<<"integer:eq">>) -> ?BOOL;
call_return_type(<<"integer:neq">>) -> ?BOOL;
call_return_type(<<"gte">>) -> ?BOOL;
call_return_type(<<"lte">>) -> ?BOOL;
call_return_type(<<"gt">>) -> ?BOOL;
call_return_type(<<"lt">>) -> ?BOOL;
call_return_type(<<"eq">>) -> ?BOOL;
call_return_type(<<"neq">>) -> ?BOOL;
call_return_type(<<"boolean:and">>) -> ?BOOL;
call_return_type(<<"boolean:or">>) -> ?BOOL;
call_return_type(<<"boolean:not">>) -> ?BOOL;
call_return_type(<<"string:upper">>) -> string;
call_return_type(<<"string:lower">>) -> string;
call_return_type(<<"string:concat">>) -> string;
call_return_type(<<"string:substring">>) -> string;
call_return_type(<<"string:len">>) -> i64;
call_return_type(<<"string:starts_with">>) -> ?BOOL;
call_return_type(<<"string:ends_with">>) -> ?BOOL;
call_return_type(<<"string:contains">>) -> ?BOOL;
call_return_type(_) -> dynamic.

%%====================================================================
%% struct:get / struct:set output type resolution
%%====================================================================

infer_struct_get_type(#{<<"args">> := [StructExpr | _],
                         <<"kwargs">> := #{<<"key">> := KeyExpr}}, InputType) ->
    StructType = infer_expr_output_type(StructExpr, InputType),
    case extract_string_literal(KeyExpr) of
        {ok, KeyStr} -> field_type(KeyStr, StructType);
        false -> dynamic
    end;
infer_struct_get_type(_CallJson, _InputType) ->
    dynamic.

infer_struct_set_type(#{<<"args">> := [StructExpr, ValExpr | _],
                         <<"kwargs">> := #{<<"key">> := KeyExpr}}, InputType) ->
    StructType = infer_expr_output_type(StructExpr, InputType),
    ValType = infer_expr_output_type(ValExpr, InputType),
    case extract_string_literal(KeyExpr) of
        {ok, KeyStr} ->
            case StructType of
                {struct, Fields, Mode} ->
                    {struct, Fields#{KeyStr => ValType}, Mode};
                _ -> dynamic
            end;
        false -> dynamic
    end;
infer_struct_set_type(_CallJson, _InputType) ->
    dynamic.

extract_string_literal(#{<<"type">> := <<"string">>, <<"value">> := Val}) when is_binary(Val) ->
    {ok, Val};
extract_string_literal(#{<<"type">> := <<"string">>, <<"value">> := Val}) when is_list(Val) ->
    {ok, list_to_binary(Val)};
extract_string_literal(_) -> false.

%%====================================================================
%% Flat map
%%====================================================================

infer_flat_map_out_type(_BaseFnName, InputType) ->
    case InputType of
        {struct, _Fields, _} -> InputType;
        _ -> InputType
    end.

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

infer_agg_return_type(FnRef, ValType, FnReg) ->
    AggName = case maps:find(FnRef, FnReg) of
        {ok, #{<<"aggregate">> := Name}} when is_binary(Name) -> Name;
        _ -> FnRef
    end,
    infer_agg_return_type_1(AggName, ValType).

infer_agg_return_type_1(<<"agg:sum">>, ValType) -> agg_sum_type(ValType);
infer_agg_return_type_1(<<"agg:count">>, _ValType) -> i64;
infer_agg_return_type_1(<<"agg:avg">>, _ValType) -> f64;
infer_agg_return_type_1(<<"agg:min">>, ValType) -> ValType;
infer_agg_return_type_1(<<"agg:max">>, ValType) -> ValType;
infer_agg_return_type_1(<<"agg:first">>, ValType) -> ValType;
infer_agg_return_type_1(<<"agg:last">>, ValType) -> ValType;
infer_agg_return_type_1(_Other, ValType) -> ValType.

agg_sum_type(T) when T =:= i8;  T =:= i16; T =:= i32; T =:= i64;
                    T =:= u8;  T =:= u16; T =:= u32; T =:= u64;
                    T =:= integer -> i64;
agg_sum_type(f32) -> f64;
agg_sum_type(f64) -> f64;
agg_sum_type(numeric) -> numeric;
agg_sum_type(_) -> dynamic.

%%====================================================================
%% Field helpers
%%====================================================================

field_type(FieldName, {struct, Fields, _Rest}) ->
    case maps:find(FieldName, Fields) of
        {ok, T} -> T;
        error -> dynamic
    end;
field_type(_FieldName, _NonStruct) ->
    dynamic.

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

parse_string_list(Bin) ->
    Trimmed = trim_bin(Bin),
    case Trimmed of
        <<"[", _/binary>> ->
            Inner = binary:part(Trimmed, 1, byte_size(Trimmed) - 2),
            Tokens = split_top(Inner, <<",">>),
            [dequote(trim_bin(T)) || T <- Tokens, trim_bin(T) =/= <<>>];
        _ -> [Trimmed]
    end.

%%====================================================================
%% String helpers (minimal subset, inlined to avoid deps)
%%====================================================================

trim_bin(<<>>) -> <<>>;
trim_bin(Bin) -> trim_left(trim_right(Bin)).

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
    Trimmed = trim_bin(Bin),
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
    case trim_bin(Buf) of
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
                    case trim_bin(Buf) of
                        <<>> -> split_top(AfterSep, Sep, 0, 0, Acc, <<>>);
                        BufTrim -> split_top(AfterSep, Sep, 0, 0,
                                             [BufTrim | Acc], <<>>)
                    end;
                _ ->
                    split_top(Rest, Sep, Depth, Quote, Acc,
                              <<Buf/binary, C>>)
            end;
        _ ->
            split_top(Rest, Sep, Depth, Quote, Acc, <<Buf/binary, C>>)
    end.

%%====================================================================
%% Helpers
%%====================================================================

bin(V) when is_binary(V) -> V;
bin(V) when is_list(V) -> list_to_binary(V);
bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
bin(V) -> V.

%%====================================================================
%% Lowered graph type inference
%%====================================================================

-spec infer_lowered(#lowered_graph{}, #{binary() => gdbsp_column_type()},
                    fn_registry()) -> {ok, #lowered_graph{}} | {error, term()}.
infer_lowered(#lowered_graph{nodes = Nodes} = LG, TSMap, FnReg) ->
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
                                         TSMap, FnReg)
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
is_concrete_type(dynamic) -> false;
is_concrete_type({dynamic, _}) -> false;
is_concrete_type({struct, Fields, _}) when map_size(Fields) =:= 0 -> false;
is_concrete_type(_) -> true.

infer_lnode_type(source, _Args, _InputIds, Tags, _TypeAcc, TSMap, _FnReg) ->
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

infer_lnode_type(fixpoint_input, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg) ->
    lowered_input_type(InputIds, TypeAcc);

infer_lnode_type(fixpoint_output, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg) ->
    lowered_input_type(InputIds, TypeAcc);

infer_lnode_type(plus, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg) ->
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

infer_lnode_type(join, Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg) ->
    LType = lowered_nth_input_type(1, InputIds, TypeAcc),
    RType = lowered_nth_input_type(2, InputIds, TypeAcc),
    {on, OnFields} = get_kw_arg(Args, on, []),
    check_join_key_types(OnFields, LType, RType),
    merge_join_type(LType, RType, OnFields);

infer_lnode_type(aggregate, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    FnRef = get_var_arg(Args, 2),
    _ = case maps:find(FnRef, FnReg) of
        {ok, _} -> ok;
        error ->
            error(#{<<"class">> => <<"missing_typespec">>,
                    <<"node">> => FnRef,
                    <<"message">> => <<"aggregate function not found">>})
    end,
    {by, ByFields} = get_kw_arg(Args, by, []),
    {value, ValField} = get_kw_arg(Args, value, <<>>),
    {as, AsField} = get_kw_arg(Args, 'as', <<>>),
    ValType = field_type(ValField, InputType),
    AggRetType = infer_agg_return_type(FnRef, ValType, FnReg),
    ByPairs = [{F, field_type(F, InputType)} || F <- ByFields],
    AllFields = ByPairs ++ [{AsField, AggRetType}],
    {struct, maps:from_list(AllFields), exact};

infer_lnode_type(map, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    {var, FnName} = lists:nth(2, Args),
    case maps:find(FnName, FnReg) of
        {ok, FnJson} -> infer_map_output_type(FnJson, InputType);
        error ->
            error(#{<<"class">> => <<"missing_typespec">>,
                    <<"node">> => FnName,
                    <<"message">> => <<"map function not found">>})
    end;

infer_lnode_type(flat_map, Args, InputIds, _Tags, TypeAcc, _TSMap, FnReg) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    {var, BaseFnName} = lists:nth(2, Args),
    case maps:find(BaseFnName, FnReg) of
        {ok, _} ->
            infer_flat_map_out_type(BaseFnName, InputType);
        error ->
            error(#{<<"class">> => <<"missing_typespec">>,
                    <<"node">> => BaseFnName,
                    <<"message">> => <<"flat_map function not found">>})
    end;

infer_lnode_type(project, Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg) ->
    InputType = lowered_input_type(InputIds, TypeAcc),
    KeepFields = get_string_list_arg(Args, 2),
    project_struct(InputType, KeepFields);

infer_lnode_type(_Op, _Args, InputIds, _Tags, TypeAcc, _TSMap, _FnReg) ->
    lowered_input_type(InputIds, TypeAcc).

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
