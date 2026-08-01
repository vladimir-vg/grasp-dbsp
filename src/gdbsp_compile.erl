%%%-------------------------------------------------------------------
%%% @doc GDBSP compiler — transforms parsed #gdbsp_program{} into
%%% a deployable #circuit_graph{}.
%%%
%%% Pipeline: parse → lower → type-infer → compile-graph → incrementalize
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile).

-export([compile/2, compile_with_names/2]).

-include("gdbsp_parse.hrl").
-include("gdbsp_circuit.hrl").
-include("gdbsp_lowered.hrl").

-type options() :: #{
    incrementalize => boolean(),
    fn_registry => #{binary() := jsx:json_term()}
}.

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
    try
        InlineFnReg = compile_inline_fns(Program, ExternalFnReg),
        FnReg = maps:merge(ExternalFnReg, InlineFnReg),
        TSMap = build_ts_map(Program#gdbsp_program.typespecs),
        case gdbsp_compile_lower:run(Program, #{}) of
            {ok, Lowered0} ->
                case gdbsp_type_infer:infer_lowered(Lowered0, TSMap, FnReg) of
                    {ok, Lowered} ->
                        case gdbsp_compile_graph:build_from_lowered(Lowered, FnReg) of
                            {ok, Graph, NameToId} ->
                                Graph2 = case Incr of
                                    true  -> gdbsp_compile_incremental:run(Graph);
                                    false -> Graph
                                end,
                                {ok, Graph2, NameToId};
                            {error, _} = Err -> Err
                        end;
                    {error, _} = Err -> Err
                end;
            {error, _} = Err -> Err
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

compile_inline_fns(#gdbsp_program{fn_defs = []}, _ExternalFnReg) ->
    #{};
compile_inline_fns(Program, _ExternalFnReg) ->
    case gdbsp_compile_expr:check_all_fns(Program) of
        {ok, InlineFnReg, _Warnings} ->
            InlineFnReg;
        {error, ErrorMap} ->
            throw({compile_error, {inline_fn_errors, ErrorMap}})
    end.
