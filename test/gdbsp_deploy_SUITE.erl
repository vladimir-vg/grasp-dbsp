%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_deploy — pure deploy plan building.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_deploy_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_circuit.hrl").

-export([all/0, groups/0]).
-export([
    plan_nonrec_single_rule/1,
    plan_pid_free/1,
    deploy_multi_aggregate_join_wiring/1
]).

all() -> [{group, deploy_parallel}].

groups() ->
      [{deploy_parallel, [parallel], [
          plan_nonrec_single_rule,
          plan_pid_free,
          deploy_multi_aggregate_join_wiring
      ]}].

%%====================================================================
%% Non-recursive: single rule — source → map → output
%%====================================================================

plan_nonrec_single_rule(_Config) ->
    Node1Id = 1,
    Node2Id = 2,
    Node3Id = 3,

    G = #circuit_graph{
        next_id = 4,
        nodes = #{
            Node1Id => #circuit_node{id = Node1Id, op = {source, <<"s">>}, inputs = [], meta = #{}},
            Node2Id => #circuit_node{id = Node2Id, op = {map, #{}},             inputs = [Node1Id], meta = #{}},
            Node3Id => #circuit_node{id = Node3Id, op = {output, <<"r">>},      inputs = [Node2Id], meta = #{}}
        },
        schemas = #{}
    },
    #{wiring := Wiring, configs := Configs} = gdbsp_deploy:plan(G),

    true = length(Wiring) >= 1,
    true = map_size(Configs) >= 1,
    true = maps:fold(fun(_, #{mod := _}, Acc) -> Acc; (_, _, _) -> false end, true, Configs).

%%====================================================================
%% PID-free check: no pid() values anywhere in the deploy plan
%%====================================================================

plan_pid_free(_Config) ->
    Node1Id = 1,
    Node2Id = 2,
    Node3Id = 3,

    G = #circuit_graph{
        next_id = 4,
        nodes = #{
            Node1Id => #circuit_node{id = Node1Id, op = {source, <<"s">>},  inputs = [], meta = #{}},
            Node2Id => #circuit_node{id = Node2Id, op = {map, #{}},              inputs = [Node1Id], meta = #{}},
            Node3Id => #circuit_node{id = Node3Id, op = {output, <<"r">>},       inputs = [Node2Id], meta = #{}}
        },
        schemas = #{}
    },
    Plan = gdbsp_deploy:plan(G),

    Pids = find_pids(Plan),
    [] = Pids.

%%====================================================================
%% Multi-rule join wiring — two map_index nodes feed a join,
%% with an output downstream. Verifies the join operator in the
%% deploy plan has correct labels and wiring connections.
%%====================================================================

deploy_multi_aggregate_join_wiring(_Config) ->
    NodeSrc    = 1,
    NodeAgg1   = 2,
    NodeAgg2   = 3,
    NodeJoin   = 4,
    NodeOut    = 5,

    Graph = #circuit_graph{
        next_id = 6,
        nodes = #{
            NodeSrc    => #circuit_node{id = NodeSrc,  op = {source, <<"emp">>},      inputs = [],           meta = #{}},
            NodeAgg1   => #circuit_node{id = NodeAgg1, op = {map_index, #{}},          inputs = [NodeSrc],    meta = #{}},
            NodeAgg2   => #circuit_node{id = NodeAgg2, op = {map_index, #{}},          inputs = [NodeSrc],    meta = #{}},
            NodeJoin   => #circuit_node{id = NodeJoin, op = {join, #{}},              inputs = [NodeAgg1, NodeAgg2], meta = #{}},
            NodeOut    => #circuit_node{id = NodeOut,  op = {output, <<"stats">>},     inputs = [NodeJoin],   meta = #{}}
        },
        schemas = #{}
    },
    #{wiring := Wiring, configs := Configs} = gdbsp_deploy:plan(Graph),

    JoinRefs = [Ref || {Ref, #{mod := Mod}} <- maps:to_list(Configs),
                       Mod =:= gdbsp_op_join],
    1 = length(JoinRefs),
    [JoinRef] = JoinRefs,

    #{lhs_label := _, rhs_label := _} = maps:get(args, maps:get(JoinRef, Configs)),

    JoinInputs = [{Snd, RcvLbl} || {Snd, _, Rcv, RcvLbl} <- Wiring,
                                    Rcv =:= JoinRef],
    2 = length(JoinInputs),

    JoinDownstream = [{Rcv, Lbl} || {Snd, _, Rcv, Lbl} <- Wiring,
                                     Snd =:= JoinRef],
    true = length(JoinDownstream) >= 1,

    StatsReceivers = [Rcv || {_, _, Rcv, _} <- Wiring,
                              is_tuple(Rcv), tuple_size(Rcv) >= 2,
                              element(1, Rcv) =:= output,
                              element(2, Rcv) =:= <<"stats">>],
    true = length(StatsReceivers) >= 1.

%%====================================================================
%% Helpers
%%====================================================================

find_pids(Term) ->
    find_pids(Term, []).

find_pids(Term, Acc) when is_pid(Term) ->
    [Term | Acc];
find_pids(Term, Acc) when is_list(Term) ->
    lists:foldl(fun find_pids/2, Acc, Term);
find_pids(Term, Acc) when is_tuple(Term) ->
    lists:foldl(fun find_pids/2, Acc, tuple_to_list(Term));
find_pids(Term, Acc) when is_map(Term) ->
    lists:foldl(fun find_pids/2, Acc, maps:values(Term));
find_pids(_, Acc) ->
    Acc.
