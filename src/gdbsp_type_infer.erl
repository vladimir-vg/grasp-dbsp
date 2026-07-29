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

-export([infer/3]).

-type fn_registry() :: #{binary() => map()}.

%%====================================================================
%% Public API
%%====================================================================

-spec infer([#gdbsp_node_def{}], [#gdbsp_typespec{}], fn_registry()) ->
    #{binary() => gdbsp_column_type()}.
infer(Nodes, Typespecs, FnReg) ->
    TSMap = build_ts_map(Typespecs),
    NodeMap = build_node_map(Nodes),
    Order = topo_sort(NodeMap),
    infer_in_order(Order, NodeMap, TSMap, FnReg, #{}).

%%====================================================================
%% Building maps
%%====================================================================

build_ts_map(Typespecs) ->
    lists:foldl(
        fun(#gdbsp_typespec{name = N, spec = {type, {stream, Inner}}}, Acc) ->
                Acc#{N => Inner};
           (#gdbsp_typespec{name = N, spec = {type, T}}, Acc) ->
                Acc#{N => T};
           (#gdbsp_typespec{name = N, spec = Spec}, Acc) ->
                Acc#{N => Spec}
        end, #{}, Typespecs).

build_node_map(Nodes) ->
    lists:foldl(
        fun(#gdbsp_node_def{name = N, op = Op, args = Args}, Acc) ->
                Acc#{N => {Op, Args}}
        end, #{}, Nodes).

%%====================================================================
%% Topological sort
%%====================================================================

topo_sort(NodeMap) ->
    InDeg = maps:map(fun(_N, {_Op, Args}) ->
        length(node_refs(Args, NodeMap))
    end, NodeMap),
    Consumers = build_cons_map(NodeMap),
    AllNames = maps:keys(NodeMap),
    Queue = [N || N <- AllNames, maps:get(N, InDeg) =:= 0],
    topo_loop(Queue, InDeg, Consumers, []).

build_cons_map(NodeMap) ->
    lists:foldl(
        fun({Name, {_Op, Args}}, Acc) ->
            Refs = node_refs(Args, NodeMap),
            lists:foldl(
                fun(Ref, A) ->
                    maps:update_with(Ref, fun(L) -> [Name | L] end, [Name], A)
                end, Acc, Refs)
        end, #{}, maps:to_list(NodeMap)).

node_refs(Args, NodeMap) ->
    lists:filtermap(
        fun({var, Name}) when is_binary(Name) ->
                case maps:is_key(Name, NodeMap) of
                    true -> {true, Name};
                    false -> false
                end;
           (_) -> false
        end, Args).

topo_loop(Queue, InDeg, Consumers, Acc) ->
    case Queue of
        [] ->
            case length(Acc) =:= map_size(InDeg) of
                true -> lists:reverse(Acc);
                false ->
                    Stuck = maps:keys(InDeg) -- Acc,
                    error(#{<<"class">> => <<"cycle">>, <<"stuck">> => lists:sort(Stuck)})
            end;
        [Name | Rest] ->
            NewAcc = [Name | Acc],
            Dependents = maps:get(Name, Consumers, []),
            {NewQ, NewIndeg} =
                lists:foldl(
                    fun(Dep, {Q, ID}) ->
                        NewD = maps:get(Dep, ID) - 1,
                        ID2 = maps:put(Dep, NewD, ID),
                        case NewD of
                            0 -> {[Dep | Q], ID2};
                            _ -> {Q, ID2}
                        end
                    end, {Rest, InDeg}, Dependents),
            topo_loop(NewQ, NewIndeg, Consumers, NewAcc)
    end.

%%====================================================================
%% Inference loop
%%====================================================================

infer_in_order([], _NodeMap, _TSMap, _FnReg, Acc) ->
    Acc;
infer_in_order([Name | Rest], NodeMap, TSMap, FnReg, Acc) ->
    Type = infer_node(Name, NodeMap, TSMap, Acc, FnReg),
    infer_in_order(Rest, NodeMap, TSMap, FnReg, Acc#{Name => Type}).

infer_node(Name, NodeMap, TSMap, TypeAcc, FnReg) ->
    case maps:find(Name, TSMap) of
        {ok, {function, _, _}} ->
            infer_node_from_op(Name, NodeMap, TypeAcc, FnReg);
        {ok, {aggregate_function, _, _}} ->
            infer_node_from_op(Name, NodeMap, TypeAcc, FnReg);
        {ok, T} ->
            T;
        error ->
            infer_node_from_op(Name, NodeMap, TypeAcc, FnReg)
    end.

infer_node_from_op(Name, NodeMap, TypeAcc, FnReg) ->
    {Op, Args} = maps:get(Name, NodeMap),
    infer_node_op(Op, Args, TypeAcc, FnReg, Name).

%%====================================================================
%% Per-operator type inference
%%====================================================================

infer_node_op(source, _Args, _TypeAcc, _FnReg, Name) ->
    error(#{<<"class">> => <<"missing_typespec">>, <<"node">> => Name});

infer_node_op(filter, Args, TypeAcc, _FnReg, _Name) ->
    input_type(Args, TypeAcc);

infer_node_op(distinct, Args, TypeAcc, _FnReg, _Name) ->
    input_type(Args, TypeAcc);

infer_node_op(plus, Args, TypeAcc, _FnReg, _Name) ->
    input_type(Args, TypeAcc);

infer_node_op(neg, Args, TypeAcc, _FnReg, _Name) ->
    input_type(Args, TypeAcc);

infer_node_op(integrate, Args, TypeAcc, _FnReg, _Name) ->
    input_type(Args, TypeAcc);

infer_node_op(differentiate, Args, TypeAcc, _FnReg, _Name) ->
    input_type(Args, TypeAcc);

infer_node_op(project, Args, TypeAcc, _FnReg, _Name) ->
    InputType = input_type(Args, TypeAcc),
    KeepFields = get_string_list_arg(Args, 2),
    project_struct(InputType, KeepFields);

infer_node_op(map, Args, TypeAcc, FnReg, _Name) ->
    InputType = input_type(Args, TypeAcc),
    {var, FnName} = lists:nth(2, Args),
    case maps:find(FnName, FnReg) of
        {ok, FnJson} ->
            infer_map_output_type(FnJson, InputType);
        error ->
            InputType
    end;

infer_node_op(flat_map, Args, TypeAcc, _FnReg, _Name) ->
    InputType = input_type(Args, TypeAcc),
    {var, BaseFnName} = lists:nth(2, Args),
    infer_flat_map_out_type(BaseFnName, InputType);

infer_node_op(join, Args, TypeAcc, _FnReg, _Name) ->
    [InputRef1, InputRef2] = node_refs(Args, TypeAcc),
    LType = maps:get(InputRef1, TypeAcc),
    RType = maps:get(InputRef2, TypeAcc),
    {on, OnFields} = get_kw_arg(Args, on, []),
    merge_join_type(LType, RType, OnFields);

infer_node_op(aggregate, Args, TypeAcc, FnReg, _Name) ->
    InputRef = get_var_arg(Args, 1),
    FnRef = get_var_arg(Args, 2),
    InputType = maps:get(InputRef, TypeAcc),
    {by, ByFields} = get_kw_arg(Args, by, []),
    {value, ValField} = get_kw_arg(Args, value, <<>>),
    {as, AsField} = get_kw_arg(Args, 'as', <<>>),

    ValType = field_type(ValField, InputType),
    AggRetType = infer_agg_return_type(FnRef, ValType, FnReg),

    ByPairs = [{F, field_type(F, InputType)} || F <- ByFields],
    AllFields = ByPairs ++ [{AsField, AggRetType}],
    {struct, maps:from_list(AllFields), exact};

infer_node_op(antijoin, Args, TypeAcc, _FnReg, _Name) ->
    input_type(Args, TypeAcc);

infer_node_op(output, Args, TypeAcc, _FnReg, _Name) ->
    input_type(Args, TypeAcc);

%% Default: inherit from first input
infer_node_op(_Op, Args, TypeAcc, _FnReg, _Name) ->
    input_type(Args, TypeAcc).

%%====================================================================
%% Input type extraction
%%====================================================================

input_type(Args, TypeAcc) ->
    case node_refs(Args, TypeAcc) of
        [FirstRef | _] -> maps:get(FirstRef, TypeAcc);
        [] -> dynamic
    end.

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

infer_map_output_type(#{<<"field">> := FieldName}, InputType) ->
    field_type(bin(FieldName), InputType);

infer_map_output_type(#{<<"type">> := TypeJson, <<"value">> := _ValJson},
                      _InputType) ->
    case gdbsp_type:parse_type(TypeJson) of
        {ok, T} -> T;
        {error, _} -> dynamic
    end;

infer_map_output_type(#{<<"call">> := CallName} = CallJson, InputType) ->
    infer_call_output_type(bin(CallName), CallJson, InputType);

infer_map_output_type(_Other, InputType) ->
    InputType.

%%====================================================================
%% Expression output type (for sub-expressions inside map functions)
%%====================================================================

infer_expr_output_type(#{<<"field">> := FieldName}, InputType) ->
    field_type(bin(FieldName), InputType);

infer_expr_output_type(#{<<"type">> := TypeJson}, _InputType) ->
    case gdbsp_type:parse_type(TypeJson) of
        {ok, T} -> T;
        {error, _} -> dynamic
    end;

infer_expr_output_type(#{<<"call">> := CallName} = CallJson, InputType) ->
    infer_call_output_type(bin(CallName), CallJson, InputType);

infer_expr_output_type(#{<<"aggregate">> := _AggName}, _InputType) ->
    dynamic;

infer_expr_output_type(_Other, _InputType) ->
    dynamic.

%%====================================================================
%% Function call return type lookup
%%====================================================================

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
