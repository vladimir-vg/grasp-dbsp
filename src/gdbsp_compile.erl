%%%-------------------------------------------------------------------
%%% @doc GDBSP compiler — transforms parsed #gdbsp_program{} into
%%% a deployable #circuit_graph{}.
%%%
%%% Pipeline: parse → lower → type-infer → compile-graph → incrementalize
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile).

-export([compile/2, compile_with_names/2, infer/2]).

-include("gdbsp_parse.hrl").
-include("gdbsp_circuit.hrl").
-include("gdbsp_lowered.hrl").

-type options() :: #{
    incrementalize => boolean(),
    fn_registry => #{binary() := jsx:json_term()}
}.

-type fn_params() :: #{binary() => #{pos := [binary()], kw := [{binary(), binary()}]}}.

-spec compile(#gdbsp_program{}, options()) ->
    {ok, #circuit_graph{}} | {error, term()}.
compile(Program, Options) ->
    case compile_with_names(Program, Options) of
        {ok, Graph, _NameToId} ->
            {ok, Graph};
        {error, _} = Err -> Err
    end.

-spec compile_with_names(#gdbsp_program{}, options()) ->
    {ok, #circuit_graph{}, #{binary() => node_id()}} | {error, term()}.
compile_with_names(Program, Options) ->
    ExternalFnReg = maps:get(fn_registry, Options, #{}),
    Incr = maps:get(incrementalize, Options, false),
    case infer(Program, ExternalFnReg) of
        {ok, Lowered, FnReg, FnParams} ->
            try
                {ok, StdlibMap} = gdbsp_builtins:load_stdlib(),
                KwargOrder = gdbsp_builtins:build_kwarg_order(StdlibMap),
                case gdbsp_compile_graph:build_from_lowered(Lowered, FnReg, FnParams, KwargOrder) of
                    {ok, Graph, NameToId} ->
                        Graph2 = case Incr of
                            true  -> gdbsp_compile_incremental:run(Graph);
                            false -> Graph
                        end,
                        {ok, Graph2, NameToId};
                    {error, _} = Err -> Err
                end
            catch
                throw:{compile_error, Reason} -> {error, Reason};
                throw:{fixpoint_error, Reason} -> {error, {fixpoint_error, Reason}}
            end;
        {error, _} = Err -> Err
    end.

-spec infer(#gdbsp_program{}, #{binary() => jsx:json_term()}) ->
    {ok, #lowered_graph{}, #{binary() => jsx:json_term()}, fn_params()} |
    {error, term()}.
infer(Program, ExternalFnReg) ->
    try
        {ok, StdlibMap} = gdbsp_builtins:load_stdlib(),
        {InlineFnReg, FnParams} = compile_inline_fns(Program, StdlibMap),
        case duplicate_fn_names(ExternalFnReg, InlineFnReg) of
            [] -> ok;
            [Name | _] -> throw({compile_error, {duplicate_function, Name}})
        end,
        FnReg = maps:merge(ExternalFnReg, InlineFnReg),
        CallableMap = gdbsp_compile_expr:merge_callable_maps(
            StdlibMap,
            gdbsp_compile_expr:inline_sig_map(Program#gdbsp_program.typespecs)),
        TSMap = build_ts_map(Program#gdbsp_program.typespecs),
        case gdbsp_compile_lower:run(Program, #{}) of
            {ok, Lowered0} ->
                case gdbsp_type_infer:infer_lowered(Lowered0, TSMap, FnReg, FnParams, CallableMap) of
                    {ok, Lowered} -> {ok, Lowered, FnReg, FnParams};
                    {error, _} = E -> E
                end;
            {error, _} = E -> E
        end
    catch
        throw:{compile_error, Reason} ->
            {error, Reason};
        throw:{fixpoint_error, Reason} ->
            {error, {fixpoint_error, Reason}}
    end.

build_ts_map(Typespecs) ->
    lists:foldl(
        fun(#gdbsp_typespec{name = N, spec = {type, {stream, Inner}}}, Acc) ->
                Acc#{N => Inner};
           (#gdbsp_typespec{name = N, spec = {type, T}}, Acc) ->
                Acc#{N => T};
           (_, Acc) -> Acc
        end, #{}, Typespecs).

compile_inline_fns(#gdbsp_program{fn_defs = []}, _StdlibMap) ->
    {#{}, #{}};
compile_inline_fns(Program, StdlibMap) ->
    case duplicate_inline_names(Program#gdbsp_program.fn_defs) of
        [] -> ok;
        [DupName | _] -> throw({compile_error, {duplicate_function, DupName}})
    end,
    case stdlib_collision_names(Program#gdbsp_program.fn_defs, StdlibMap) of
        [] -> ok;
        [CollisionName | _] -> throw({compile_error, {stdlib_collision, CollisionName}})
    end,
    case gdbsp_compile_expr:check_all_fns(Program, StdlibMap) of
        {ok, InlineFnReg, FnParams, _Warnings} ->
            {InlineFnReg, FnParams};
        {error, ErrorMap} ->
            throw({compile_error, {inline_fn_errors, ErrorMap}})
    end.

duplicate_fn_names(ExternalFnReg, InlineFnReg) ->
    [Name || Name <- maps:keys(InlineFnReg), maps:is_key(Name, ExternalFnReg)].

duplicate_inline_names(FnDefs) ->
    Names = [N || #gdbsp_fn_def{name = N} <- FnDefs],
    Names -- lists:usort(Names).

stdlib_collision_names(FnDefs, StdlibMap) ->
    [N || #gdbsp_fn_def{name = N} <- FnDefs, maps:is_key(N, StdlibMap)].
