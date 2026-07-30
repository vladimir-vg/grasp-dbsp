%%%-------------------------------------------------------------------
%%% @doc GraphViz DOT generation for grasp-dbsp graph types.
%%%
%%% Converts `#lowered_graph{}` and `#circuit_graph{}` records
%%% to Graphviz DOT format strings. Output can be rendered with:
%%% ```
%%% dot -Tpng graph.dot -o graph.png
%%% dot -Tsvg graph.dot -o graph.svg
%%% ```
%%%
%%% Two separate function families — one per graph type:
%%%   lowered_to_dot/1, lowered_to_dot/2
%%%   circuit_to_dot/1, circuit_to_dot/2
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_graphviz).

-export([lowered_to_dot/1, lowered_to_dot/2,
         circuit_to_dot/1, circuit_to_dot/2]).

-include("gdbsp_lowered.hrl").
-include("gdbsp_circuit.hrl").

%%====================================================================
%% Lowered graph → DOT
%%====================================================================

-spec lowered_to_dot(#lowered_graph{}) -> iolist().
lowered_to_dot(#lowered_graph{} = LG) ->
    lowered_to_dot(LG, undefined).

-spec lowered_to_dot(#lowered_graph{}, string() | binary() | atom() | undefined) -> iolist().
lowered_to_dot(#lowered_graph{nodes = Nodes, fixpoints = Fixpoints}, Name) ->
    GraphName = case Name of
        undefined -> "lowered_graph";
        _ -> dot_str(Name)
    end,
    Label = case Name of
        undefined -> "Lowered DBSP Graph";
        _ -> dot_str(Name)
    end,
    [
        "digraph ", dot_label(GraphName), " {\n",
        "  rankdir=LR;\n",
        "  newrank=true;\n",
        "  label=", dot_label(Label), ";\n",
        "  node [fontname=\"monospace\", fontsize=10, shape=ellipse];\n",
        lowered_nodes_dot(Nodes),
        "\n",
        "  edge [color=grey50];\n",
        lowered_edges_dot(Nodes),
        lowered_fixpoint_legend(Fixpoints),
        "}\n"
    ].

%%--------------------------------------------------------------------
%% Lowered node rendering
%%--------------------------------------------------------------------

lowered_nodes_dot(Nodes) ->
    [lowered_node_dot(N) || {_, N} <- maps:to_list(Nodes)].

lowered_node_dot(#lnode{id = Id, op = Op, args = Args, tags = Tags}) ->
    Label = lowered_node_label(Op, Args, Tags),
    Color = lowered_node_color(Op),
    ["  ", dot_id(Id), " [label=", dot_label(Label),
     ", style=filled, fillcolor=", Color, "];\n"].

lowered_node_label(Op, Args, Tags) ->
    TagStr = case Tags of
        [T | _] -> binary_to_list(T);
        [] -> ""
    end,
    OpStr = atom_to_list(Op),
    Extra = lowered_node_extra(Op, Args),
    case TagStr of
        "" -> case Extra of
            "" -> ["(", OpStr, ")"];
            _ -> [OpStr, "\n", Extra]
        end;
        _ -> case Extra of
            "" -> [TagStr, "\n(", OpStr, ")"];
            _ -> [TagStr, "\n(", OpStr, " ", Extra, ")"]
        end
    end.

lowered_node_extra(source, Args) ->
    lowered_source_label(Args);
lowered_node_extra(map, Args) ->
    lowered_fn_label(Args);
lowered_node_extra(filter, Args) ->
    lowered_fn_label(Args);
lowered_node_extra(flat_map, Args) ->
    lowered_fn_label(Args);
lowered_node_extra(join, Args) ->
    lowered_on_label(Args);
lowered_node_extra(antijoin, Args) ->
    lowered_on_label(Args);
lowered_node_extra(project, Args) ->
    lowered_project_label(Args);
lowered_node_extra(aggregate, Args) ->
    lowered_agg_label(Args);
lowered_node_extra(fixpoint_input, Args) ->
    lowered_fp_boundary_label(Args);
lowered_node_extra(fixpoint_output, Args) ->
    lowered_fp_boundary_label(Args);
lowered_node_extra(_, _) ->
    "".

lowered_source_label(Args) ->
    case [S || {string, S} <- Args] of
        [T | _] -> binary_to_list(T);
        _ -> ""
    end.

lowered_fn_label(Args) ->
    Vars = [V || {var, V} <- Args],
    case Vars of
        [_, FnName | _] -> binary_to_list(FnName);
        _ -> ""
    end.

lowered_on_label(Args) ->
    case [F || {on, F} <- Args] of
        [[{string, _} | _] = Fields] ->
            Names = [binary_to_list(S) || {string, S} <- Fields],
            ["on: [", lists:join(", ", Names), "]"];
        [[F | _] = Fields] when is_binary(F) ->
            Names = [binary_to_list(S) || S <- Fields],
            ["on: [", lists:join(", ", Names), "]"];
        [B] when is_binary(B) ->
            ["on: ", binary_to_list(B)];
        _ -> ""
    end.

lowered_project_label(Args) ->
    case [L || L <- Args, is_list(L)] of
        [Fields] ->
            Names = [binary_to_list(F) || F <- Fields, is_binary(F)],
            ["[", lists:join(", ", Names), "]"];
        _ -> ""
    end.

lowered_agg_label(Args) ->
    FnName = case [V || {var, V} <- Args] of
        [_, Fn | _] -> binary_to_list(Fn);
        _ -> ""
    end,
    By = lowered_agg_by_label(Args),
    case By of
        "" -> FnName;
        _ -> case FnName of
            "" -> By;
            _ -> FnName ++ " " ++ By
        end
    end.

lowered_agg_by_label(Args) ->
    case [B || {by, B} <- Args] of
        [[{string, _} | _] = Fields] ->
            ["by: [", lists:join(", ", [binary_to_list(S) || {string, S} <- Fields]), "]"];
        [[B | _] = Fields] when is_binary(B) ->
            ["by: [", lists:join(", ", [binary_to_list(S) || S <- Fields]), "]"];
        [B] when is_binary(B) ->
            ["by: ", binary_to_list(B)];
        _ -> ""
    end.

lowered_fp_boundary_label(Args) ->
    case [S || {string, S} <- Args] of
        [P | _] -> binary_to_list(P);
        _ -> ""
    end.

lowered_node_color(source) -> "palegreen";
lowered_node_color(map) -> "lightyellow";
lowered_node_color(filter) -> "lightcoral";
lowered_node_color(flat_map) -> "lightgoldenrod";
lowered_node_color(neg) -> "thistle";
lowered_node_color(plus) -> "lightcyan";
lowered_node_color(join) -> "palegreen";
lowered_node_color(distinct) -> "lightsteelblue";
lowered_node_color(aggregate) -> "plum";
lowered_node_color(integrate) -> "lightblue";
lowered_node_color(differentiate) -> "lightsalmon";
lowered_node_color(delay) -> "lightgray";
lowered_node_color(antijoin) -> "lightsteelblue";
lowered_node_color(project) -> "lightgrey";
lowered_node_color(fixpoint_input) -> "lightblue";
lowered_node_color(fixpoint_output) -> "lightsalmon";
lowered_node_color(circuit_access) -> "lightcyan";
lowered_node_color(_) -> "white".

%%--------------------------------------------------------------------
%% Lowered edge rendering
%%--------------------------------------------------------------------

lowered_edges_dot(Nodes) ->
    maps:fold(
        fun(Id, #lnode{inputs = Inputs}, Acc) ->
            [lowered_node_edges(Id, Inputs) | Acc]
        end,
        [],
        Nodes).

lowered_node_edges(ConsumerId, Inputs) ->
    [[dot_id(In), " -> ", dot_id(ConsumerId), ";\n"] || In <- Inputs].

%%--------------------------------------------------------------------
%% Fixpoint legend
%%--------------------------------------------------------------------

lowered_fixpoint_legend(Fixpoints) when map_size(Fixpoints) =:= 0 ->
    [];
lowered_fixpoint_legend(Fixpoints) ->
    Lines = maps:fold(
        fun(_FpHmac, #{circuit_name := CName, tags := Tags}, Acc) ->
            TagStrs = [binary_to_list(T) || T <- Tags],
            [[io_lib:format("  // fixpoint: ~s (~s)~n",
                            [CName, lists:join(", ", TagStrs)])] | Acc]
        end,
        [],
        Fixpoints),
    ["\n", lists:reverse(Lines)].

%%====================================================================
%% Circuit graph → DOT
%%====================================================================

-spec circuit_to_dot(#circuit_graph{}) -> iolist().
circuit_to_dot(#circuit_graph{} = CG) ->
    circuit_to_dot(CG, undefined).

-spec circuit_to_dot(#circuit_graph{}, string() | binary() | atom() | undefined) -> iolist().
circuit_to_dot(#circuit_graph{nodes = Nodes, schemas = Schemas}, Name) ->
    GraphName = case Name of
        undefined -> "circuit_graph";
        _ -> dot_str(Name)
    end,
    Label = case Name of
        undefined -> "Circuit Graph";
        _ -> dot_str(Name)
    end,
    [
        "digraph ", dot_label(GraphName), " {\n",
        "  rankdir=LR;\n",
        "  newrank=true;\n",
        "  label=", dot_label(Label), ";\n",
        "  node [fontname=\"monospace\", fontsize=10, shape=ellipse];\n",
        circuit_nodes_dot(Nodes, Schemas),
        "\n",
        "  edge [color=grey50];\n",
        circuit_edges_dot(Nodes),
        "}\n"
    ].

%%--------------------------------------------------------------------
%% Circuit node rendering
%%--------------------------------------------------------------------

circuit_nodes_dot(Nodes, Schemas) ->
    [circuit_node_dot(N, Schemas) || {_, N} <- lists:sort(maps:to_list(Nodes))].

circuit_node_dot(#circuit_node{id = Id, op = Op, meta = Meta},
                 Schemas) ->
    Label = circuit_node_label(Op, Schemas, Id),
    Color = circuit_node_color(Op),
    SccComment = case maps:is_key(scc_body, Meta) of
        true -> ["  // scc_body\n"];
        false -> []
    end,
    [SccComment,
     "  ", dot_id(Id), " [label=", dot_label(Label),
     ", style=filled, fillcolor=", Color, "];\n"].

circuit_node_label({source, Name}, Schemas, Id) ->
    Schema = maps:get(Id, Schemas, []),
    ["source\n", binary_to_list(Name), circuit_schema_suffix(Schema)];
circuit_node_label({output, Name}, Schemas, Id) ->
    Schema = maps:get(Id, Schemas, []),
    ["output\n", binary_to_list(Name), circuit_schema_suffix(Schema)];
circuit_node_label({map, Spec}, _Schemas, _Id) ->
    Kind = maps:get(kind, Spec, unknown),
    case Kind of
        project ->
            Keep = maps:get(keep, Spec, []),
            ["map(project)\n[", lists:join(", ", [binary_to_list(K) || K <- Keep]), "]"];
        agg_unwrap ->
            Out = maps:get(output_var, Spec, <<>>),
            ["map(unwrap)\n", binary_to_list(Out)];
        _ ->
            "map"
    end;
circuit_node_label({filter, _}, _Schemas, _Id) -> "filter";
circuit_node_label({flat_map, Spec}, _Schemas, _Id) ->
    Unnest = maps:get(unnest_outs, Spec, []),
    case Unnest of
        [] -> "flat_map";
        _ -> ["flat_map\n+[", lists:join(", ", [binary_to_list(U) || U <- Unnest]), "]"]
    end;
circuit_node_label({neg}, _Schemas, _Id) -> "neg";
circuit_node_label({plus}, _Schemas, _Id) -> "plus";
circuit_node_label({map_index, Spec}, _Schemas, _Id) ->
    Keys = maps:get(key_vars, Spec, []),
    Vals = maps:get(val_vars, Spec, []),
    KeyStr = [binary_to_list(K) || K <- Keys],
    ValStr = [binary_to_list(V) || V <- Vals],
    case maps:is_key(agg_col, Spec) of
        true ->
            Agg = binary_to_list(maps:get(agg_col, Spec, <<>>)),
            ["map_index\nkey: [", lists:join(", ", KeyStr),
             "]\nagg: ", Agg];
        false ->
            ["map_index\nkey: [", lists:join(", ", KeyStr),
             "]\nval: [", lists:join(", ", ValStr), "]"]
    end;
circuit_node_label({join, Spec}, _Schemas, _Id) ->
    Shared = maps:get(shared_vars, Spec, []),
    ["join\n[", lists:join(", ", [binary_to_list(S) || S <- Shared]), "]"];
circuit_node_label({distinct}, _Schemas, _Id) -> "distinct";
circuit_node_label({aggregate, Name}, _Schemas, _Id) ->
    ["agg\n", binary_to_list(Name)];
circuit_node_label({integrate}, _Schemas, _Id) -> "I";
circuit_node_label({integrate, _}, _Schemas, _Id) -> "I(scc)";
circuit_node_label({differentiate}, _Schemas, _Id) -> "D";
circuit_node_label({delay}, _Schemas, _Id) -> "delay";
circuit_node_label({antijoin, Keys, Vals}, _Schemas, _Id) ->
    ["antijoin\n[", lists:join(", ", [binary_to_list(K) || K <- Keys]),
     "]\n[", lists:join(", ", [binary_to_list(V) || V <- Vals]), "]"];
circuit_node_label({rec, Name, SccId}, _Schemas, _Id) ->
    io_lib:format("rec(~s)\nscc: ~w", [Name, SccId]);
circuit_node_label({rec_output, Name, SccId}, _Schemas, _Id) ->
    io_lib:format("rec_out(~s)\nscc: ~w", [Name, SccId]).

circuit_schema_suffix([]) -> "";
circuit_schema_suffix(Schema) ->
    ["\n(", lists:join(", ", [binary_to_list(C) || C <- Schema]), ")"].

circuit_node_color({source, _}) -> "palegreen";
circuit_node_color({output, _}) -> "lightcoral";
circuit_node_color({map, _}) -> "lightyellow";
circuit_node_color({filter, _}) -> "lightcoral";
circuit_node_color({flat_map, _}) -> "lightgoldenrod";
circuit_node_color({neg}) -> "thistle";
circuit_node_color({plus}) -> "lightcyan";
circuit_node_color({map_index, _}) -> "lightyellow";
circuit_node_color({join, _}) -> "palegreen";
circuit_node_color({distinct}) -> "lightsteelblue";
circuit_node_color({aggregate, _}) -> "plum";
circuit_node_color({integrate}) -> "lightblue";
circuit_node_color({integrate, _}) -> "lightblue";
circuit_node_color({differentiate}) -> "lightsalmon";
circuit_node_color({delay}) -> "lightgray";
circuit_node_color({antijoin, _, _}) -> "lightsteelblue";
circuit_node_color({rec, _, _}) -> "lightgray";
circuit_node_color({rec_output, _, _}) -> "lightgray".

%%--------------------------------------------------------------------
%% Circuit edge rendering
%%--------------------------------------------------------------------

circuit_edges_dot(Nodes) ->
    maps:fold(
        fun(Id, #circuit_node{inputs = Inputs}, Acc) ->
            [circuit_node_edges(Id, Inputs) | Acc]
        end,
        [],
        Nodes).

circuit_node_edges(ConsumerId, [_ | _] = Inputs) ->
    [[dot_id(In), " -> ", dot_id(ConsumerId), ";\n"] || In <- Inputs];
circuit_node_edges(_ConsumerId, []) ->
    [].

%%====================================================================
%% DOT helpers
%%====================================================================

dot_id(Term) when is_integer(Term) ->
    integer_to_list(Term);
dot_id(Term) when is_list(Term) ->
    [$" | Term ++ "\""];
dot_id(Term) when is_binary(Term) ->
    Esc = dot_escape(binary_to_list(Term)),
    [$" | Esc ++ "\""];
dot_id(Term) when is_atom(Term) ->
    [$" | atom_to_list(Term) ++ "\""].

dot_label(Text) when is_binary(Text) ->
    Esc = dot_escape(binary_to_list(Text)),
    [$" | Esc ++ "\""];
dot_label(Text) when is_list(Text) ->
    Esc = dot_escape(Text),
    [$" | Esc ++ "\""].

dot_escape([]) -> [];
dot_escape([$" | Rest]) -> [$\\, $" | dot_escape(Rest)];
dot_escape([$\\ | Rest]) -> [$\\, $\\ | dot_escape(Rest)];
dot_escape([C | Rest]) -> [C | dot_escape(Rest)].

dot_str(Term) when is_list(Term) -> Term;
dot_str(Term) when is_binary(Term) -> binary_to_list(Term);
dot_str(Term) when is_atom(Term) -> atom_to_list(Term);
dot_str(_) -> "".
