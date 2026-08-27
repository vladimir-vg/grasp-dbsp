%%%-------------------------------------------------------------------
%%% @doc Weight-aware aggregate primitives for the aggregate operator.
%%%
%%% Each aggregate overload is an init/update/result MFA triple used by
%%% gdbsp_op_aggregate.erl, operating on (Value, Weight) pairs:
%%%   init(V, W)        -> Acc
%%%   update(Acc, V, W) -> Acc'
%%%   result(Acc)       -> Value | drop
%%%
%%% V is the evaluated slot-argument expression; W is the ZSet weight (an
%%% integer multiplicity). The per-key multiset passed to the fold is
%%% always net-positive.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_agg).

-include("gdbsp_type.hrl").

%% ── bytewise XOR helper ─────────────────────────────────────────────
-export([bytewise_xor/2]).

%% ── Operator-level aggregate functions (weight-aware) ───────────────
-export([agg_op_sum_init/2, agg_op_sum_update/3, agg_op_sum_result/1]).
-export([agg_op_sum_numeric_init/2, agg_op_sum_numeric_update/3,
         agg_op_sum_numeric_result/1]).
-export([agg_op_count_init/2, agg_op_count_update/3, agg_op_count_result/1]).
-export([agg_op_min_init/2, agg_op_min_update/3, agg_op_min_result/1]).
-export([agg_op_min_numeric_init/2, agg_op_min_numeric_update/3,
         agg_op_min_numeric_result/1]).
-export([agg_op_max_init/2, agg_op_max_update/3, agg_op_max_result/1]).
-export([agg_op_max_numeric_init/2, agg_op_max_numeric_update/3,
         agg_op_max_numeric_result/1]).
-export([agg_op_avg_integer_init/2, agg_op_avg_integer_update/3,
         agg_op_avg_integer_result/1]).
-export([agg_op_xor_init/2, agg_op_xor_update/3, agg_op_xor_result/1]).

%%====================================================================
%% bytewise XOR (equal-length inputs required)
%%====================================================================

-spec bytewise_xor(binary(), binary()) -> binary().
bytewise_xor(A, B) ->
    list_to_binary([X bxor Y || {X, Y} <- lists:zip(binary_to_list(A), binary_to_list(B))]).

%%====================================================================
%% sum
%%====================================================================

agg_op_sum_init(V, W) -> V * W.
agg_op_sum_update(A, V, W) -> A + V * W.
agg_op_sum_result(V) -> V.

%%==== sum: numeric ===================================================

agg_op_sum_numeric_init(V, W) -> decimal:mult(V, {W, 0}).
agg_op_sum_numeric_update(A, V, W) -> decimal:add(A, decimal:mult(V, {W, 0})).
agg_op_sum_numeric_result(V) -> V.

%%====================================================================
%% count
%%====================================================================

agg_op_count_init(_V, W) -> W.
agg_op_count_update(A, _V, W) -> A + W.
agg_op_count_result(V) -> V.

%%====================================================================
%% min
%%====================================================================

agg_op_min_init(V, W) -> #{V => W}.
agg_op_min_update(Acc, V, W) -> agg_op_add_weight(Acc, V, W).
agg_op_min_result(Acc) ->
    case [V || {V, W} <- maps:to_list(Acc), W > 0] of
        [] -> drop;
        Vs -> lists:min(Vs)
    end.

%%==== min: numeric ==================================================

agg_op_min_numeric_init(V, W) -> #{V => W}.
agg_op_min_numeric_update(Acc, V, W) -> agg_op_add_weight(Acc, V, W).
agg_op_min_numeric_result(Acc) ->
    case [V || {V, W} <- maps:to_list(Acc), W > 0] of
        [] -> drop;
        [H | T] -> lists:foldl(fun numeric_min/2, H, T)
    end.

numeric_min(V, Best) ->
    case decimal:fast_cmp(V, Best) of
        -1 -> V;
        _ -> Best
    end.

%%====================================================================
%% max
%%====================================================================

agg_op_max_init(V, W) -> #{V => W}.
agg_op_max_update(Acc, V, W) -> agg_op_add_weight(Acc, V, W).
agg_op_max_result(Acc) ->
    case [V || {V, W} <- maps:to_list(Acc), W > 0] of
        [] -> drop;
        Vs -> lists:max(Vs)
    end.

%%==== max: numeric ==================================================

agg_op_max_numeric_init(V, W) -> #{V => W}.
agg_op_max_numeric_update(Acc, V, W) -> agg_op_add_weight(Acc, V, W).
agg_op_max_numeric_result(Acc) ->
    case [V || {V, W} <- maps:to_list(Acc), W > 0] of
        [] -> drop;
        [H | T] -> lists:foldl(fun numeric_max/2, H, T)
    end.

numeric_max(V, Best) ->
    case decimal:fast_cmp(V, Best) of
        1 -> V;
        _ -> Best
    end.

agg_op_add_weight(Acc, V, W) ->
    W2 = maps:get(V, Acc, 0) + W,
    case W2 of
        0 -> maps:remove(V, Acc);
        _ -> Acc#{V => W2}
    end.

%%====================================================================
%% avg: integer (floor(sum / count), drops empty groups)
%%====================================================================

agg_op_avg_integer_init(V, W) -> #{sum => V * W, cnt => W}.
agg_op_avg_integer_update(#{sum := S, cnt := C}, V, W) ->
    #{sum => S + V * W, cnt => C + W}.
agg_op_avg_integer_result(#{cnt := 0}) -> drop;
agg_op_avg_integer_result(#{sum := S, cnt := C}) -> floor_div(S, C).

floor_div(S, C) ->
    Q = S div C,
    case S rem C of
        0 -> Q;
        R when R < 0 -> Q - 1;
        _ -> Q
    end.

%%====================================================================
%% xor (bytes)
%%
%% Bytewise XOR of a multiset of bytes values. XOR is self-inverse, so a
%% value with weight W contributes exactly once iff W is odd (an even W
%% cancels to nothing). Length mismatches poison the accumulator (drop).
%%====================================================================

agg_op_xor_init(V, W) ->
    {byte_size(V), xor_weight(<<>>, V, W)}.

agg_op_xor_update({poisoned, _} = A, _V, _W) ->
    A;
agg_op_xor_update({Len, A}, V, W) ->
    case byte_size(V) =:= Len of
        true -> {Len, xor_weight(A, V, W)};
        false -> {poisoned, none}
    end.

agg_op_xor_result({poisoned, _}) -> drop;
agg_op_xor_result({_, A}) -> A.

xor_weight(A, V, W) ->
    case W rem 2 of
        0 -> A;
        _ ->
            case A of
                <<>> -> V;
                _ -> bytewise_xor(A, V)
            end
    end.
