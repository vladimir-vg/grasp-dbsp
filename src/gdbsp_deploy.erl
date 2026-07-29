%%%-------------------------------------------------------------------
%%% @doc Pure deploy plan builder for the barrier-based DBSP circuit.
%%%
%%% Takes a compiled flat #circuit_graph{} and produces a deploy_plan() —
%%% a PID-free data structure containing wiring tuples and per-operator
%%% spawn configuration.
%%%
%%% The wiring uses typed refs with reference() for unique identity —
%%% just refs and labels.
%%%
%%% The deploy_plan is consumed by the proc layer to spawn processes
%%% and establish PID-level wiring.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_deploy).

-include("gdbsp_circuit.hrl").

-export([plan/1, plan/2, plan/3]).

%%====================================================================
%% Types
%%====================================================================

-type ref() ::
    {op, reference()} |
    {source, binary(), reference()} |
    {output, binary(), reference()}.

-type label() :: term().

-type routing_tuple() :: {
    ref(),   %% sender
    label(), %% sender output label
    ref(),   %% receiver
    label()  %% receiver input label
}.

-type operator_config() :: map().

-type deploy_plan() :: #{
    wiring  => [routing_tuple()],
    configs => #{ref() => operator_config()}
}.

-export_type([ref/0, routing_tuple/0, operator_config/0, deploy_plan/0]).

%%====================================================================
%% API
%%====================================================================

-spec plan(#circuit_graph{}) -> deploy_plan().
plan(Graph) ->
    plan(Graph, #{}, #{}).

%% @doc Registry override seam: Overrides (atom => module) is forwarded to
%% gdbsp_operator_spec:lookup/2, letting gg-runtime select wrapper / extra
%% operators per deployment. The basic dialect passes the empty map.
-spec plan(#circuit_graph{}, #{atom() => module()}) -> deploy_plan().
plan(Graph, Overrides) ->
    plan(Graph, Overrides, #{}).

%% @doc Value/leaf injection seam: Opts may carry `value => Module' (default
%% `gdbsp_value'), merged into every operator's init args as `value_mod'.
%% gg-runtime passes `#{value => gdbsp_value}' to run the full dialect.
-spec plan(#circuit_graph{}, #{atom() => module()}, map()) -> deploy_plan().
plan(#circuit_graph{nodes = Nodes}, Overrides, Opts) ->
    ValueMod = maps:get(value, Opts, gdbsp_value),
    RefMap = assign_refs(Nodes),
    Wiring = build_wiring_tuples(Nodes, RefMap),
    Configs = build_configs(Nodes, RefMap, Overrides, ValueMod),
    #{wiring => Wiring, configs => Configs}.

%%====================================================================
%% Ref assignment
%%====================================================================

-spec assign_refs(#{node_id() => #circuit_node{}}) ->
    #{node_id() => ref()}.
assign_refs(Nodes) ->
    maps:fold(
        fun(NodeId, #circuit_node{op = Op}, Acc) ->
            Ref = node_ref(Op),
            maps:put(NodeId, Ref, Acc)
        end,
        #{},
        Nodes
    ).

-spec node_ref(operator()) -> ref().
node_ref({source, Name})           -> {source, Name, make_ref()};
node_ref({output, Name})           -> {output, Name, make_ref()};
node_ref(_Op)                      -> {op, make_ref()}.

%%====================================================================
%% Wiring tuples
%%====================================================================

-spec build_wiring_tuples(#{node_id() => #circuit_node{}},
                           #{node_id() => ref()}) -> [routing_tuple()].
build_wiring_tuples(Nodes, RefMap) ->
    maps:fold(
        fun(NodeId, #circuit_node{op = Op, inputs = InputIds, meta = Meta}, Acc) ->
            ReceiverRef = maps:get(NodeId, RefMap),
            InputLabels = gdbsp_circuit:labels_for(Op, InputIds, Meta),
            Tuples = lists:zipwith(
                fun(InputId, InputLabel) ->
                    InputRef = maps:get(InputId, RefMap),
                    {InputRef, default, ReceiverRef, InputLabel}
                end,
                InputIds,
                gdbsp_circuit:pad_labels(InputIds, InputLabels)
            ),
            Tuples ++ Acc
        end,
        [],
        Nodes
    ).

%%====================================================================
%% Operator configs
%%====================================================================

-spec build_configs(#{node_id() => #circuit_node{}},
                     #{node_id() => ref()},
                     #{atom() => module()},
                     module()) -> #{ref() => operator_config()}.
build_configs(Nodes, RefMap, Overrides, ValueMod) ->
    maps:fold(
        fun(NodeId, #circuit_node{op = Op, inputs = InputIds, meta = Meta}, Acc) ->
            Ref = maps:get(NodeId, RefMap),
            case config_for(Op, InputIds, Ref, Meta, Overrides, ValueMod) of
                {ok, Config} -> maps:put(Ref, Config, Acc);
                skip -> Acc
            end
        end,
        #{},
        Nodes
    ).

-spec config_for(operator(), [node_id()], ref(), map(),
                 #{atom() => module()}, module()) ->
    {ok, operator_config()} | skip.
config_for({source, _}, _Inputs, _Ref, _Meta, _Overrides, _ValueMod) ->
    skip;
config_for({output, _}, _Inputs, _Ref, _Meta, _Overrides, _ValueMod) ->
    skip;
config_for(Op, Inputs, _Ref, Meta, Overrides, ValueMod) ->
    Atom = gdbsp_circuit:op_atom(Op),
    case gdbsp_operator_spec:lookup(Atom, Overrides) of
        {ok, Mod} ->
            Args = (gdbsp_circuit:op_args(Op, Inputs))#{value_mod => ValueMod},
            Labels = gdbsp_circuit:labels_for(Op, Inputs, Meta),
            {ok, #{mod => Mod, args => Args, labels => Labels}};
        {error, not_found} ->
            {ok, #{}}
    end.