%%%-------------------------------------------------------------------
%%% @doc Barrier-aware key-based grouping (flat ZSet → IndexedZSet).
%%%
%%% Single-upstream stateless pass-through. Extracts {Key, Value}
%%% from each row via Fun. Groups by Key, wraps as IndexedZSet entries
%%% with outer weight 1. Drops rows where fun returns {drop, _}.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_map_index).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").

-type op_state() :: #{
    'fun'      := fun((term()) -> {term(), term()}),
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{key_vars := KV, val_vars := VV}) ->
    KFn = key_extract_fn(KV),
    VFn = val_extract_fn(VV),
    init(#{'fun' => fun(Row) ->
        try {KFn(Row), VFn(Row)}
        catch throw:drop_row -> drop
        end
    end});
init(#{key_vars := KV, agg_row := _}) ->
    KFn = key_extract_fn(KV),
    init(#{'fun' => fun(Row) -> {KFn(Row), Row} end});
init(#{'fun' := Fun}) ->
    {#{'fun' => Fun, downstream_label => default}, [default], [default]}.


-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{'fun' := Fun, downstream_label := Label} = St, default,
             {delta, Meta, Deltas}) ->
    Indexed = [{1, {K, [{W, V}]}}
               || {W, Row} <- Deltas,
                  {K, V} <- [Fun(Row)],
                  K =/= drop],
    {St, gdbsp_operator_spec:maybe_emit(Label, Meta, Indexed)}.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.

%%--------------------------------------------------------------------
%% Symbolic spec → closure builders
%%--------------------------------------------------------------------

key_extract_fn([]) -> fun(_Row) -> <<"*">> end;
key_extract_fn([K]) -> field_extract_fn(K);
key_extract_fn(Keys) -> tuple_extract_fn(Keys).

val_extract_fn([]) -> fun(_Row) -> {} end;
val_extract_fn([V]) -> field_extract_fn(V);
val_extract_fn(Vals) -> tuple_extract_fn(Vals).

field_extract_fn(Var) ->
    fun({value, {struct, _, _}, TypedValues}) ->
        case maps:find(Var, TypedValues) of
            {ok, {value, _Type, Val}} -> Val;
            error -> erlang:throw(drop_row)
        end
    end.

tuple_extract_fn(Vars) ->
    fun({value, {struct, _, _}, TypedValues}) ->
        case lists:foldl(fun(V, Acc) ->
            case maps:find(V, TypedValues) of
                {ok, {value, _Type, Val}} -> [Val | Acc];
                error -> erlang:throw(drop_row)
            end
        end, [], Vars) of
            [] -> erlang:throw(drop_row);
            RevVals -> list_to_tuple(lists:reverse(RevVals))
        end
    end.
