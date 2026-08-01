%%%-------------------------------------------------------------------
%%% @doc Runtime aggregate functions — init, feed, result triples.
%%%
%%% Each aggregate overload has three functions:
%%%   init(PosExprs, KwExprs, Options) -> state()
%%%   feed(state(), row()) -> state()
%%%   result(state()) -> value()
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_agg).

-include("gdbsp_type.hrl").

%% ── xor ─────────────────────────────────────────────────────────────
-export([agg_xor_bytes_init/3, agg_xor_bytes_feed/2, agg_xor_bytes_result/1]).
-export([agg_xor_optional_bytes_init/3, agg_xor_optional_bytes_feed/2,
         agg_xor_optional_bytes_result/1]).
-export([bytewise_xor/2]).

%% ── sum ─────────────────────────────────────────────────────────────
-export([agg_sum_integer_init/3, agg_sum_integer_feed/2, agg_sum_integer_result/1]).
-export([agg_sum_f64_init/3, agg_sum_f64_feed/2, agg_sum_f64_result/1]).
-export([agg_sum_numeric_init/3, agg_sum_numeric_feed/2, agg_sum_numeric_result/1]).
-export([agg_sum_optional_integer_init/3, agg_sum_optional_integer_feed/2,
         agg_sum_optional_integer_result/1]).
-export([agg_sum_optional_f64_init/3, agg_sum_optional_f64_feed/2,
         agg_sum_optional_f64_result/1]).
-export([agg_sum_optional_numeric_init/3, agg_sum_optional_numeric_feed/2,
         agg_sum_optional_numeric_result/1]).

%% ── count ───────────────────────────────────────────────────────────
-export([agg_count_init/3, agg_count_feed/2, agg_count_result/1]).

%% ── min ─────────────────────────────────────────────────────────────
-export([agg_min_integer_init/3, agg_min_integer_feed/2, agg_min_integer_result/1]).
-export([agg_min_f64_init/3, agg_min_f64_feed/2, agg_min_f64_result/1]).
-export([agg_min_numeric_init/3, agg_min_numeric_feed/2, agg_min_numeric_result/1]).
-export([agg_min_optional_integer_init/3, agg_min_optional_integer_feed/2,
         agg_min_optional_integer_result/1]).
-export([agg_min_optional_f64_init/3, agg_min_optional_f64_feed/2,
         agg_min_optional_f64_result/1]).
-export([agg_min_optional_numeric_init/3, agg_min_optional_numeric_feed/2,
         agg_min_optional_numeric_result/1]).

%% ── max ─────────────────────────────────────────────────────────────
-export([agg_max_integer_init/3, agg_max_integer_feed/2, agg_max_integer_result/1]).
-export([agg_max_f64_init/3, agg_max_f64_feed/2, agg_max_f64_result/1]).
-export([agg_max_numeric_init/3, agg_max_numeric_feed/2, agg_max_numeric_result/1]).
-export([agg_max_optional_integer_init/3, agg_max_optional_integer_feed/2,
         agg_max_optional_integer_result/1]).
-export([agg_max_optional_f64_init/3, agg_max_optional_f64_feed/2,
         agg_max_optional_f64_result/1]).
-export([agg_max_optional_numeric_init/3, agg_max_optional_numeric_feed/2,
         agg_max_optional_numeric_result/1]).

%% ── avg ─────────────────────────────────────────────────────────────
-export([agg_avg_integer_init/3, agg_avg_integer_feed/2, agg_avg_integer_result/1]).
-export([agg_avg_f64_init/3, agg_avg_f64_feed/2, agg_avg_f64_result/1]).
-export([agg_avg_numeric_init/3, agg_avg_numeric_feed/2, agg_avg_numeric_result/1]).
-export([agg_avg_optional_integer_init/3, agg_avg_optional_integer_feed/2,
         agg_avg_optional_integer_result/1]).
-export([agg_avg_optional_f64_init/3, agg_avg_optional_f64_feed/2,
         agg_avg_optional_f64_result/1]).
-export([agg_avg_optional_numeric_init/3, agg_avg_optional_numeric_feed/2,
         agg_avg_optional_numeric_result/1]).

