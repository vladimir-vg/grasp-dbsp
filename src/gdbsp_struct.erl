%%%-------------------------------------------------------------------
%%% @doc Runtime typed-value module — struct operations.
%%%
%%% Provides struct construction, field access, field update,
%%% typed-row conversion, and value wrapping/unwrapping.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_struct).

-include("gdbsp_type.hrl").

-export([struct_constructor/2]).
-export([struct_get/2]).
-export([struct_set/3]).
-export([map_to_struct/2, struct_to_map/1, struct_extend/3, struct_project/2]).
-export([unwrap_value/1]).
-export([wrap_value/2]).

%%====================================================================
%% struct:struct(type, map(string, dynamic)) -> struct
%%====================================================================

-spec struct_constructor(type_arg(), value()) -> value().
struct_constructor({type, {struct, Fields, Rest}}, {value, {map, dynamic, dynamic}, RawValues}) ->
    case is_map(RawValues) andalso maps:keys(RawValues) =:= maps:keys(Fields) of
        false ->
            erlang:throw(drop_row);
        true ->
            TypedValues = maps:fold(fun(Field, V, Acc) ->
                {value, _, _} = V,
                Acc#{Field => V}
            end, #{}, RawValues),
            {value, {struct, Fields, Rest}, TypedValues}
    end;
struct_constructor(_TypeArg, _RawValues) ->
    erlang:throw(drop_row).

%%====================================================================
%% struct:get(struct, key: string) -> dynamic
%%====================================================================

-define(IS_STRING_TYPE(KT), (KT =:= string orelse KT =:= {string, <<"UTF-8">>})).

-spec struct_get(value(), value()) -> value().
struct_get({value, {struct, _Fields, _Rest}, TypedValues}, {value, KeyType, Key})
        when ?IS_STRING_TYPE(KeyType) ->
    case is_map(TypedValues) andalso maps:find(Key, TypedValues) of
        {ok, Val} -> Val;
        error -> erlang:throw(drop_row)
    end;
struct_get({value, _, M}, {value, KeyType, Key})
         when is_map(M), ?IS_STRING_TYPE(KeyType) ->
    case maps:find(Key, M) of
        {ok, {value, FieldType, RawVal}} -> {value, {dynamic, FieldType}, RawVal};
        error -> erlang:throw(drop_row)
    end;
struct_get(_, _) ->
    erlang:throw(drop_row).

%%====================================================================
%% struct:set(struct, key: string, value: dynamic) -> struct
%%====================================================================

-spec struct_set(value(), value(), value()) -> value().
struct_set({value, {struct, Fields, Rest}, TypedValues},
           {value, KeyType, Key},
           {value, NewType, _} = NewVal) when ?IS_STRING_TYPE(KeyType) ->
    case is_map(Fields) andalso is_map(TypedValues) andalso maps:is_key(Key, Fields) of
        false ->
            erlang:throw(drop_row);
        true ->
            FieldType = maps:get(Key, Fields),
            case NewType =:= FieldType of
                true  -> {value, {struct, Fields, Rest}, TypedValues#{Key => NewVal}};
                false -> erlang:throw(drop_row)
            end
    end;
struct_set(_, _, _) ->
    erlang:throw(drop_row).

%%====================================================================
%% Typed-row boundary utilities
%%====================================================================

-spec map_to_struct(#{binary() => term()}, gdbsp_column_type()) -> value().
map_to_struct(RawMap, {dynamic, _SchemaInner}) when is_map(RawMap) ->
    Wrapped = maps:map(fun(_K, V) -> wrap_value(V, infer_type(V)) end, RawMap),
    {value, {dynamic, {map, string, dynamic}}, Wrapped};
map_to_struct(RawMap, dynamic) when is_map(RawMap) ->
    Wrapped = maps:map(fun(_K, V) -> wrap_value(V, infer_type(V)) end, RawMap),
    {value, {dynamic, {map, string, dynamic}}, Wrapped};
map_to_struct(RawMap, {struct, Fields, Rest}) when is_list(Fields) ->
    map_to_struct(RawMap, {struct, maps:from_list(Fields), Rest});
map_to_struct(RawMap, {struct, Fields, Rest}) ->
    TypedValues = maps:fold(fun(Var, Type, Acc) ->
        case maps:find(Var, RawMap) of
            {ok, Val} -> Acc#{Var => wrap_value(Val, Type)};
            error -> erlang:throw(drop_row)
        end
    end, #{}, Fields),
    {value, {struct, Fields, Rest}, TypedValues}.

-type raw_value() :: term().
-spec wrap_value(raw_value(), gdbsp_column_type()) -> value().
wrap_value({value, T, V}, {dynamic, InnerType}) when InnerType =/= undefined ->
    {value, {dynamic, InnerType}, V};
wrap_value({value, T, V}, {dynamic, undefined}) ->
    {value, {dynamic, T}, V};
wrap_value({value, T, V}, dynamic) ->
    {value, {dynamic, T}, V};
wrap_value({value, _, _} = AlreadyTyped, _T) ->
    AlreadyTyped;
wrap_value(absent, {optional, _T}) ->
    {value, {optional, _T}, absent};
wrap_value(Val, {map, _K, V}) when is_map(Val) ->
    Wrapped = maps:fold(fun(MapKey, MapVal, Acc) ->
        Acc#{MapKey => wrap_value(MapVal, V)}
    end, #{}, Val),
    {value, {map, _K, V}, Wrapped};
wrap_value(Val, {array, E, S}) when is_list(Val) ->
    {value, {array, E, S}, [wrap_value(Elem, E) || Elem <- Val]};
wrap_value({value, _} = Present, {optional, T}) ->
    {value, {optional, T}, Present};
wrap_value(Val, {optional, T}) ->
    {value, {optional, T}, {value, wrap_inner_optional(Val, T)}};
wrap_value(Val, {closure, Params, T}) ->
    {value, {closure, Params, T}, wrap_value(Val, T)};
wrap_value(Val, {struct, Fields, Rest}) when is_list(Fields) ->
    wrap_value(Val, {struct, maps:from_list(Fields), Rest});
wrap_value(Val, {struct, Fields, Rest}) when is_map(Val) ->
    TypedValues = maps:fold(fun(Var, Type, Acc) ->
        case maps:find(Var, Val) of
            {ok, V2} -> Acc#{Var => wrap_value(V2, Type)};
            error -> Acc
        end
    end, #{}, Fields),
    {value, {struct, Fields, Rest}, TypedValues};
wrap_value(Val, f32) when is_integer(Val) -> {value, f32, float(Val)};
wrap_value(Val, f64) when is_integer(Val) -> {value, f64, float(Val)};
wrap_value(Val, numeric) when is_float(Val) -> {value, numeric, decimal:to_decimal(Val, #{precision => 20, rounding => round_half_up})};
wrap_value(Val, numeric) when is_integer(Val) -> {value, numeric, decimal:to_decimal(Val, #{precision => 20, rounding => round_half_up})};
wrap_value(Val, {numeric, P, S}) when is_float(Val) -> {value, {numeric, P, S}, decimal:to_decimal(Val, #{precision => 20, rounding => round_half_up})};
wrap_value(Val, {numeric, P, S}) when is_integer(Val) -> {value, {numeric, P, S}, decimal:to_decimal(Val, #{precision => 20, rounding => round_half_up})};
wrap_value(Val, {dynamic, Inner}) when Inner =/= undefined ->
    {value, {dynamic, Inner}, Val};
wrap_value(Val, dynamic) ->
    ActualType = infer_type(Val),
    {value, {dynamic, ActualType}, Val};
%% Bare `json` target: wrap as a Form-1 json passthrough with unknown inner
%% type — never the illegal bare {value, json, _} tag
%% (value-type-representation-hardening.md, Tier 1).
wrap_value(Val, json) ->
    {value, {json, undefined}, Val};
wrap_value(Val, T) ->
    {value, T, Val}.

wrap_inner_optional(absent, _T) -> absent;
wrap_inner_optional(Val, T) ->
    {value, _, Raw} = wrap_value(Val, T),
    Raw.

-spec struct_to_map(value()) -> #{binary() => term()}.
struct_to_map({value, {struct, _Fields, _Rest}, TypedValues}) ->
    maps:map(fun(_Var, V) -> unwrap_value(V) end, TypedValues).

-spec unwrap_value(value() | term()) -> term().
unwrap_value({value, {map, _, _}, M}) ->
    maps:map(fun(_K, V) -> unwrap_value(V) end, M);
unwrap_value({value, {array, _, _}, L}) ->
    [unwrap_value(E) || E <- L];
unwrap_value({value, {struct, _, _}, TypedValues}) ->
    maps:map(fun(_K, V) -> unwrap_value(V) end, TypedValues);
unwrap_value({value, {optional, _}, absent}) ->
    null;
unwrap_value({value, {optional, _}, {value, V}}) ->
    V;
unwrap_value({value, {closure, _, _}, V}) ->
    unwrap_value(V);
unwrap_value({value, {optional, _}, absent}) ->
    absent;
unwrap_value({value, {dynamic, T}, V}) ->
    {value, T, V};
unwrap_value({value, {json, T}, V}) ->
    {value, T, V};
unwrap_value({value, _, V}) ->
    V;
unwrap_value(V) ->
    V.

-spec struct_extend(value(), binary(), value()) -> value().
struct_extend({value, {struct, Fields, Rest}, TypedValues}, Var, {value, NewType, NewVal}) when is_map(Fields) ->
    NewFields = maps:put(Var, NewType, Fields),
    NewTypedVals = maps:put(Var, {value, NewType, NewVal}, TypedValues),
    {value, {struct, NewFields, Rest}, NewTypedVals}.

-spec struct_project(value(), [binary()]) -> value().
struct_project({value, {struct, Fields, Rest}, TypedValues}, KeepVars) when is_map(Fields) ->
    NewFields = maps:with(KeepVars, Fields),
    NewTypedVals = maps:with(KeepVars, TypedValues),
    {value, {struct, NewFields, Rest}, NewTypedVals}.

%%====================================================================
%% infer_type: map Erlang term to Grasp type
%%====================================================================

-spec infer_type(term()) -> gdbsp_column_type().
infer_type(V) when is_integer(V) -> integer;
infer_type(V) when is_binary(V) -> string;
infer_type(V) when is_float(V) -> numeric;
infer_type({decimal, _, _}) -> numeric;
infer_type(V) when is_boolean(V) -> ?BOOL;
infer_type(absent) -> absent;
infer_type(V) when is_list(V) -> {array, dynamic, varsize};
infer_type(V) when is_map(V) -> {map, string, dynamic};
infer_type(_V) -> dynamic.
