%%%-------------------------------------------------------------------
%%% @doc Expression lowering and function body type checking.
%%%
%%% Converts parse_expr() (syntactic representation) to expr()
%%% (runtime representation) and checks inline function bodies
%%% against declared typespecs.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_expr).

-export([lower_expr/2, lower_fn_body/2]).
-export([check_fn_body/4, check_all_fns/2, inline_sig_map/1, merge_callable_maps/2]).

-include("gdbsp_parse.hrl").
-include("gdbsp_expr.hrl").
-include("gdbsp_type.hrl").

%%====================================================================
%% Expression Lowering
%%====================================================================

-spec lower_expr(gdbsp_parse_expr:parse_expr(), #{binary() => binary()}) ->
    expr() | no_return().
lower_expr({const, _Line, N, integer, _Src, _Type}, _Bindings) ->
    {value, integer, N};
lower_expr({const, _Line, V, decimal, _Src, _Type}, _Bindings) ->
    {value, numeric, V};
lower_expr({const, _Line, V, float, _Src, _Type}, _Bindings) ->
    {value, f64, V};
lower_expr({const, _Line, S, string, _Src, _Type}, _Bindings) ->
    {value, {string, <<"UTF-8">>}, S};
lower_expr({const, _Line, B, bits, _Src, _Type}, _Bindings) ->
    {value, bits, B};
lower_expr({const, _Line, absent, _Tag, _Src, _Type}, _Bindings) ->
    {value, absent, absent};
lower_expr({symbol, _Line, <<"true">>}, _Bindings) ->
    {value, {enum, [<<"false">>, <<"true">>]}, <<"true">>};
lower_expr({symbol, _Line, <<"false">>}, _Bindings) ->
    {value, {enum, [<<"false">>, <<"true">>]}, <<"false">>};
lower_expr({symbol, _Line, <<"null">>}, _Bindings) ->
    {value, {enum, [<<"null">>]}, <<"null">>};
lower_expr({symbol, Line, Name}, _Bindings) ->
    throw({lower_error, Line, {unknown_symbol, Name}});
lower_expr({var, _Line, Name}, _Bindings) ->
    {arg, Name};
lower_expr({binop, _Line, Op, LHS, RHS}, Bindings) ->
    FnName = gdbsp_builtins:binop_fn_name(Op),
    L = lower_expr(LHS, Bindings),
    R = lower_expr(RHS, Bindings),
    {call, FnName, [L, R], #{}};
lower_expr({unop, _Line, Op, E}, Bindings) ->
    FnName = gdbsp_builtins:unop_fn_name(Op),
    E1 = lower_expr(E, Bindings),
    {call, FnName, [E1], #{}};
lower_expr({dot_access, _Line, Obj, Field}, Bindings) ->
    O = lower_expr(Obj, Bindings),
    {call, <<"std.struct_get">>, [O], #{<<"key">> => {value, {string, <<"UTF-8">>}, Field}}};
lower_expr({array_literal, _Line, Elems}, Bindings) ->
    Lowered = [lower_expr_elem(El, Bindings) || El <- Elems],
    {call, <<"array">>, Lowered, #{}};
lower_expr({dict_literal, _Line, KwArgs, Rest}, Bindings) ->
    KwMap = lower_kw_args(KwArgs, Bindings, #{}),
    MapCall = {call, <<"map">>, [], KwMap},
    case Rest of
        undefined ->
            MapCall;
        RestExpr ->
            R = lower_expr(RestExpr, Bindings),
            {call, <<"map_merge">>, [MapCall, R], #{}}
    end;
lower_expr({subscript, _Line, Obj, {index, Key}}, Bindings) ->
    O = lower_expr(Obj, Bindings),
    K = lower_expr(Key, Bindings),
    {get, O, [K]};
lower_expr({subscript, _Line, Obj, {slice, Start, Stop, Step}}, Bindings) ->
    O = lower_expr(Obj, Bindings),
    S1 = maybe_lower_expr(Start, Bindings),
    S2 = maybe_lower_expr(Stop, Bindings),
    S3 = maybe_lower_expr(Step, Bindings),
    {slice, O, S1, S2, S3};
lower_expr({call, _Line, Name, Args}, Bindings) ->
    Lowered = [lower_call_arg(A, Bindings) || A <- Args],
    {PosArgs, KwMap} = split_call_args(Lowered),
    {call, Name, PosArgs, KwMap};
lower_expr({agg, Line, _Name, _Args}, _Bindings) ->
    throw({lower_error, Line, aggregates_not_allowed_in_fn_body}).

maybe_lower_expr(undefined, _Bindings) -> undefined;
maybe_lower_expr(E, Bindings) -> lower_expr(E, Bindings).

lower_expr_elem({rest, _Line, _Var}, _Bindings) ->
    {value, absent, absent};
lower_expr_elem(E, Bindings) ->
    lower_expr(E, Bindings).

lower_call_arg({kv, Key, Value}, Bindings) ->
    {kv, Key, lower_expr(Value, Bindings)};
lower_call_arg(Arg, Bindings) ->
    lower_expr(Arg, Bindings).

split_call_args(Args) ->
    split_call_args(Args, [], #{}).

split_call_args([], Pos, Kw) ->
    {lists:reverse(Pos), Kw};
split_call_args([{kv, Key, Value} | Rest], Pos, Kw) ->
    split_call_args(Rest, Pos, Kw#{Key => Value});
split_call_args([Arg | Rest], Pos, Kw) ->
    split_call_args(Rest, [Arg | Pos], Kw).

lower_kw_args([], _Bindings, Acc) -> Acc;
lower_kw_args([{kv, Key, Value} | Rest], Bindings, Acc) ->
    V = lower_expr(Value, Bindings),
    lower_kw_args(Rest, Bindings, Acc#{Key => V});
lower_kw_args([Arg | _Rest], _Bindings, _Acc) ->
    throw({lower_error, 0, {non_kv_in_dict, Arg}}).

%%====================================================================
%% Function Body Lowering
%%====================================================================

-spec lower_fn_body(#gdbsp_fn_def{}, #gdbsp_typespec{}) ->
    expr() | no_return().
lower_fn_body(#gdbsp_fn_def{params = Params, body = Body, line = Line},
              #gdbsp_typespec{spec = {function, _PosTypes, KwMap, _RetType}}) ->
    Bindings = build_fn_bindings(Params, KwMap, Line),
    lower_expr(Body, Bindings);
lower_fn_body(_FnDef, #gdbsp_typespec{}) ->
    throw({lower_error, 0, non_function_typespec}).

build_fn_bindings([], _KwMap, _Line) -> #{};
build_fn_bindings([{pos, Name} | Rest], KwMap, Line) ->
    RestBindings = build_fn_bindings(Rest, KwMap, Line),
    RestBindings#{Name => Name};
build_fn_bindings([{kw, Key, Var} | Rest], KwMap, Line) ->
    RestBindings = build_fn_bindings(Rest, KwMap, Line),
    case maps:is_key(Key, KwMap) of
        true -> RestBindings#{Var => Var};
        false -> throw({lower_error, Line, {unexpected_kw_param, Key}})
    end.

%%====================================================================
%% Type Checking
%%====================================================================

-spec check_fn_body(expr(), #{binary() => gdbsp_column_type()}, gdbsp_column_type(),
                    gdbsp_builtins:stdlib_map()) ->
    ok | {error, [term()]}.
check_fn_body(BodyExpr, TypeEnv, DeclaredRetType, StdlibMap) ->
    case gdbsp_type_infer_expr:infer_expr(BodyExpr, TypeEnv, StdlibMap) of
        {ok, InferredType} ->
            InferredCanon = gdbsp_type:canonical_text(InferredType),
            DeclaredCanon = gdbsp_type:canonical_text(DeclaredRetType),
            case InferredCanon =:= DeclaredCanon of
                true -> ok;
                false ->
                    {error, [{return_type_mismatch, InferredType, DeclaredRetType}]}
            end;
        {error, Errors} ->
            {error, Errors}
    end.

%%====================================================================
%% Check All Functions
%%====================================================================

-spec check_all_fns(#gdbsp_program{}, gdbsp_builtins:stdlib_map()) ->
    {ok, #{binary() => jsx:json_term()}, #{binary() => map()}, [term()]} |
    {error, #{binary() => term()}}.
check_all_fns(#gdbsp_program{fn_defs = FnDefs, typespecs = TSs}, StdlibMap) ->
    CallableMap = merge_callable_maps(StdlibMap, inline_sig_map(TSs)),
    case check_all_fns(FnDefs, TSs, CallableMap, #{}, [], []) of
        {ok, FnJsonMap, Warnings} ->
            {ok, FnJsonMap, build_fn_params(FnDefs), Warnings};
        {error, _} = Err -> Err
    end.

%% Callable signatures resolvable from inside inline-function bodies: the
%% stdlib plus every user-declared function typespec. Both use the same
%% {function, Pos, Kw, Ret} shape matched by gdbsp_builtins:resolve_call/4.
inline_sig_map(TSs) ->
    lists:foldl(
        fun(#gdbsp_typespec{name = N, spec = {function, _, _, _}} = TS, Acc) ->
                Acc#{N => [TS | maps:get(N, Acc, [])]};
           (_, Acc) -> Acc
        end, #{}, TSs).

merge_callable_maps(A, B) ->
    maps:merge_with(fun(_K, LA, LB) -> LA ++ LB end, A, B).

build_fn_params(FnDefs) ->
    maps:from_list(
        [begin
             Pos = [PName || {pos, PName} <- Params],
             Kw = [{Key, Var} || {kw, Key, Var} <- Params],
             {FnName, #{pos => Pos, kw => Kw}}
         end || #gdbsp_fn_def{name = FnName, params = Params} <- FnDefs]).

check_all_fns([], _TSs, _StdlibMap, FnJsonMap, _Warnings, Errors) ->
    case Errors of
        [] -> {ok, FnJsonMap, []};
        _ -> {error, maps:from_list(Errors)}
    end;
check_all_fns([FnDef | Rest], TSs, StdlibMap, FnJsonMap, Warnings, Errors) ->
    Name = FnDef#gdbsp_fn_def.name,
    case find_fn_typespec(Name, TSs) of
        {ok, TS} ->
            case check_single_fn(FnDef, TS, StdlibMap) of
                {ok, Json} ->
                    check_all_fns(Rest, TSs, StdlibMap, FnJsonMap#{Name => Json}, Warnings, Errors);
                {error, FnErrors} ->
                    check_all_fns(Rest, TSs, StdlibMap, FnJsonMap, Warnings,
                                  [{Name, FnErrors} | Errors])
            end;
        {error, Reason} ->
            check_all_fns(Rest, TSs, StdlibMap, FnJsonMap, Warnings,
                          [{Name, Reason} | Errors])
    end.

find_fn_typespec(Name, TSs) ->
    case lists:filter(
        fun(#gdbsp_typespec{name = N, spec = Spec}) ->
            N =:= Name andalso element(1, Spec) =:= function
        end, TSs) of
        [] -> {error, missing_typespec};
        [TS | _] -> {ok, TS}
    end.

check_single_fn(FnDef, #gdbsp_typespec{spec = {function, PosTypes, KwMap, RetType}} = TS,
                StdlibMap) ->
    Params = FnDef#gdbsp_fn_def.params,
    case validate_params(Params, PosTypes, KwMap) of
        ok ->
            try
                Body = lower_fn_body(FnDef, TS),
                TypeEnv = build_type_env(Params, PosTypes, KwMap),
                case check_fn_body(Body, TypeEnv, RetType, StdlibMap) of
                    ok ->
                        Json = gdbsp_expr:expr_to_json(Body),
                        {ok, Json};
                    {error, Errors} ->
                        {error, Errors}
                end
            catch
                throw:{lower_error, Line, Reason} ->
                    {error, [{Line, Reason}]}
            end;
        {error, _} = E -> E
    end.

validate_params(Params, PosTypes, KwMap) ->
    {PosParams, KwParams} = lists:partition(fun({pos, _}) -> true; (_) -> false end, Params),
    case length(PosParams) =:= length(PosTypes) of
        false ->
            {error, [{param_count_mismatch, length(PosParams), length(PosTypes)}]};
        true ->
            KwKeys = [K || {kw, K, _} <- KwParams],
            DeclaredKeys = maps:keys(KwMap),
            ExtraKw = KwKeys -- DeclaredKeys,
            MissingKw = DeclaredKeys -- KwKeys,
            case {ExtraKw, MissingKw} of
                {[], []} -> ok;
                {[], _} -> {error, [{missing_kw_params, MissingKw}]};
                {_, []} -> {error, [{extra_kw_params, ExtraKw}]};
                _ -> {error, [{kw_param_mismatch, ExtraKw, MissingKw}]}
            end
    end.

build_type_env([], _PosTypes, _KwMap) -> #{};
build_type_env([{pos, Name} | Rest], [PT | PosTail], KwMap) ->
    Env = build_type_env(Rest, PosTail, KwMap),
    Env#{Name => PT};
build_type_env([{kw, Key, Var} | Rest], PosTypes, KwMap) ->
    Env = build_type_env(Rest, PosTypes, KwMap),
    T = maps:get(Key, KwMap),
    Env#{Var => T}.
