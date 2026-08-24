%%%-------------------------------------------------------------------
%%% @doc Expression-level type inference — the single shared engine.
%%%
%%% Infers the type of an `expr()` tree (gdbsp_expr.hrl) given an
%%% argument-type environment and the callable (stdlib + inline) map.
%%% Operates exclusively on the internal `gdbsp_column_type()`
%%% representation (gdbsp_type.hrl) — never on JSON.
%%%
%%% Used by both callers:
%%%   - inline function body checking (gdbsp_compile_expr)
%%%   - stream-level node output typing (gdbsp_type_infer), after
%%%     decoding registry JSON bodies via gdbsp_expr:json_to_expr/1.
%%%
%%% Strict: every unresolvable expression is an error. `dynamic` is
%%% never synthesized as a fallback — it is produced only from a
%%% declared `dynamic` type or from access into an already-`dynamic`
%%% container.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_type_infer_expr).

-include("gdbsp_expr.hrl").
-include("gdbsp_type.hrl").

-export([infer_expr/3]).

-type arg_env() :: #{binary() => gdbsp_column_type()}.

-spec infer_expr(expr(), arg_env(), gdbsp_builtins:stdlib_map()) ->
    {ok, gdbsp_column_type()} | {error, [term()]}.
infer_expr({value, T, _V}, _Env, _StdlibMap) ->
    {ok, T};
infer_expr({arg, Name}, Env, _StdlibMap) ->
    case maps:find(Name, Env) of
        {ok, T} -> {ok, T};
        error -> {error, [{unbound_var, Name}]}
    end;
infer_expr({call, <<"std.struct_get">>, PosArgs, KwArgs}, Env, StdlibMap) ->
    infer_struct_get(PosArgs, KwArgs, Env, StdlibMap);
infer_expr({call, <<"std.struct_set">>, PosArgs, KwArgs}, Env, StdlibMap) ->
    infer_struct_set(PosArgs, KwArgs, Env, StdlibMap);
infer_expr({call, <<"struct">>, _PosArgs, KwArgs}, Env, StdlibMap) ->
    case infer_kw_map(KwArgs, Env, StdlibMap) of
        {ok, Pairs} -> {ok, {struct, maps:from_list(Pairs), exact}};
        {error, _} = E -> E
    end;
infer_expr({call, <<"array">>, PosArgs, _KwArgs}, Env, StdlibMap) ->
    case infer_list(PosArgs, Env, StdlibMap) of
        {ok, PosTypes} ->
            ElemType = case lists:reverse(PosTypes) of
                [T | _] -> T;
                [] -> dynamic
            end,
            {ok, {array, ElemType, varsize}};
        {error, _} = E -> E
    end;
infer_expr({call, <<"map">>, _PosArgs, KwArgs}, Env, StdlibMap) ->
    case infer_kw_map(KwArgs, Env, StdlibMap) of
        {ok, Pairs} ->
            ValType = case lists:reverse([T || {_K, T} <- Pairs]) of
                [T | _] -> T;
                [] -> dynamic
            end,
            {ok, {map, string, ValType}};
        {error, _} = E -> E
    end;
infer_expr({call, <<"map_merge">>, PosArgs, _KwArgs}, Env, StdlibMap) ->
    case infer_list(PosArgs, Env, StdlibMap) of
        {ok, [{map, K, V} | _]} -> {ok, {map, K, V}};
        {ok, _} -> {error, [{map_merge_non_map}]};
        {error, _} = E -> E
    end;
