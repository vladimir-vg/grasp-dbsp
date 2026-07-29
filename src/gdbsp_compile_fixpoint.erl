%%%-------------------------------------------------------------------
%%% @doc Pre-processing pass: expands fixpoint calls into inline operators.
%%%
%%% Stage 1 only handles trivial fixpoints (no self-referential params),
%%% compiled as macro expansion.
%%%
%%% Phase 1: For each fixpoint node, look up circuit definition and
%%% substitute body nodes with resolved arguments. Prefix body node
%%% names to avoid collisions.
%%%
%%% Phase 2: Resolve circuit_access nodes — replace fp.field with the
%%% prefixed body node name.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_fixpoint).

-export([expand/1]).

-include("gdbsp_parse.hrl").

%%====================================================================
%% Public API
%%====================================================================

-spec expand(#gdbsp_program{}) ->
    {ok, #gdbsp_program{}} | {error, term()}.
expand(Prog) ->
    #gdbsp_program{nodes = Nodes, typespecs = TSs, circuits = Circuits} = Prog,
    CircuitMap = build_circuit_map(Circuits),
    try
        {ExpandedNodes, AccessMap} = expand_fixpoints(Nodes, CircuitMap, #{}),
        ResolvedNodes = resolve_access_nodes(ExpandedNodes, AccessMap),
        ResolvedTSs = resolve_access_typespecs(TSs, AccessMap),
        {ok, #gdbsp_program{nodes = ResolvedNodes,
                            typespecs = ResolvedTSs,
                            circuits = Circuits}}
    catch
        throw:{fixpoint_error, Reason} ->
            {error, Reason}
    end.

%%====================================================================
%% Phase 1 — expand fixpoint calls
%%====================================================================

expand_fixpoints([], _CircuitMap, AccMap) ->
    {[], AccMap};
expand_fixpoints([#gdbsp_node_def{op = fixpoint, name = FpName, args = Args,
                                   line = L} | Rest],
                  CircuitMap, AccMap) ->
    {BodyNodes, NewAccMap} = expand_one_fixpoint(FpName, Args, L, CircuitMap, AccMap),
    {RestNodes, AccMap2} = expand_fixpoints(Rest, CircuitMap, NewAccMap),
    {BodyNodes ++ RestNodes, AccMap2};
expand_fixpoints([Node | Rest], CircuitMap, AccMap) ->
    {RestNodes, AccMap2} = expand_fixpoints(Rest, CircuitMap, AccMap),
    {[Node | RestNodes], AccMap2}.

expand_one_fixpoint(FpName, Args, Line, CircuitMap, AccMap) ->
    [CircuitNameArg | KwArgs] = Args,
    CircuitName = case CircuitNameArg of
        {var, N} -> N;
        _ -> throw_fixpoint_error(Line, "first fixpoint arg must be a circuit name")
    end,
    case maps:find(CircuitName, CircuitMap) of
        error ->
            throw_fixpoint_error(Line, io_lib:format(
                "unknown circuit: ~s", [CircuitName]));
        {ok, Def} ->
            #gdbsp_circuit_def{params = Params, body = BodyNodes} = Def,
            KwMap = build_kw_map(KwArgs, Line),
            ok = validate_fixpoint_args(Params, KwMap, CircuitName, Line),
            expand_body(FpName, BodyNodes, Params, KwMap, AccMap, Line)
    end.

build_kw_map(KwArgs, Line) ->
    maps:from_list(
        lists:map(
            fun({K, V}) -> {K, V};
               (Other) -> throw_fixpoint_error(Line, io_lib:format(
                    "expected keyword argument, got: ~p", [Other]))
            end,
            KwArgs
        )
    ).

validate_fixpoint_args(Params, KwMap, _CircuitName, _Line) ->
    ParamKeys = maps:keys(Params),
    KwKeys = maps:keys(KwMap),
    Missing = ParamKeys -- KwKeys,
    case Missing of
        [] -> ok;
        _ -> throw_fixpoint_error(_Line, io_lib:format(
                "missing arguments for circuit ~s: ~s",
                [_CircuitName, join_keys(Missing)]))
    end,
    Extra = KwKeys -- ParamKeys,
    case Extra of
        [] -> ok;
        _ -> throw_fixpoint_error(_Line, io_lib:format(
                "unknown arguments for circuit ~s: ~s",
                [_CircuitName, join_keys(Extra)]))
    end.

expand_body(FpName, BodyNodes, Params, KwMap, AccMapIn, _Line) ->
    Prefix = <<FpName/binary, "_">>,
    {NewNodes, NewAccMap} = lists:foldl(
        fun(BodyNode, {NodesAcc, MapAcc}) ->
            #gdbsp_node_def{name = BodyName, op = BodyOp,
                            args = BodyArgs, line = BodyL} = BodyNode,
            Prefixed = <<Prefix/binary, BodyName/binary>>,
            InternalToArg = maps:fold(
                fun(Kw, Internal, A) ->
                    A#{Internal => maps:get(Kw, KwMap)}
                end,
                #{},
                Params
            ),
            NewArgs = substitute_params(BodyArgs, InternalToArg),
            NewNode = #gdbsp_node_def{
                name = Prefixed, op = BodyOp, args = NewArgs, line = BodyL},
            NewMap = MapAcc#{{FpName, BodyName} => Prefixed},
            {[NewNode | NodesAcc], NewMap}
        end,
        {[], AccMapIn},
        BodyNodes
    ),
    {lists:reverse(NewNodes), NewAccMap}.