%% ── Operator-level functions ─────────────────────────────────────────
-export([agg_op_sum_init/2, agg_op_sum_update/3, agg_op_sum_result/1]).
-export([agg_op_count_init/2, agg_op_count_update/3, agg_op_count_result/1]).
-export([agg_op_min_init/2, agg_op_min_update/3, agg_op_min_result/1]).
-export([agg_op_max_init/2, agg_op_max_update/3, agg_op_max_result/1]).
-export([agg_op_xor_init/2, agg_op_xor_update/3, agg_op_xor_result/1]).

%%====================================================================
%% xor: bytes
%%====================================================================

agg_xor_bytes_init(PosExprs, _KwExprs, _Options) ->
    #{ck => col_key(PosExprs), acc => <<>>, first_len => undefined,
      consistent => true, seen => false}.

agg_xor_bytes_feed(#{consistent := false} = S, _Row) ->
    S;
agg_xor_bytes_feed(#{seen := false, ck := CK} = S, Row) ->
    {value, _, Bin} = gdbsp_struct:struct_get(Row, CK),
    S#{acc := Bin, first_len := byte_size(Bin), seen := true};
agg_xor_bytes_feed(#{ck := CK, acc := Acc, first_len := FL} = S, Row) ->
    {value, _, Bin} = gdbsp_struct:struct_get(Row, CK),
    case byte_size(Bin) of
        FL -> S#{acc := bytewise_xor(Acc, Bin)};
        _  -> S#{consistent := false}
    end.

agg_xor_bytes_result(#{consistent := false}) ->
    erlang:throw(drop_row);
agg_xor_bytes_result(#{acc := Acc}) ->
    {value, bytes, Acc}.

%%==== xor: nullable bytes =============================================

agg_xor_optional_bytes_init(PosExprs, _KwExprs, _Options) ->
    #{ck => col_key(PosExprs), acc => <<>>, first_len => undefined,
      consistent => true, seen => false}.

agg_xor_optional_bytes_feed(#{consistent := false} = S, _Row) ->
    S;
agg_xor_optional_bytes_feed(#{seen := false, ck := CK} = S, Row) ->
    {value, _, Bin} = gdbsp_struct:struct_get(Row, CK),
    case Bin of
        absent -> S;
        _ -> S#{acc := Bin, first_len := byte_size(Bin), seen := true}
    end;
agg_xor_optional_bytes_feed(#{ck := CK, acc := Acc, first_len := FL} = S, Row) ->
    {value, _, Bin} = gdbsp_struct:struct_get(Row, CK),
    case Bin of
        absent -> S;
        _ when byte_size(Bin) =:= FL ->
            S#{acc := bytewise_xor(Acc, Bin)};
        _ -> S#{consistent := false}
    end.

agg_xor_optional_bytes_result(#{consistent := false}) ->
    {value, {optional, bytes}, absent};
agg_xor_optional_bytes_result(#{seen := false}) ->
    {value, {optional, bytes}, absent};
agg_xor_optional_bytes_result(#{acc := Acc}) ->
    {value, {optional, bytes}, Acc}.

%%====================================================================
%% Internal — bytewise XOR (equal-length inputs required)
%%====================================================================

-spec bytewise_xor(binary(), binary()) -> binary().
bytewise_xor(A, B) ->
    list_to_binary([X bxor Y || {X, Y} <- lists:zip(binary_to_list(A), binary_to_list(B))]).

%%====================================================================
%% Common helpers
%%====================================================================

col_key([_ | _]) -> {value, string, <<"value">>};
col_key([]) -> {value, string, <<"value">>}.

%%====================================================================
%% sum: integer
%%====================================================================

agg_sum_integer_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), acc => 0}.

agg_sum_integer_feed(#{ck := CK, acc := A} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    S#{acc := A + V}.

agg_sum_integer_result(#{acc := A}) -> {value, integer, A}.

%%==== sum: f64 =======================================================

agg_sum_f64_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), acc => 0.0}.

agg_sum_f64_feed(#{ck := CK, acc := A} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    S#{acc := A + V}.

agg_sum_f64_result(#{acc := A}) -> {value, f64, A}.

%%==== sum: numeric ===================================================

agg_sum_numeric_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), acc => {0, 0}}.

agg_sum_numeric_feed(#{ck := CK, acc := A} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    S#{acc := decimal:add(A, V)}.

agg_sum_numeric_result(#{acc := A}) -> {value, numeric, A}.

%%==== sum: nullable integer =========================================

agg_sum_optional_integer_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), acc => 0, seen => false}.

agg_sum_optional_integer_feed(#{ck := CK, acc := A, seen := Seen} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> S;
        _ -> case Seen of
                 false -> S#{acc := V, seen := true};
                 true -> S#{acc := A + V}
             end
    end.

agg_sum_optional_integer_result(#{acc := A, seen := false}) ->
    {value, {optional, integer}, absent};
agg_sum_optional_integer_result(#{acc := A}) ->
    {value, {optional, integer}, A}.

%%==== sum: nullable f64 =============================================

agg_sum_optional_f64_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), acc => 0.0, seen => false}.

agg_sum_optional_f64_feed(#{ck := CK, acc := A, seen := Seen} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> S;
        _ -> case Seen of
                 false -> S#{acc := V, seen := true};
                 true -> S#{acc := A + V}
             end
    end.

agg_sum_optional_f64_result(#{acc := _A, seen := false}) ->
    {value, {optional, f64}, absent};
agg_sum_optional_f64_result(#{acc := A}) ->
    {value, {optional, f64}, A}.

%%==== sum: nullable numeric =========================================

agg_sum_optional_numeric_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), acc => {0, 0}, seen => false}.

agg_sum_optional_numeric_feed(#{ck := CK, acc := A, seen := Seen} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> S;
        _ -> case Seen of
                 false -> S#{acc := V, seen := true};
                 true -> S#{acc := decimal:add(A, V)}
             end
    end.

agg_sum_optional_numeric_result(#{acc := _A, seen := false}) ->
    {value, {optional, numeric}, absent};
agg_sum_optional_numeric_result(#{acc := A}) ->
    {value, {optional, numeric}, A}.

%%====================================================================
%% count
%%====================================================================

agg_count_init(_PosExprs, _KwExprs, _Options) ->
    #{count => 0}.

agg_count_feed(#{count := C} = S, _Row) ->
    S#{count := C + 1}.

agg_count_result(#{count := C}) -> {value, integer, C}.

%%====================================================================
%% min: integer
%%====================================================================

agg_min_integer_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined}.

agg_min_integer_feed(#{ck := CK, best := Best} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    NewBest = case Best of
        undefined -> V;
        _ when V < Best -> V;
        _ -> Best
    end,
    S#{best := NewBest}.

agg_min_integer_result(#{best := B}) -> {value, integer, B}.

%%==== min: f64 ======================================================

agg_min_f64_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined}.

agg_min_f64_feed(#{ck := CK, best := Best} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    NewBest = case Best of
        undefined -> V;
        _ when V < Best -> V;
        _ -> Best
    end,
    S#{best := NewBest}.

agg_min_f64_result(#{best := B}) -> {value, f64, B}.

%%==== min: numeric ==================================================

agg_min_numeric_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined}.

agg_min_numeric_feed(#{ck := CK, best := Best} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    NewBest = case Best of
        undefined -> V;
        _ -> case decimal:fast_cmp(V, Best) of
                 -1 -> V;
                 _ -> Best
             end
    end,
    S#{best := NewBest}.

agg_min_numeric_result(#{best := B}) -> {value, numeric, B}.

%%==== min: nullable integer =========================================

agg_min_optional_integer_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined, seen => false}.

agg_min_optional_integer_feed(#{ck := CK, best := Best, seen := Seen} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> S;
        _ -> NewBest = case Seen of
                 false -> V;
                 true -> case V < Best of true -> V; false -> Best end
             end,
             S#{best := NewBest, seen := true}
    end.

agg_min_optional_integer_result(#{seen := false}) ->
    {value, {optional, integer}, absent};
agg_min_optional_integer_result(#{best := B}) ->
    {value, {optional, integer}, B}.

%%==== min: nullable f64 =============================================

agg_min_optional_f64_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined, seen => false}.

agg_min_optional_f64_feed(#{ck := CK, best := Best, seen := Seen} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> S;
        _ -> NewBest = case Seen of
                 false -> V;
                 true -> case V < Best of true -> V; false -> Best end
             end,
             S#{best := NewBest, seen := true}
    end.

agg_min_optional_f64_result(#{seen := false}) ->
    {value, {optional, f64}, absent};
agg_min_optional_f64_result(#{best := B}) ->
    {value, {optional, f64}, B}.

%%==== min: nullable numeric =========================================

agg_min_optional_numeric_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined, seen => false}.

agg_min_optional_numeric_feed(#{ck := CK, best := Best, seen := Seen} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> S;
        _ -> NewBest = case Seen of
                 false -> V;
                 true -> case decimal:fast_cmp(V, Best) of -1 -> V; _ -> Best end
             end,
             S#{best := NewBest, seen := true}
    end.

agg_min_optional_numeric_result(#{seen := false}) ->
    {value, {optional, numeric}, absent};
agg_min_optional_numeric_result(#{best := B}) ->
    {value, {optional, numeric}, B}.

%%====================================================================
%% max: integer
%%====================================================================

agg_max_integer_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined}.

agg_max_integer_feed(#{ck := CK, best := Best} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    NewBest = case Best of
        undefined -> V;
        _ when V > Best -> V;
        _ -> Best
    end,
    S#{best := NewBest}.

agg_max_integer_result(#{best := B}) -> {value, integer, B}.

%%==== max: f64 ======================================================

agg_max_f64_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined}.

agg_max_f64_feed(#{ck := CK, best := Best} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    NewBest = case Best of
        undefined -> V;
        _ when V > Best -> V;
        _ -> Best
    end,
    S#{best := NewBest}.

agg_max_f64_result(#{best := B}) -> {value, f64, B}.

%%==== max: numeric ==================================================

agg_max_numeric_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined}.

agg_max_numeric_feed(#{ck := CK, best := Best} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    NewBest = case Best of
        undefined -> V;
        _ -> case decimal:fast_cmp(V, Best) of
                 1 -> V;
                 _ -> Best
             end
    end,
    S#{best := NewBest}.

agg_max_numeric_result(#{best := B}) -> {value, numeric, B}.

%%==== max: nullable integer =========================================

agg_max_optional_integer_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined, seen => false}.

agg_max_optional_integer_feed(#{ck := CK, best := Best, seen := Seen} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> S;
        _ -> NewBest = case Seen of
                 false -> V;
                 true -> case V > Best of true -> V; false -> Best end
             end,
             S#{best := NewBest, seen := true}
    end.

agg_max_optional_integer_result(#{seen := false}) ->
    {value, {optional, integer}, absent};
agg_max_optional_integer_result(#{best := B}) ->
    {value, {optional, integer}, B}.

%%==== max: nullable f64 =============================================

agg_max_optional_f64_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined, seen => false}.

agg_max_optional_f64_feed(#{ck := CK, best := Best, seen := Seen} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> S;
        _ -> NewBest = case Seen of
                 false -> V;
                 true -> case V > Best of true -> V; false -> Best end
             end,
             S#{best := NewBest, seen := true}
    end.

agg_max_optional_f64_result(#{seen := false}) ->
    {value, {optional, f64}, absent};
agg_max_optional_f64_result(#{best := B}) ->
    {value, {optional, f64}, B}.

%%==== max: nullable numeric =========================================

agg_max_optional_numeric_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), best => undefined, seen => false}.

agg_max_optional_numeric_feed(#{ck := CK, best := Best, seen := Seen} = S, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> S;
        _ -> NewBest = case Seen of
                 false -> V;
                 true -> case decimal:fast_cmp(V, Best) of 1 -> V; _ -> Best end
             end,
             S#{best := NewBest, seen := true}
    end.

agg_max_optional_numeric_result(#{seen := false}) ->
    {value, {optional, numeric}, absent};
agg_max_optional_numeric_result(#{best := B}) ->
    {value, {optional, numeric}, B}.

%%====================================================================
%% avg: integer → f64
%%====================================================================

agg_avg_integer_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), sum => 0, cnt => 0}.

agg_avg_integer_feed(#{ck := CK, sum := S0, cnt := C0} = St, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    St#{sum := S0 + V, cnt := C0 + 1}.

agg_avg_integer_result(#{cnt := 0}) ->
    erlang:throw(drop_row);
agg_avg_integer_result(#{sum := S, cnt := C}) ->
    {value, f64, S / C}.

%%==== avg: f64 → f64 ================================================

agg_avg_f64_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), sum => 0.0, cnt => 0}.

agg_avg_f64_feed(#{ck := CK, sum := S0, cnt := C0} = St, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    St#{sum := S0 + V, cnt := C0 + 1}.

agg_avg_f64_result(#{cnt := 0}) ->
    erlang:throw(drop_row);
agg_avg_f64_result(#{sum := S, cnt := C}) ->
    {value, f64, S / C}.

%%==== avg: numeric → numeric ========================================

agg_avg_numeric_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), sum => {0, 0}, cnt => 0}.

agg_avg_numeric_feed(#{ck := CK, sum := S0, cnt := C0} = St, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    St#{sum := decimal:add(S0, V), cnt := C0 + 1}.

agg_avg_numeric_result(#{cnt := 0}) ->
    erlang:throw(drop_row);
agg_avg_numeric_result(#{sum := S, cnt := C}) ->
    {value, numeric, decimal:divide(S, {C, 0},
        #{precision => 10, rounding => round_half_up})}.

%%==== avg: nullable integer → nullable f64 =========================

agg_avg_optional_integer_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), sum => 0, cnt => 0}.

agg_avg_optional_integer_feed(#{ck := CK, sum := S0, cnt := C0} = St, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> St;
        _ -> St#{sum := S0 + V, cnt := C0 + 1}
    end.

agg_avg_optional_integer_result(#{cnt := 0}) ->
    {value, {optional, f64}, absent};
agg_avg_optional_integer_result(#{sum := S, cnt := C}) ->
    {value, {optional, f64}, S / C}.

%%==== avg: nullable f64 → nullable f64 ==============================

agg_avg_optional_f64_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), sum => 0.0, cnt => 0}.

agg_avg_optional_f64_feed(#{ck := CK, sum := S0, cnt := C0} = St, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> St;
        _ -> St#{sum := S0 + V, cnt := C0 + 1}
    end.

agg_avg_optional_f64_result(#{cnt := 0}) ->
    {value, {optional, f64}, absent};
agg_avg_optional_f64_result(#{sum := S, cnt := C}) ->
    {value, {optional, f64}, S / C}.

%%==== avg: nullable numeric → nullable numeric ======================

agg_avg_optional_numeric_init(PosExprs, KwExprs, _Options) ->
    #{ck => col_key(PosExprs), sum => {0, 0}, cnt => 0}.

agg_avg_optional_numeric_feed(#{ck := CK, sum := S0, cnt := C0} = St, Row) ->
    {value, _, V} = gdbsp_struct:struct_get(Row, CK),
    case V of
        absent -> St;
        _ -> St#{sum := decimal:add(S0, V), cnt := C0 + 1}
    end.

agg_avg_optional_numeric_result(#{cnt := 0}) ->
    {value, {optional, numeric}, absent};
agg_avg_optional_numeric_result(#{sum := S, cnt := C}) ->
    {value, {optional, numeric}, decimal:divide(S, {C, 0},
        #{precision => 10, rounding => round_half_up})}.

%%====================================================================
%% Operator-level aggregate functions (weight-aware)
%%
%% Used by gdbsp_op_aggregate.erl. These operate on (Value, Weight)
%% pairs for incremental circuit execution. Init: V,W → Acc.
%% Update: Acc,V,W → Acc'. Result: Acc → Value | drop.
%%====================================================================

%% ── sum ───────────────────────────────────────────────────────────────

agg_op_sum_init(V, W) -> V * W.
agg_op_sum_update(A, V, W) -> A + V * W.
agg_op_sum_result(V) -> V.

%% ── count ─────────────────────────────────────────────────────────────

agg_op_count_init(_V, W) -> W.
agg_op_count_update(A, _V, W) -> A + W.
agg_op_count_result(V) -> V.

%% ── min ───────────────────────────────────────────────────────────────

agg_op_min_init(V, _W) -> V.
agg_op_min_update(A, V, _W) -> erlang:min(A, V).
agg_op_min_result(V) -> V.

%% ── max ───────────────────────────────────────────────────────────────

agg_op_max_init(V, _W) -> V.
agg_op_max_update(A, V, _W) -> erlang:max(A, V).
agg_op_max_result(V) -> V.

%% ── xor (bytes) ───────────────────────────────────────────────────────

agg_op_xor_init(V, _W) -> {byte_size(V), V}.
agg_op_xor_update({poisoned, _} = A, _V, _W) -> A;
agg_op_xor_update({Len, A}, V, _W) when byte_size(V) =:= Len ->
    {Len, bytewise_xor(A, V)};
agg_op_xor_update(_, _, _) -> {poisoned, none}.
agg_op_xor_result({poisoned, _}) -> drop;
agg_op_xor_result({_, A}) -> A.