infer_expr({call, Name, PosArgs, KwArgs}, Env, StdlibMap) ->
    case infer_list(PosArgs, Env, StdlibMap) of
        {ok, PosTypes} ->
            case infer_kw_map(KwArgs, Env, StdlibMap) of
                {ok, KwPairs} ->
                    case gdbsp_builtins:resolve_call(Name, PosTypes, KwPairs, StdlibMap) of
                        {ok, RetType, _Concrete} -> {ok, RetType};
                        {error, Reason} -> {error, [{fn_lookup_error, Name, Reason}]}
                    end;
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
infer_expr({get, Obj, [Key | _]}, Env, StdlibMap) ->
    case infer_expr(Obj, Env, StdlibMap) of
        {ok, ObjType} ->
            case infer_expr(Key, Env, StdlibMap) of
                {ok, KeyType} -> infer_get_type(ObjType, Key, KeyType);
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
infer_expr({get, _Obj, []}, _Env, _StdlibMap) ->
    {error, [{get_without_key}]};
infer_expr({slice, Obj, _Start, _Stop, _Step}, Env, StdlibMap) ->
    case infer_expr(Obj, Env, StdlibMap) of
        {ok, ObjType} -> infer_slice_type(ObjType);
        {error, _} = E -> E
    end;
infer_expr({agg, _Name, _PosArgs, _KwArgs}, _Env, _StdlibMap) ->
    {error, [aggregates_not_allowed_in_fn_body]}.

%%====================================================================
%% std.struct_get — key must be a string literal (field value selection)
%%====================================================================

infer_struct_get([StructExpr | _], KwArgs, Env, StdlibMap) ->
    case infer_expr(StructExpr, Env, StdlibMap) of
        {ok, StructType} ->
            case extract_string_literal(maps:get(<<"key">>, KwArgs, undefined)) of
                {ok, KeyStr} -> struct_get_field_type(KeyStr, StructType);
                error -> {error, [{non_literal_key, <<"std.struct_get">>}]}
            end;
        {error, _} = E -> E
    end;
infer_struct_get(_, _, _, _) ->
    {error, [{bad_call, <<"std.struct_get">>}]}.

struct_get_field_type(KeyStr, {struct, Fields, _}) ->
    case maps:find(KeyStr, Fields) of
        {ok, FT} -> {ok, FT};
        error -> {error, [{missing_field, KeyStr}]}
    end;
struct_get_field_type(_KeyStr, dynamic) -> {ok, dynamic};
struct_get_field_type(_KeyStr, {dynamic, _}) -> {ok, dynamic};
struct_get_field_type(_KeyStr, _Other) ->
    {error, [{non_struct_target, <<"std.struct_get">>}]}.

%%====================================================================
%% std.struct_set — update-only, literal key, value type must match
%%====================================================================

infer_struct_set([StructExpr | _], KwArgs, Env, StdlibMap) ->
    case infer_expr(StructExpr, Env, StdlibMap) of
        {ok, StructType} ->
            case extract_string_literal(maps:get(<<"key">>, KwArgs, undefined)) of
                {ok, KeyStr} ->
                    struct_set_field_type(KeyStr, StructType, KwArgs, Env, StdlibMap);
                error -> {error, [{non_literal_key, <<"std.struct_set">>}]}
            end;
        {error, _} = E -> E
    end;
infer_struct_set(_, _, _, _) ->
    {error, [{bad_call, <<"std.struct_set">>}]}.

struct_set_field_type(KeyStr, {struct, Fields, _} = StructType, KwArgs, Env, StdlibMap) ->
    case maps:find(KeyStr, Fields) of
        {ok, FieldType} ->
            case maps:find(<<"value">>, KwArgs) of
                {ok, ValueExpr} ->
                    case infer_expr(ValueExpr, Env, StdlibMap) of
                        {ok, ValType} ->
                            case gdbsp_builtins:exact_match(FieldType, ValType) of
                                true -> {ok, StructType};
                                false -> {error, [{type_conflict, {field, KeyStr}, FieldType, ValType}]}
                            end;
                        {error, _} = E -> E
                    end;
                error -> {error, [{missing_kw_arg, <<"value">>}]}
            end;
        error -> {error, [{missing_field, KeyStr}]}
    end;
