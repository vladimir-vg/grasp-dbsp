%%%-------------------------------------------------------------------
%%% @doc Behavior specification and registry for all DBSP operators.
%%%
%%% Every operator implements three callbacks:
%%%
%%%   init(InitArgs :: map()) ->
%%%       {State :: term(), InLabels :: [term()], OutLabels :: [term()]}
%%%
%%%   handle_delta(State :: term(), Label :: term(),
%%%                {delta, Meta :: map(), Deltas :: [term()]}) ->
%%%       {State, [op_action()]}
%%%
%%%   merge_metas(#{Label :: term() => Meta :: map()}) -> map()
%%%
%%% Operators are pure — no process spawning, no message passing.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_operator_spec).

-include("gdbsp_op.hrl").
-include("gdbsp_circuit.hrl").

-callback init(InitArgs :: map()) -> {term(), [term()], [term()]}.

-callback handle_delta(term(), term(), {delta, map(), [term()]}) ->
    {term(), [op_action()]}.

-callback merge_metas(#{term() => map()}) -> map().

-export([lookup/1, lookup/2]).
-export([meta_for/2, deltas_of/2, merge_metas_consistent/1]).
-export([barrier_collect/5]).
-export([maybe_emit/3]).
-export([is_linear/1, needs_full_input/1, produces_full_output/1]).
-export([agg_init_update/1]).

%%--------------------------------------------------------------------
%% Operator registry
%%--------------------------------------------------------------------

%% @doc Look up the module implementing a given operator (core registry).
-spec lookup(atom()) -> {ok, module()} | {error, not_found}.
lookup(Atom) -> lookup(Atom, #{}).

%% @doc Registry override seam: consult an injected override/extra map
%% (atom => module) first, then fall back to the core clauses. gg-runtime
%% maps the core atoms to its checkpoint-capable gdbsp_op_* wrappers and
%% registers extra operators (aggregate, flat_map, trace, op_circuit).
-spec lookup(atom(), #{atom() => module()}) -> {ok, module()} | {error, not_found}.
lookup(Atom, Overrides) ->
    case Overrides of
        #{Atom := Mod} -> {ok, Mod};
        _              -> lookup_core(Atom)
    end.

-spec lookup_core(atom()) -> {ok, module()} | {error, not_found}.
lookup_core(map)            -> {ok, gdbsp_op_map};
lookup_core(filter)         -> {ok, gdbsp_op_filter};
lookup_core(neg)            -> {ok, gdbsp_op_neg};
lookup_core(plus)           -> {ok, gdbsp_op_plus};
lookup_core(map_index)      -> {ok, gdbsp_op_map_index};
lookup_core(integrate)      -> {ok, gdbsp_op_integrate};
lookup_core(distinct)       -> {ok, gdbsp_op_distinct};
lookup_core(join)           -> {ok, gdbsp_op_join};
lookup_core(differentiate)  -> {ok, gdbsp_op_differentiate};
lookup_core(antijoin)       -> {ok, gdbsp_op_antijoin};
lookup_core(aggregate)      -> {ok, gdbsp_op_aggregate};
lookup_core(delay)         -> {ok, gdbsp_op_delay};
lookup_core(flat_map)       -> {ok, gdbsp_op_flat_map};
lookup_core(_)              -> {error, not_found}.

%%====================================================================
%% Barrier helpers — shared between multi-input operator modules
%%====================================================================

-spec meta_for(#{term() => {delta, map(), [term()], term()}}, term()) -> map().
meta_for(Acc, Key) ->
    {delta, M, _, _} = maps:get(Key, Acc),
    M.

-spec deltas_of(#{term() => {delta, map(), [term()], term()}}, term()) -> [term()].
deltas_of(Acc, Key) ->
    {delta, _, D, _} = maps:get(Key, Acc),
    D.

-spec merge_metas_consistent(#{term() => map()}) -> map().
merge_metas_consistent(LabeledMetas) ->
    case lists:usort(maps:values(LabeledMetas)) of
        [Meta] -> Meta;
        _ -> error({meta_mismatch, LabeledMetas})
    end.

-spec barrier_collect(term(), term(), {delta, map(), [term()]}, term(), pos_integer()) ->
    {error, term()} | {ok, term(), #{term() => {delta, map(), [term()], term()}}} | {not_ready, term()}.
barrier_collect(St, Label, Msg, BS, N) ->
    case gdbsp_barrier:record(BS, Label, Msg) of
        {error, Reason} ->
            {error, Reason};
        {ok, BS2, Acc} ->
            case map_size(Acc) =:= N of
                false ->
                    {not_ready, St#{barrier := BS2}};
                true ->
                    {ok, St#{barrier := BS2}, Acc}
            end
    end.

%%====================================================================
%% Output emission helpers — shared between stateless single-input operators
%%====================================================================

-spec maybe_emit(term(), map(), [term()]) -> [op_action()].
maybe_emit(_Label, Meta, []) ->
    case maps:is_key(barrier, Meta) of
        true  -> [{send, _Label, {delta, Meta, []}}];
        false -> []
    end;
maybe_emit(Label, Meta, Deltas) -> [{send, Label, {delta, Meta, Deltas}}].

%%====================================================================
%% Operator classification — for compiler incrementalization pass
%%====================================================================

-spec is_linear({atom(), term()} | atom()) -> boolean().
is_linear({map, _})       -> true;
is_linear({filter, _})    -> true;
is_linear({flat_map, _})  -> true;
is_linear({neg})          -> true;
is_linear({plus})         -> true;
is_linear({map_index, _}) -> true;
is_linear({delay})        -> true;
is_linear({antijoin, _, _})   -> false;
is_linear(_)              -> false.

-spec needs_full_input({atom(), term()} | atom()) -> boolean().
needs_full_input({join, _})         -> true;
needs_full_input({distinct})        -> true;
needs_full_input({aggregate, _})    -> true;
needs_full_input({antijoin, _, _})  -> true;
needs_full_input(_)                 -> false.

-spec produces_full_output({atom(), term()} | atom()) -> boolean().
produces_full_output({join, _})         -> true;
produces_full_output({distinct})        -> true;
produces_full_output({aggregate, _})    -> true;
produces_full_output({antijoin, _, _})  -> true;
produces_full_output(_)                 -> false.

%%====================================================================
%% Aggregate init/update — used by runtime aggregate operator
%%====================================================================

-spec agg_init_update(atom()) ->
    {fun((term(), integer()) -> term()),
     fun((term(), term(), integer()) -> term()),
     fun((term()) -> term() | drop)}.
agg_init_update(sum) ->
    {fun(V, W) -> V * W end, fun(Acc, V, W) -> Acc + V * W end,
     fun(V) -> V end};
agg_init_update(count) ->
    {fun(_V, W) -> W end, fun(Acc, _V, W) -> Acc + W end,
     fun(V) -> V end};
agg_init_update(min) ->
    {fun(V, _W) -> V end, fun(Acc, V, _W) -> erlang:min(Acc, V) end,
     fun(V) -> V end};
agg_init_update(max) ->
    {fun(V, _W) -> V end, fun(Acc, V, _W) -> erlang:max(Acc, V) end,
     fun(V) -> V end};
agg_init_update('xor') ->
    {fun(V, _W) -> {byte_size(V), V} end,
     fun({poisoned, _} = Acc, _V, _W) -> Acc;
        ({Len, Acc}, V, _W) when byte_size(V) =:= Len ->
            {Len, try Acc bxor V
                  catch error:badarg -> error(xor_type_mismatch) end};
        (_, _, _) -> {poisoned, none}
     end,
     fun({poisoned, _}) -> drop;
        ({_, Acc}) -> Acc
     end};
agg_init_update(_) ->
    {fun(V, W) -> V * W end, fun(Acc, V, W) -> Acc + V * W end,
     fun(V) -> V end}.
