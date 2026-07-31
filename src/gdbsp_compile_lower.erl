%%%-------------------------------------------------------------------
%%% @doc Lowering stage — transforms parsed #gdbsp_program{} into
%%% a content-addressed #lowered_graph{} with deduplication.
%%%
%%% Runs before type inference, before circuit graph construction.
%%% Handles:
%%%   - Node deduplication (content-addressing via sorted inputs)
%%%   - Fixpoint circuit expansion (trivial → inline; self-ref → boundary markers)
%%%   - circuit_access resolution (dot notation)
%%%   - Fixpoint body operator validation
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_lower).

-export([run/2]).

-include("gdbsp_parse.hrl").
-include("gdbsp_lowered.hrl").
-include("gdbsp_type.hrl").

-define(FORBIDDEN_IN_FIXPOINT, [aggregate, neg, antijoin]).

%%====================================================================
%% Public API
%%====================================================================

-spec run(#gdbsp_program{}, #{binary() => gdbsp_column_type()}) ->
    {ok, #lowered_graph{}} | {error, term()}.
run(Prog, TypeMap) ->
    try
        #gdbsp_program{nodes = Nodes, typespecs = TSs, circuits = Circuits} = Prog,
        ok = validate_circuit_bodies(Circuits),
        CircuitMap = build_circuit_map(Circuits),
        case build_name_table(Nodes, TSs, TypeMap) of
            {ok, NameTable} ->
                case topo_sort(NameTable) of
                    {ok, Order} ->
                        {ok, lower_nodes(NameTable, Order, CircuitMap, new_lg())};
                    {error, _} = Err -> Err
                end;
            {error, _} = Err -> Err
        end
    catch
        throw:{fixpoint_error, _} = FixErr ->
            {error, FixErr}
    end.

%%====================================================================
%% Circuit body validation
%%====================================================================

validate_circuit_bodies(Circuits) ->
    lists:foreach(
        fun(#gdbsp_circuit_def{name = CName, body = Body}) ->
            lists:foreach(
                fun(#gdbsp_node_def{name = N, op = Op, line = L}) ->
                    case lists:member(Op, ?FORBIDDEN_IN_FIXPOINT) of
                        true ->
                            throw_lower_error(L,
                                io_lib:format(
                                    "operator ~s is not allowed inside"
                                    " fixpoint circuit ~s (node ~s)",
                                    [Op, CName, N]));
                        false -> ok
                    end
                end, Body)
        end, Circuits).

build_circuit_map(Circuits) ->
    maps:from_list([{D#gdbsp_circuit_def.name, D} || D <- Circuits]).

%%====================================================================
%% Name table
%%====================================================================

-record(node_info, {
    name     :: binary(),
    op       :: atom(),
    args     :: list(),
    typespec :: gdbsp_column_type() | undefined,
    line     :: pos_integer()
}).

build_name_table(Nodes, TSs, TypeMap) ->
    TSMap = lists:foldl(
        fun(#gdbsp_typespec{name = N, spec = {type, {stream, Inner}}}, Acc) ->
                Acc#{N => Inner};
           (#gdbsp_typespec{name = N, spec = {type, T}}, Acc) ->
                Acc#{N => T};
           (_, Acc) -> Acc
        end, #{}, TSs),
    build_name_table(Nodes, TSMap, TypeMap, #{}, []).

build_name_table([], _TSMap, _TypeMap, Acc, _Order) ->
    {ok, Acc};
build_name_table([#gdbsp_node_def{name = N, op = Op, args = Args, line = L} | Rest],
                 TSMap, TypeMap, Acc, Order) ->
    case maps:is_key(N, Acc) of
        true -> {error, {duplicate_node, N}};
        false ->
            TS = case maps:find(N, TSMap) of
                {ok, T} -> T;
                error ->
                    case maps:find(N, TypeMap) of
                        {ok, T} -> T;
                        error -> undefined
                    end
            end,
            Info = #node_info{name = N, op = Op, args = Args, typespec = TS, line = L},
            build_name_table(Rest, TSMap, TypeMap, Acc#{N => Info}, [N | Order])
    end.

%%====================================================================
%% Topological sort
%%====================================================================

topo_sort(NameTable) ->
    InDeg = maps:map(fun(_N, Info) ->
        Refs = node_refs_from_args(Info#node_info.args, NameTable),
        case Info#node_info.op of
            delay ->
                length([R || R <- Refs, R =/= Info#node_info.name]);
            _ -> length(Refs)
        end
    end, NameTable),
    Consumers = build_consumers(NameTable),
    AllNames = maps:keys(NameTable),
    Queue = [N || N <- AllNames, maps:get(N, InDeg) =:= 0],
    topo_loop(queue:from_list(Queue), InDeg, Consumers, NameTable, []).

build_consumers(NameTable) ->
    lists:foldl(fun({N, Info}, Acc) ->
        Refs = node_refs_from_args(Info#node_info.args, NameTable),
        lists:foldl(fun(Ref, A) ->
            maps:update_with(Ref, fun(L) -> [N | L] end, [N], A)
        end, Acc, Refs)
    end, #{}, maps:to_list(NameTable)).

node_refs_from_args(Args, NameTable) ->
    lists:filtermap(fun
        ({var, Name}) when is_binary(Name) ->
            case maps:is_key(Name, NameTable) of true -> {true, Name}; false -> false end;
        ({circuit_access, Var, _Field}) when is_binary(Var) ->
            case maps:is_key(Var, NameTable) of true -> {true, Var}; false -> false end;
        ({_Kw, {var, Name}}) when is_binary(Name) ->
            case maps:is_key(Name, NameTable) of true -> {true, Name}; false -> false end;
        ({_Kw, {circuit_access, Var, _Field}}) ->
            case maps:is_key(Var, NameTable) of true -> {true, Var}; false -> false end;
        (_) -> false
    end, Args).

topo_loop(Queue, InDeg, Consumers, NameTable, Acc) ->
    case queue:out(Queue) of
        {empty, _} ->
            case length(Acc) =:= map_size(NameTable) of
                true -> {ok, lists:reverse(Acc)};
                false -> {error, cycle_in_graph}
            end;
        {{value, Name}, RestQ} ->
            NewAcc = [Name | Acc],
            Dependents = maps:get(Name, Consumers, []),
            {NewQ, NewIndeg} = lists:foldl(fun(Dep, {Q, ID}) ->
                NewD = maps:get(Dep, ID) - 1,
                ID2 = maps:put(Dep, NewD, ID),
                case NewD of
                    0 -> {queue:in(Dep, Q), ID2};
                    _ -> {Q, ID2}
                end
            end, {RestQ, InDeg}, Dependents),
            topo_loop(NewQ, NewIndeg, Consumers, NameTable, NewAcc)
    end.

%%====================================================================
%% Lowered graph construction
%%====================================================================

new_lg() -> #lowered_graph{}.

lower_nodes(NameTable, Order, CircuitMap, LG0) ->
    lists:foldl(
        fun(Name, LG) ->
            Info = maps:get(Name, NameTable),
            case Info#node_info.op of
                fixpoint ->
                    expand_fixpoint(Name, Info, CircuitMap, LG, NameTable);
                circuit_access ->
                    resolve_circuit_access(Name, Info, LG);
                _ ->
                    lower_regular_node(Name, Info, LG)
            end
        end,
        LG0,
        Order).

%%--------------------------------------------------------------------
%% Regular node lowering
%%--------------------------------------------------------------------

lower_regular_node(Name, Info, LG) ->
    #node_info{op = Op, args = Args, typespec = TS} = Info,
    Inputs = resolve_inputs(Args, LG#lowered_graph.tag_map),
    {NewLG, _NodeId} = add_node(Op, Inputs, Args, [Name], TS, LG),
    NewLG.

%%--------------------------------------------------------------------
%% circuit_access resolution
%%--------------------------------------------------------------------

resolve_circuit_access(Name, Info, LG) ->
    #node_info{args = Args, typespec = TS} = Info,
    case Args of
        [{var, Var}, {var, Field}] ->
            Tag = <<Var/binary, ".", Field/binary>>,
            case maps:find(Tag, LG#lowered_graph.tag_map) of
                {ok, ResolvedId} ->
                    {NewLG, _NodeId} = add_node(plus, [ResolvedId], [{var, Tag}], [Name], TS, LG),
                    NewLG;
                error ->
                    throw_lower_error(Info#node_info.line,
                        io_lib:format("unresolved circuit access: ~s.~s",
                                      [Var, Field]))
            end;
        _ ->
            throw_lower_error(Info#node_info.line,
                "invalid circuit_access args")
    end.

%%--------------------------------------------------------------------
%% Fixpoint expansion
%%--------------------------------------------------------------------

expand_fixpoint(Name, Info, CircuitMap, LG0, _NameTable) ->
    #node_info{args = Args, line = Line, name = FpName} = Info,
    [CircuitNameArg | KwArgs] = Args,
    CircuitName = case CircuitNameArg of
        {var, N} -> N;
        _ -> throw_lower_error(Line, "first fixpoint arg must be a circuit name")
    end,
    case maps:find(CircuitName, CircuitMap) of
        error ->
            throw_lower_error(Line,
                io_lib:format("unknown circuit: ~s", [CircuitName]));
        {ok, Def} ->
            #gdbsp_circuit_def{params = Params, body = BodyNodes} = Def,
            KwMap = build_kw_map(KwArgs, Line),
            ok = validate_fixpoint_args(Params, KwMap, CircuitName, Line),
            SelfRefKws = find_self_ref_kws(Params, BodyNodes),
            case SelfRefKws of
                [] ->
                    expand_trivial(FpName, BodyNodes, Params, KwMap, LG0, Line);
                _ ->
                    expand_selfref(FpName, Name, CircuitName, Params,
                                   BodyNodes, SelfRefKws, KwMap, LG0, Line)
            end
    end.

%%--------------------------------------------------------------------
%% Trivial fixpoint — inline macro expansion
%%--------------------------------------------------------------------

expand_trivial(FpName, BodyNodes, Params, KwMap, LG0, _Line) ->
    Prefix = <<FpName/binary, ".">>,
    InternalToArg = maps:fold(
        fun(Kw, Internal, A) ->
            A#{Internal => maps:get(Kw, KwMap)}
        end,
        #{},
        Params),
    lists:foldl(
        fun(#gdbsp_node_def{name = BodyName, op = BodyOp, args = BodyArgs},
            LG) ->
            Tag = <<Prefix/binary, BodyName/binary>>,
            SubstitutedArgs = substitute_params(BodyArgs, InternalToArg),
            Inputs = resolve_inputs(SubstitutedArgs, LG#lowered_graph.tag_map),
            {NewLG, _NodeId} = add_node(BodyOp, Inputs, SubstitutedArgs, [Tag], undefined, LG),
            NewLG
        end,
        LG0,
        BodyNodes).

%%--------------------------------------------------------------------
%% Self-referential fixpoint
%%--------------------------------------------------------------------

expand_selfref(_FpName, NodeName, CircuitName, Params, BodyNodes,
                SelfRefKws, KwMap, LG0, Line) ->
    FpHmac = fixpoint_hash(CircuitName, KwMap),

    ok = validate_selfref_distinct(BodyNodes, SelfRefKws, CircuitName, Line),

    Prefix = <<NodeName/binary, ".">>,

    {LG1, InputMap} = create_fixpoint_inputs(Params, KwMap, FpHmac, LG0, Line),

    %% Build substitution map: internal names → fixpoint_input node names.
    InternalNameMap = maps:fold(
        fun(Kw, Internal, A) ->
            KwBin = atom_to_binary(Kw, utf8),
            A#{Internal => {var, fixpoint_input_name(FpHmac, KwBin)},
               KwBin => {var, fixpoint_input_name(FpHmac, KwBin)}}
        end,
        #{},
        Params),

    %% Create body nodes
    {LG2, BodyIds} = lists:foldl(
        fun(#gdbsp_node_def{name = BN, op = BOp, args = BArgs}, {LG, BIds}) ->
            SubstitutedArgs = substitute_params(BArgs, InternalNameMap),
            Inputs = resolve_inputs(SubstitutedArgs, LG#lowered_graph.tag_map),
            {LG3, NodeId} = add_node(BOp, Inputs, SubstitutedArgs, [BN], undefined, LG),
            {LG3, BIds#{BN => NodeId}}
        end,
        {LG1, #{}},
        BodyNodes),

    %% Create fixpoint_output nodes for self-ref body outputs
    SelfRefKwBins = [atom_to_binary(K, utf8) || K <- SelfRefKws],
    {LG3, OutIdMap} = lists:foldl(
        fun(KwBin, {LG, Acc}) ->
            BodyOutId = maps:get(KwBin, BodyIds),
            Tag = <<Prefix/binary, KwBin/binary>>,
            {LGN, OutId} = add_node(fixpoint_output, [BodyOutId],
                                    [{string, KwBin}],
                                    [Tag], undefined, LG),
            {LGN, Acc#{KwBin => OutId}}
        end,
        {LG2, #{}},
        SelfRefKwBins),

    FixInfo = build_fixpoint_metadata(Params, SelfRefKws, InputMap, BodyIds,
                                       Prefix, CircuitName, NodeName),

    %% Add fixpoint_output tags to tag_map for external access
    LG4 = maps:fold(
        fun(KwBin, OutId, LGAcc) ->
            Tag = <<Prefix/binary, KwBin/binary>>,
            LGAcc#lowered_graph{tag_map = maps:put(Tag, OutId, LGAcc#lowered_graph.tag_map)}
        end,
        LG3,
        OutIdMap),

    LG4#lowered_graph{fixpoints = maps:put(FpHmac, FixInfo, LG4#lowered_graph.fixpoints)}.

%%--------------------------------------------------------------------
%% Fixpoint self-ref helpers
%%--------------------------------------------------------------------

-spec create_fixpoint_inputs(#{atom() => binary()}, map(),
                             fixpoint_hash(), #lowered_graph{},
                             pos_integer()) ->
    {#lowered_graph{}, #{binary() => lnode_id()}}.
create_fixpoint_inputs(Params, KwMap, FpHmac, LG, Line) ->
    lists:foldl(
        fun({Kw, Internal}, {LGAcc, AccById}) ->
            KwBin = atom_to_binary(Kw, utf8),
            case maps:find(Kw, KwMap) of
                {ok, {var, ExtName}} ->
                    resolve_fixpoint_input(ExtName, KwBin, FpHmac, Internal,
                                           LGAcc, AccById, Line);
                {ok, {circuit_access, Var, Field}} ->
                    ExtName = <<Var/binary, ".", Field/binary>>,
                    resolve_fixpoint_input(ExtName, KwBin, FpHmac, Internal,
                                           LGAcc, AccById, Line);
                _ ->
                    {LGAcc, AccById}
            end
        end,
        {LG, #{}},
        maps:to_list(Params)).

-spec resolve_fixpoint_input(binary(), binary(), fixpoint_hash(), binary(),
                              #lowered_graph{}, #{binary() => lnode_id()},
                              pos_integer()) ->
    {#lowered_graph{}, #{binary() => lnode_id()}}.
resolve_fixpoint_input(ExtName, KwBin, FpHmac, Internal, LGAcc, AccById, Line) ->
    case maps:find(ExtName, LGAcc#lowered_graph.tag_map) of
        {ok, ExtId} ->
            FpInName = fixpoint_input_name(FpHmac, KwBin),
            {LG2, InpId} = add_node(fixpoint_input, [ExtId],
                                    [{string, KwBin}, {fixpoint, FpHmac}],
                                    [], undefined, LGAcc),
            LG3 = register_internal_name(LG2, FpInName, InpId),
            {LG3, AccById#{Internal => InpId}};
        error ->
            throw_lower_error(Line,
                io_lib:format(
                    "unresolved fixpoint argument ~s for ~s",
                    [ExtName, KwBin]))
    end.

-spec build_fixpoint_metadata(#{atom() => binary()}, [atom()],
                               #{binary() => lnode_id()},
                               #{binary() => lnode_id()}, binary(),
                               binary(), binary()) -> fixpoint_info().
build_fixpoint_metadata(Params, SelfRefKws, InputMap, BodyIds, Prefix,
                         CircuitName, NodeName) ->
    ParamsInfo = maps:fold(
        fun(Kw, Internal, Acc) ->
            KwBin = atom_to_binary(Kw, utf8),
            Kind = case lists:member(Kw, SelfRefKws) of
                true -> self_ref;
                false -> base
            end,
            InputId = maps:get(Internal, InputMap),
            BodyOut = case Kind of
                self_ref -> maps:get(KwBin, BodyIds);
                base -> InputId
            end,
            Acc#{KwBin => #{
                kind => Kind,
                label => <<Prefix/binary, KwBin/binary>>,
                input => InputId,
                body_out => BodyOut
            }}
        end,
        #{},
        Params),
    #{
        circuit_name => CircuitName,
        tags => [NodeName],
        params => ParamsInfo
    }.

%%--------------------------------------------------------------------
%% Content-addressed node insertion
%%--------------------------------------------------------------------

add_node(Op, Inputs, Args, Tags, Type, LG) ->
    NonNodeArgs = nonnode_args_for_hash(Args, LG#lowered_graph.tag_map),
    Hash = content_hash(Op, Inputs, NonNodeArgs),
    case maps:find(Hash, LG#lowered_graph.nodes) of
        {ok, Existing} ->
            MergedTags = lists:usort(Tags ++ Existing#lnode.tags),
            Node = Existing#lnode{tags = MergedTags},
            LG2 = add_tags(LG, Tags, Hash),
            {LG2#lowered_graph{nodes = maps:put(Hash, Node, LG#lowered_graph.nodes)}, Hash};
        error ->
            Node = #lnode{
                id = Hash, op = Op, inputs = Inputs,
                args = Args, tags = Tags, type = Type},
            LG2 = add_tags(LG, Tags, Hash),
            {LG2#lowered_graph{nodes = maps:put(Hash, Node, LG#lowered_graph.nodes)}, Hash}
    end.

add_tags(LG, Tags, NodeId) ->
    TagMap2 = lists:foldl(
        fun(Tag, Acc) ->
            maps:put(Tag, NodeId, Acc)
        end,
        LG#lowered_graph.tag_map,
        Tags),
    LG#lowered_graph{tag_map = TagMap2}.

register_internal_name(LG, Name, NodeId) ->
    LG#lowered_graph{tag_map = maps:put(Name, NodeId, LG#lowered_graph.tag_map)}.

%%====================================================================
%% Content hashing
%%====================================================================

content_hash(Op, Inputs, NonNodeArgs) ->
    SortedInputs = lists:sort(Inputs),
    Bin = term_to_binary({Op, SortedInputs, NonNodeArgs}),
    integer_to_binary(erlang:phash2(Bin), 16).

fixpoint_hash(CircuitName, KwMap) ->
    SortedKws = lists:sort(
        lists:map(
            fun({K, V}) ->
                {K, case V of
                    {var, N} -> {var, N};
                    _ -> V
                end}
            end,
            maps:to_list(KwMap))),
    Bin = term_to_binary({fixpoint_call, CircuitName, SortedKws}),
    integer_to_binary(erlang:phash2(Bin), 16).

fixpoint_input_name(FpHmac, ParamBin) ->
    <<"@fp_in:", FpHmac/binary, ":", ParamBin/binary>>.

%%====================================================================
%% Input resolution
%%====================================================================

resolve_inputs(Args, TagMap) ->
    lists:filtermap(fun
        ({var, Name}) ->
            case maps:find(Name, TagMap) of
                {ok, Id} -> {true, Id};
                error -> false
            end;
        ({circuit_access, Var, Field}) ->
            Tag = <<Var/binary, ".", Field/binary>>,
            case maps:find(Tag, TagMap) of
                {ok, Id} -> {true, Id};
                error -> false
            end;
        ({_Kw, {var, Name}}) ->
            case maps:find(Name, TagMap) of
                {ok, Id} -> {true, Id};
                error -> false
            end;
        ({_Kw, {circuit_access, Var, Field}}) ->
            Tag = <<Var/binary, ".", Field/binary>>,
            case maps:find(Tag, TagMap) of
                {ok, Id} -> {true, Id};
                error -> false
            end;
        (_) -> false
    end, Args).

nonnode_args_for_hash(Args, TagMap) ->
    lists:filter(fun
        ({var, Name}) ->
            not maps:is_key(Name, TagMap);
        ({circuit_access, Var, Field}) ->
            Tag = <<Var/binary, ".", Field/binary>>,
            not maps:is_key(Tag, TagMap);
        ({_Kw, {var, _Name}}) -> false;
        (_) -> true
    end, Args).

%%====================================================================
%% Fixpoint helpers
%%====================================================================

build_kw_map(KwArgs, Line) ->
    maps:from_list(
        lists:map(
            fun({K, V}) -> {K, V};
               (Other) -> throw_lower_error(Line,
                   io_lib:format("expected keyword argument, got: ~p", [Other]))
            end,
            KwArgs)).

validate_fixpoint_args(Params, KwMap, _CircuitName, _Line) ->
    ParamKeys = maps:keys(Params),
    KwKeys = maps:keys(KwMap),
    Missing = ParamKeys -- KwKeys,
    case Missing of
        [] -> ok;
        _ -> throw_lower_error(_Line, io_lib:format(
            "missing arguments for circuit ~s: ~s",
            [_CircuitName, join_keys(Missing)]))
    end,
    Extra = KwKeys -- ParamKeys,
    case Extra of
        [] -> ok;
        _ -> throw_lower_error(_Line, io_lib:format(
            "unknown arguments for circuit ~s: ~s",
            [_CircuitName, join_keys(Extra)]))
    end.

find_self_ref_kws(Params, BodyNodes) ->
    BodyNodeNames = [N || #gdbsp_node_def{name = N} <- BodyNodes],
    maps:fold(
        fun(Kw, _Internal, Acc) ->
            KwBin = atom_to_binary(Kw, utf8),
            case lists:member(KwBin, BodyNodeNames) of
                true -> [Kw | Acc];
                false -> Acc
            end
        end,
        [],
        Params).

validate_selfref_distinct(BodyNodes, SelfRefKws, CircuitName, Line) ->
    BodyNodeMap = maps:from_list(
        [{N, D} || D = #gdbsp_node_def{name = N} <- BodyNodes]),
    lists:foreach(
        fun(Kw) ->
            KwBin = atom_to_binary(Kw, utf8),
            NodeDef = maps:get(KwBin, BodyNodeMap),
            case NodeDef#gdbsp_node_def.op of
                distinct -> ok;
                _ -> throw_lower_error(Line,
                    io_lib:format(
                        "self-referential node ~s in circuit ~s must be"
                        " wrapped in distinct",
                        [KwBin, CircuitName]))
            end
        end,
        SelfRefKws).

%%--------------------------------------------------------------------
%% Parameter substitution
%%--------------------------------------------------------------------

substitute_params(Args, SubMap) ->
    lists:map(
        fun({var, Name}) ->
            case maps:find(Name, SubMap) of
                {ok, Replacement} -> Replacement;
                error -> {var, Name}
            end;
           ({circuit_access, Var, Field}) ->
            Tag = <<Var/binary, ".", Field/binary>>,
            case maps:find(Tag, SubMap) of
                {ok, Replacement} -> Replacement;
                error -> {circuit_access, Var, Field}
            end;
           (Other) -> Other
        end,
        Args).

%%====================================================================
%% Error helpers
%%====================================================================

throw_lower_error(Line, Msg) when is_list(Msg) ->
    throw({fixpoint_error, {Line, list_to_binary(Msg)}});
throw_lower_error(Line, Msg) ->
    throw({fixpoint_error, {Line, Msg}}).

join_keys(Keys) ->
    Sorted = lists:sort(Keys),
    Parts = [key_to_bin(K) || K <- Sorted],
    iolist_to_binary(lists:join(<<", ">>, Parts)).

key_to_bin(K) when is_atom(K) -> atom_to_binary(K, utf8);
key_to_bin(K) when is_binary(K) -> K.
