-module(gdbsp_circuit).

-include("gdbsp_circuit.hrl").

-export([op_atom/1, op_args/2, labels_for/3, pad_labels/2]).

-spec op_atom(term()) -> atom().
op_atom({source, _})       -> source;
op_atom({output, _})       -> output;
op_atom({map, _})          -> map;
op_atom({filter, _})       -> filter;
op_atom({neg})             -> neg;
op_atom({plus})            -> plus;
op_atom({map_index, _})    -> map_index;
op_atom({integrate})       -> integrate;
op_atom({integrate, _})    -> integrate;
op_atom({distinct})        -> distinct;
op_atom({join, _})         -> join;
op_atom({differentiate})   -> differentiate;
op_atom({delay})           -> delay;
op_atom({antijoin, _, _})  -> antijoin;
op_atom({flat_map, _})     -> flat_map;
op_atom({aggregate, _})    -> aggregate;
op_atom({rec, _, _})       -> rec;
op_atom({rec_output, _, _}) -> rec_output;
op_atom(Op) when is_atom(Op) -> Op.

-spec op_args(term(), [term()]) -> map().
op_args({map, P}, _Inputs)          -> P;
op_args({filter, P}, _Inputs)       -> P;
op_args({neg}, _Inputs)               -> #{};
op_args({plus}, Inputs)               -> #{labels => input_labels(Inputs)};
op_args({map_index, Spec}, _Inputs) when is_map(Spec) ->
    Spec;
op_args({map_index, Fun}, _Inputs) when is_function(Fun) ->
    #{'fun' => Fun};
op_args({integrate}, _Inputs)         -> #{};
op_args({integrate, Args}, _Inputs)   -> Args;
op_args({distinct}, _Inputs)          -> #{};
op_args({join, Spec}, _Inputs) when is_map(Spec) ->
    Spec#{lhs_label => left, rhs_label => right, downstream => undefined};
op_args({join, Fun}, _Inputs) when is_function(Fun, 3) ->
    #{'fun' => Fun, lhs_label => left, rhs_label => right, downstream => undefined};
op_args({differentiate}, _Inputs)     -> #{};
op_args({antijoin, KeyVars, _LeftValVars}, _Inputs) ->
    #{key_vars => KeyVars, lhs_label => left, rhs_label => right};
op_args({flat_map, P}, _Inputs)       -> P;
op_args({aggregate, AggBin}, _Inputs) when is_binary(AggBin) ->
    #{function => AggBin};
op_args({aggregate, Plan}, _Inputs) when is_map(Plan) ->
    Plan;
op_args({rec, Name, SccId}, _Inputs) ->
    #{name => Name, scc_id => SccId};
op_args({rec_output, Name, SccId}, _Inputs) ->
    #{name => Name, scc_id => SccId};
op_args(_, _Inputs)                   -> #{}.

-spec input_labels([term()]) -> [atom() | {label, pos_integer()}].
input_labels(Inputs) ->
    case length(Inputs) of
        0 -> [];
        1 -> [default];
        2 -> [left, right];
        N -> [{label, I} || I <- lists:seq(1, N)]
    end.

%%====================================================================
%% Label assignment
%%====================================================================

-spec labels_for(operator(), [node_id()], map()) -> [term()].
labels_for({plus}, Inputs, _Meta) -> input_labels(Inputs);
labels_for({join, _}, _Inputs, _Meta) -> [left, right];
labels_for({antijoin, _, _}, _Inputs, _Meta) -> [left, right];
labels_for({rec, _, _}, Inputs, Meta) ->
    HasBodyOut = maps:get(has_body_out, Meta, false),
    N = length(Inputs),
    case N of
        0 -> [];
        1 when HasBodyOut -> [body_output];
        1 -> [source];
        _ when HasBodyOut ->
            lists:duplicate(N - 1, source) ++ [body_output];
        _ -> lists:duplicate(N, source)
    end;
labels_for({rec_output, _, _}, _Inputs, _Meta) -> [];
labels_for(_Op, Inputs, _Meta) -> input_labels(Inputs).

-spec pad_labels([term()], [term()]) -> [term()].
pad_labels(InputIds, [_ | _] = Labels) ->
    pad_labels_loop(InputIds, Labels, Labels);
pad_labels(InputIds, []) ->
    pad_labels_loop(InputIds, [], [default]).

pad_labels_loop([], _Labels, _Last) -> [];
pad_labels_loop([_ | IRest], [], Last) ->
    [hd(Last) | pad_labels_loop(IRest, [], Last)];
pad_labels_loop([_ | IRest], [L | LRest], Last) ->
    [L | pad_labels_loop(IRest, LRest, Last)].