struct_set_field_type(KeyStr, dynamic, _KwArgs, _Env, _StdlibMap) ->
    {error, [{non_struct_target, <<"std.struct_set">>}, {field, KeyStr}]};
struct_set_field_type(KeyStr, {dynamic, _}, _KwArgs, _Env, _StdlibMap) ->
    {error, [{non_struct_target, <<"std.struct_set">>}, {field, KeyStr}]};
struct_set_field_type(_KeyStr, _Other, _KwArgs, _Env, _StdlibMap) ->
    {error, [{non_struct_target, <<"std.struct_set">>}]}.

%%====================================================================
%% Subscript (get) — struct needs literal key; map/array need key type
%%====================================================================

infer_get_type({array, T, _}, _KeyExpr, KeyType) ->
    case is_integer_type(KeyType) of
        true -> {ok, T};
        false -> {error, [{array_index_not_integer, KeyType}]}
    end;
infer_get_type({map, K, V}, _KeyExpr, KeyType) ->
    case gdbsp_builtins:exact_match(K, KeyType) of
        true -> {ok, V};
        false -> {error, [{map_key_type_mismatch, KeyType, K}]}
    end;
infer_get_type({struct, Fields, _}, KeyExpr, _KeyType) ->
    case extract_string_literal(KeyExpr) of
        {ok, KeyStr} ->
            case maps:find(KeyStr, Fields) of
                {ok, FT} -> {ok, FT};
                error -> {error, [{missing_field, KeyStr}]}
            end;
        error -> {error, [{non_literal_key, subscript}]}
    end;
infer_get_type(dynamic, _KeyExpr, _KeyType) -> {ok, dynamic};
infer_get_type({dynamic, _}, _KeyExpr, _KeyType) -> {ok, dynamic};
infer_get_type(Other, _KeyExpr, _KeyType) ->
    {error, [{get_on_non_container, Other}]}.

infer_slice_type({array, T, _}) -> {ok, {array, T, varsize}};
infer_slice_type(string) -> {ok, string};
infer_slice_type({string, _}) -> {ok, string};
infer_slice_type(bytes) -> {ok, bytes};
infer_slice_type({bytes, _}) -> {ok, bytes};
infer_slice_type(dynamic) -> {ok, dynamic};
infer_slice_type({dynamic, _}) -> {ok, dynamic};
infer_slice_type(Other) -> {error, [{slice_on_non_sequence, Other}]}.

%%====================================================================
%% Helpers
%%====================================================================

infer_list([], _Env, _StdlibMap) -> {ok, []};
infer_list([E | Rest], Env, StdlibMap) ->
    case infer_expr(E, Env, StdlibMap) of
        {ok, T} ->
            case infer_list(Rest, Env, StdlibMap) of
                {ok, Ts} -> {ok, [T | Ts]};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end.

infer_kw_map(KwMap, Env, StdlibMap) when is_map(KwMap) ->
    infer_kw_pairs(maps:to_list(KwMap), Env, StdlibMap, []).

infer_kw_pairs([], _Env, _StdlibMap, Acc) -> {ok, lists:reverse(Acc)};
infer_kw_pairs([{K, V} | Rest], Env, StdlibMap, Acc) ->
    case infer_expr(V, Env, StdlibMap) of
        {ok, T} -> infer_kw_pairs(Rest, Env, StdlibMap, [{K, T} | Acc]);
        {error, _} = Err -> Err
    end.

extract_string_literal({value, string, V}) when is_binary(V) -> {ok, V};
extract_string_literal({value, {string, _}, V}) when is_binary(V) -> {ok, V};
extract_string_literal(_) -> error.

is_integer_type(i8) -> true;
is_integer_type(i16) -> true;
is_integer_type(i32) -> true;
is_integer_type(i64) -> true;
is_integer_type(u8) -> true;
is_integer_type(u16) -> true;
is_integer_type(u32) -> true;
is_integer_type(u64) -> true;
is_integer_type(integer) -> true;
is_integer_type(_) -> false.
