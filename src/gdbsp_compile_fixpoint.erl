%%%-------------------------------------------------------------------
%%% @doc Pre-processing pass: expands fixpoint calls.
%%%
%%% Trivial fixpoints (no self-referential params): macro expansion
%%% into inline operators.
%%%
%%% Self-referential fixpoints: body nodes emitted as standalone AST
%%% nodes with prefixed names. Synthetic fixpoint_rec placeholder nodes
%%% serve as Rec references for body operator wiring. The fixpoint node
%%% is preserved for the graph compiler to create Rec/Coord subgraphs.
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
    {OutNodes, NewAccMap} = expand_one_fixpoint(FpName, Args, L, CircuitMap, AccMap),
    {RestNodes, AccMap2} = expand_fixpoints(Rest, CircuitMap, NewAccMap),
    {OutNodes ++ RestNodes, AccMap2};
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
            BodyNodeNames = [N || #gdbsp_node_def{name = N} <- BodyNodes],
            SelfRefKw = find_self_ref_kws(Params, BodyNodeNames),
            case SelfRefKw of
                [] ->
                    expand_trivial(FpName, BodyNodes, Params, KwMap, AccMap, Line);
                _ ->
                    pass_through_fixpoint(FpName, Args, Line, CircuitName, Params, BodyNodes, KwMap, AccMap)
            end
    end.

find_self_ref_kws(Params, BodyNodeNames) ->
    maps:fold(
        fun(Kw, _Internal, Acc) ->
            KwBin = atom_to_binary(Kw, utf8),
            case lists:member(KwBin, BodyNodeNames) of
                true -> [Kw | Acc];
                false -> Acc
            end
        end,
        [],
        Params
    ).

%%--------------------------------------------------------------------
%% Trivial fixpoint — macro expansion
%%--------------------------------------------------------------------

expand_trivial(FpName, BodyNodes, Params, KwMap, AccMapIn, _Line) ->
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

%%--------------------------------------------------------------------
%% Self-referential fixpoint — emit body nodes + synthetic Rec-refs
%%--------------------------------------------------------------------

pass_through_fixpoint(FpName, Args, Line, _CircuitName, Params, BodyNodes, KwMap, AccMap) ->
    BodyNodeNames = [N || #gdbsp_node_def{name = N} <- BodyNodes],
    SelfRefKws = [Kw || Kw <- maps:keys(Params),
                        lists:member(atom_to_binary(Kw, utf8), BodyNodeNames)],
    Prefix = <<FpName/binary, "_">>,

    SubMap0 = maps:fold(
        fun(Kw, Internal, A) ->
            KwBin = atom_to_binary(Kw, utf8),
            case lists:member(KwBin, BodyNodeNames) of
                true ->
                    RecRefName = <<Prefix/binary, KwBin/binary, "_rec">>,
                    A#{Internal => {var, RecRefName}};
                false ->
                    case find_rec_ref_name(SelfRefKws, Prefix) of
                        undefined ->
                            ArgVal = maps:get(KwBin, KwMap, {var, <<>>}),
                            A#{Internal => ArgVal};
                        {var, _} = RecRef ->
                            A#{Internal => RecRef}
                    end
            end
        end,
        #{},
        Params
    ),

    BodyNameMap = maps:from_list(
        [{BN, {var, <<Prefix/binary, BN/binary>>}} || BN <- BodyNodeNames]),
    SubMap = maps:merge(SubMap0, BodyNameMap),

    {BodyEmitted, NewAccMap} = lists:foldl(
        fun(BodyNode, {NodesAcc, MapAcc}) ->
            #gdbsp_node_def{name = BodyName, op = BodyOp,
                            args = BodyArgs, line = BodyL} = BodyNode,
            Prefixed = <<Prefix/binary, BodyName/binary>>,
            NewArgs = dedup_rec_refs(substitute_params(BodyArgs, SubMap)),
            NewNode = #gdbsp_node_def{
                name = Prefixed, op = BodyOp, args = NewArgs, line = BodyL},
            NewMap = MapAcc#{{FpName, BodyName} => Prefixed},
            {[NewNode | NodesAcc], NewMap}
        end,
        {[], AccMap},
        BodyNodes
    ),

    KwArgsOnly = tl(Args),
    SourceRefs = lists:filtermap(
        fun({_, {var, SrcName}}) -> {true, {var, SrcName}};
           (_) -> false
        end, KwArgsOnly),
    DedupedSourceRefs = lists:usort(SourceRefs),
    RecRefNodes = lists:map(
        fun(Kw) ->
            KwBin = atom_to_binary(Kw, utf8),
            RecRefName = <<Prefix/binary, KwBin/binary, "_rec">>,
            #gdbsp_node_def{
                name = RecRefName,
                op = fixpoint_rec,
                args = DedupedSourceRefs,
                line = Line}
        end,
        SelfRefKws
    ),

    BodyNodeRefs = [{var, <<Prefix/binary, BN/binary>>} || BN <- BodyNodeNames],
    FixpointNode = #gdbsp_node_def{name = FpName, op = fixpoint,
                                    args = Args ++ SourceRefs ++ BodyNodeRefs, line = Line},

    AllNodes = lists:reverse(BodyEmitted) ++ RecRefNodes ++ [FixpointNode],
    {AllNodes, NewAccMap}.

find_rec_ref_name([], _Prefix) -> undefined;
find_rec_ref_name([Kw | _], Prefix) ->
    KwBin = atom_to_binary(Kw, utf8),
    RecRefName = <<Prefix/binary, KwBin/binary, "_rec">>,
    {var, RecRefName}.

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

dedup_rec_refs([{var, _} = First | Rest] = Args) ->
    case lists:all(fun(X) -> X =:= First end, Rest) of
        true -> [First];
        false -> lists:usort(Args)
    end;
dedup_rec_refs(Args) -> Args.

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
                            {true, #gdbsp_node_def{
                                name = Name,
                                op = circuit_access,
                                args = Args,
                                line = L}}
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
