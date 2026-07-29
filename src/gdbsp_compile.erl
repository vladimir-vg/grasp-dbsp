%%%-------------------------------------------------------------------
%%% @doc GDBSP compiler — transforms parsed #gdbsp_program{} into
%%% a deployable #circuit_graph{}.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile).

-export([compile/2, compile_with_names/2]).

-include("gdbsp_parse.hrl").
-include("gdbsp_circuit.hrl").

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
    FnReg = maps:get(fn_registry, Options, #{}),
    Incr = maps:get(incrementalize, Options, false),
    #gdbsp_program{nodes = Nodes, typespecs = TSs, circuits = Circuits} = Program,
    try
        case gdbsp_compile_graph:build(Nodes, TSs, FnReg, Circuits) of
            {ok, Graph, NameToId} ->
                Graph2 = case Incr of
                    true  -> gdbsp_compile_incremental:run(Graph);
                    false -> Graph
                end,
                {ok, Graph2, NameToId};
            {error, _} = Err -> Err
        end
    catch
        throw:{compile_error, Reason} ->
            {error, Reason}
    end.