substitute_params(Args, SubMap) ->
    lists:map(
        fun({var, Name}) ->
            case maps:find(Name, SubMap) of
                {ok, Replacement} -> Replacement;
                error -> {var, Name}
            end;
           (Other) -> Other
        end,
        Args
    ).

%%====================================================================
%% Phase 2 — resolve circuit_access nodes and arguments
%%====================================================================

resolve_access_nodes(Nodes, AccessMap) ->
    lists:filtermap(
        fun(#gdbsp_node_def{op = circuit_access, name = Name, args = Args,
                             line = L}) ->
            case Args of
                [{var, VarName}, {var, FieldName}] ->
                    case maps:find({VarName, FieldName}, AccessMap) of
                        {ok, ResolvedName} ->
                            NewNode = #gdbsp_node_def{
                                name = Name,
                                op = plus,
                                args = [{var, ResolvedName}],
                                line = L},
                            {true, NewNode};
                        error ->
                            throw_fixpoint_error(L, io_lib:format(
                                "unresolved circuit access: ~s.~s",
                                [VarName, FieldName]))
                    end;
                _ ->
                    throw_fixpoint_error(L, "invalid circuit_access args")
            end;
           (Node) ->
            {true, resolve_node_args(Node, AccessMap)}
        end,
        Nodes
    ).

resolve_node_args(#gdbsp_node_def{} = Node, AccessMap) ->
    NewArgs = resolve_args(Node#gdbsp_node_def.args, AccessMap),
    Node#gdbsp_node_def{args = NewArgs}.

resolve_args(Args, AccessMap) ->
    lists:map(
        fun({circuit_access, VarName, FieldName}) ->
            case maps:find({VarName, FieldName}, AccessMap) of
                {ok, ResolvedName} -> {var, ResolvedName};
                error -> {circuit_access, VarName, FieldName}
            end;
           ({K, {circuit_access, VarName, FieldName}}) ->
            case maps:find({VarName, FieldName}, AccessMap) of
                {ok, ResolvedName} -> {K, {var, ResolvedName}};
                error -> {K, {circuit_access, VarName, FieldName}}
            end;
           (Other) -> Other
        end,
        Args
    ).

resolve_access_typespecs(TSs, _AccessMap) ->
    TSs.

%%====================================================================
%% Helpers
%%====================================================================

build_circuit_map(Circuits) ->
    maps:from_list([{Def#gdbsp_circuit_def.name, Def} || Def <- Circuits]).

throw_fixpoint_error(Line, Msg) when is_list(Msg) ->
    throw({fixpoint_error, {Line, list_to_binary(Msg)}});
throw_fixpoint_error(Line, Msg) ->
    throw({fixpoint_error, {Line, Msg}}).

join_keys(Keys) ->
    Sorted = lists:sort(Keys),
    Parts = [key_to_bin(K) || K <- Sorted],
    iolist_to_binary(lists:join(<<", ">>, Parts)).

key_to_bin(K) when is_atom(K) -> atom_to_binary(K, utf8);
key_to_bin(K) when is_binary(K) -> K.
