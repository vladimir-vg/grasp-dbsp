%%%-------------------------------------------------------------------
%%% @doc Runtime typed-value module — std: comparison operations.
%%%
%%% All functions return {value, ?BOOL, true|false}.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_std).

-include("gdbsp_type.hrl").

%% ── std: eq ─────────────────────────────────────────────────────────
-export([std_eq_i8_i8/2, std_eq_i16_i16/2, std_eq_i32_i32/2, std_eq_i64_i64/2]).
-export([std_eq_u8_u8/2, std_eq_u16_u16/2, std_eq_u32_u32/2, std_eq_u64_u64/2]).
-export([std_eq_integer_integer/2, std_eq_boolean_boolean/2, std_eq_absent_absent/2]).
-export([std_eq_string_string/2, std_eq_numeric_numeric/2]).
-export([std_eq_numeric_fixed_numeric_fixed/2]).
-export([std_eq_f64_f64/2, std_eq_f32_f32/2]).
-export([std_eq_bytes_bytes/2, std_eq_bits_bits/2]).
-export([std_eq_enum_enum/2, std_neq_enum_enum/2]).

%% ── std: neq ────────────────────────────────────────────────────────
-export([std_neq_i8_i8/2, std_neq_i16_i16/2, std_neq_i32_i32/2, std_neq_i64_i64/2]).
-export([std_neq_u8_u8/2, std_neq_u16_u16/2, std_neq_u32_u32/2, std_neq_u64_u64/2]).
-export([std_neq_integer_integer/2, std_neq_boolean_boolean/2, std_neq_absent_absent/2]).
-export([std_neq_string_string/2, std_neq_numeric_numeric/2]).
-export([std_neq_numeric_fixed_numeric_fixed/2]).
-export([std_neq_f64_f64/2, std_neq_f32_f32/2]).
-export([std_neq_bytes_bytes/2, std_neq_bits_bits/2]).

%% ── std: lt ─────────────────────────────────────────────────────────
-export([std_lt_i8_i8/2, std_lt_i16_i16/2, std_lt_i32_i32/2, std_lt_i64_i64/2]).
-export([std_lt_u8_u8/2, std_lt_u16_u16/2, std_lt_u32_u32/2, std_lt_u64_u64/2]).
-export([std_lt_integer_integer/2, std_lt_boolean_boolean/2, std_lt_absent_absent/2]).
-export([std_lt_string_string/2, std_lt_numeric_numeric/2]).
-export([std_lt_numeric_fixed_numeric_fixed/2]).
-export([std_lt_f64_f64/2, std_lt_f32_f32/2]).
-export([std_lt_bytes_bytes/2, std_lt_bits_bits/2]).

%% ── std: gt ─────────────────────────────────────────────────────────
-export([std_gt_i8_i8/2, std_gt_i16_i16/2, std_gt_i32_i32/2, std_gt_i64_i64/2]).
-export([std_gt_u8_u8/2, std_gt_u16_u16/2, std_gt_u32_u32/2, std_gt_u64_u64/2]).
-export([std_gt_integer_integer/2, std_gt_boolean_boolean/2, std_gt_absent_absent/2]).
-export([std_gt_string_string/2, std_gt_numeric_numeric/2]).
-export([std_gt_numeric_fixed_numeric_fixed/2]).
-export([std_gt_f64_f64/2, std_gt_f32_f32/2]).
-export([std_gt_bytes_bytes/2, std_gt_bits_bits/2]).

%% ── std: lte ────────────────────────────────────────────────────────
-export([std_lte_i8_i8/2, std_lte_i16_i16/2, std_lte_i32_i32/2, std_lte_i64_i64/2]).
-export([std_lte_u8_u8/2, std_lte_u16_u16/2, std_lte_u32_u32/2, std_lte_u64_u64/2]).
-export([std_lte_integer_integer/2, std_lte_boolean_boolean/2, std_lte_absent_absent/2]).
-export([std_lte_string_string/2, std_lte_numeric_numeric/2]).
-export([std_lte_numeric_fixed_numeric_fixed/2]).
-export([std_lte_f64_f64/2, std_lte_f32_f32/2]).
-export([std_lte_bytes_bytes/2, std_lte_bits_bits/2]).

%% ── std: gte ────────────────────────────────────────────────────────
-export([std_gte_i8_i8/2, std_gte_i16_i16/2, std_gte_i32_i32/2, std_gte_i64_i64/2]).
-export([std_gte_u8_u8/2, std_gte_u16_u16/2, std_gte_u32_u32/2, std_gte_u64_u64/2]).
-export([std_gte_integer_integer/2, std_gte_boolean_boolean/2, std_gte_absent_absent/2]).
-export([std_gte_string_string/2, std_gte_numeric_numeric/2]).
-export([std_gte_numeric_fixed_numeric_fixed/2]).
-export([std_gte_f64_f64/2, std_gte_f32_f32/2]).
-export([std_gte_bytes_bytes/2, std_gte_bits_bits/2]).

%% ── std: Logic ───────────────────────────────────────────────────────
-export([std_not_boolean/1]).
-export([std_and_boolean_boolean/2, std_or_boolean_boolean/2]).

%% ── std: Dynamic comparison ──────────────────────────────────────────
-export([std_eq_dynamic_dynamic/2, std_neq_dynamic_dynamic/2]).
-export([std_lt_dynamic_dynamic/2, std_gt_dynamic_dynamic/2]).
-export([std_le_dynamic_dynamic/2, std_ge_dynamic_dynamic/2]).

%% ── std: Type predicates ─────────────────────────────────────────────

%%====================================================================
%% std: eq
%%====================================================================

-spec std_eq_i8_i8(value(), value()) -> value().
std_eq_i8_i8({value, i8, A}, {value, i8, B}) -> {value, ?BOOL, A =:= B}.

-spec std_eq_i16_i16(value(), value()) -> value().
std_eq_i16_i16({value, i16, A}, {value, i16, B}) -> {value, ?BOOL, A =:= B}.

-spec std_eq_i32_i32(value(), value()) -> value().
std_eq_i32_i32({value, i32, A}, {value, i32, B}) -> {value, ?BOOL, A =:= B}.

-spec std_eq_i64_i64(value(), value()) -> value().
std_eq_i64_i64({value, i64, A}, {value, i64, B}) -> {value, ?BOOL, A =:= B}.

std_eq_u8_u8({value, u8, A}, {value, u8, B}) -> {value, ?BOOL, A =:= B}.
std_eq_u16_u16({value, u16, A}, {value, u16, B}) -> {value, ?BOOL, A =:= B}.
std_eq_u32_u32({value, u32, A}, {value, u32, B}) -> {value, ?BOOL, A =:= B}.
std_eq_u64_u64({value, u64, A}, {value, u64, B}) -> {value, ?BOOL, A =:= B}.
std_eq_integer_integer({value, integer, A}, {value, integer, B}) -> {value, ?BOOL, A =:= B};
std_eq_integer_integer({value, _, A}, {value, _, B}) when is_integer(A), is_integer(B) ->
    {value, ?BOOL, A =:= B}.
std_eq_boolean_boolean({value, ?BOOL, A}, {value, ?BOOL, B}) -> {value, ?BOOL, A =:= B}.
std_eq_absent_absent({value, absent, A}, {value, absent, B}) -> {value, ?BOOL, A =:= B}.
std_eq_string_string({value, T, A}, {value, T, B}) -> {value, ?BOOL, A =:= B}.

std_eq_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =:= 0}.

std_eq_numeric_fixed_numeric_fixed({value, {numeric, _, _}, A}, {value, {numeric, _, _}, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =:= 0}.

%%====================================================================
%% std: neq
%%====================================================================

-spec std_neq_i8_i8(value(), value()) -> value().
std_neq_i8_i8({value, i8, A}, {value, i8, B}) -> {value, ?BOOL, A =/= B}.

-spec std_neq_i16_i16(value(), value()) -> value().
std_neq_i16_i16({value, i16, A}, {value, i16, B}) -> {value, ?BOOL, A =/= B}.

-spec std_neq_i32_i32(value(), value()) -> value().
std_neq_i32_i32({value, i32, A}, {value, i32, B}) -> {value, ?BOOL, A =/= B}.

-spec std_neq_i64_i64(value(), value()) -> value().
std_neq_i64_i64({value, i64, A}, {value, i64, B}) -> {value, ?BOOL, A =/= B}.

std_neq_u8_u8({value, u8, A}, {value, u8, B}) -> {value, ?BOOL, A =/= B}.
std_neq_u16_u16({value, u16, A}, {value, u16, B}) -> {value, ?BOOL, A =/= B}.
std_neq_u32_u32({value, u32, A}, {value, u32, B}) -> {value, ?BOOL, A =/= B}.
std_neq_u64_u64({value, u64, A}, {value, u64, B}) -> {value, ?BOOL, A =/= B}.
std_neq_integer_integer({value, integer, A}, {value, integer, B}) -> {value, ?BOOL, A =/= B}.
std_neq_boolean_boolean({value, ?BOOL, A}, {value, ?BOOL, B}) -> {value, ?BOOL, A =/= B}.
std_neq_absent_absent({value, absent, A}, {value, absent, B}) -> {value, ?BOOL, A =/= B}.
std_neq_string_string({value, T, A}, {value, T, B}) -> {value, ?BOOL, A =/= B}.

std_neq_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =/= 0}.

std_neq_numeric_fixed_numeric_fixed({value, {numeric, _, _}, A}, {value, {numeric, _, _}, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =/= 0}.

%%====================================================================
%% std: lt
%%====================================================================

-spec std_lt_i8_i8(value(), value()) -> value().
std_lt_i8_i8({value, i8, A}, {value, i8, B}) -> {value, ?BOOL, A < B}.

-spec std_lt_i16_i16(value(), value()) -> value().
std_lt_i16_i16({value, i16, A}, {value, i16, B}) -> {value, ?BOOL, A < B}.

-spec std_lt_i32_i32(value(), value()) -> value().
std_lt_i32_i32({value, i32, A}, {value, i32, B}) -> {value, ?BOOL, A < B}.

-spec std_lt_i64_i64(value(), value()) -> value().
std_lt_i64_i64({value, i64, A}, {value, i64, B}) -> {value, ?BOOL, A < B}.

std_lt_u8_u8({value, u8, A}, {value, u8, B}) -> {value, ?BOOL, A < B}.
std_lt_u16_u16({value, u16, A}, {value, u16, B}) -> {value, ?BOOL, A < B}.
std_lt_u32_u32({value, u32, A}, {value, u32, B}) -> {value, ?BOOL, A < B}.
std_lt_u64_u64({value, u64, A}, {value, u64, B}) -> {value, ?BOOL, A < B}.
std_lt_integer_integer({value, integer, A}, {value, integer, B}) -> {value, ?BOOL, A < B}.
std_lt_boolean_boolean({value, ?BOOL, A}, {value, ?BOOL, B}) -> {value, ?BOOL, A < B}.
std_lt_absent_absent({value, absent, A}, {value, absent, B}) -> {value, ?BOOL, A < B}.
std_lt_string_string({value, T, A}, {value, T, B}) -> {value, ?BOOL, A < B}.

std_lt_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =:= -1}.

std_lt_numeric_fixed_numeric_fixed({value, {numeric, _, _}, A}, {value, {numeric, _, _}, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =:= -1}.

%%====================================================================
%% std: gt
%%====================================================================

-spec std_gt_i8_i8(value(), value()) -> value().
std_gt_i8_i8({value, i8, A}, {value, i8, B}) -> {value, ?BOOL, A > B}.

-spec std_gt_i16_i16(value(), value()) -> value().
std_gt_i16_i16({value, i16, A}, {value, i16, B}) -> {value, ?BOOL, A > B}.

-spec std_gt_i32_i32(value(), value()) -> value().
std_gt_i32_i32({value, i32, A}, {value, i32, B}) -> {value, ?BOOL, A > B}.

-spec std_gt_i64_i64(value(), value()) -> value().
std_gt_i64_i64({value, i64, A}, {value, i64, B}) -> {value, ?BOOL, A > B}.

std_gt_u8_u8({value, u8, A}, {value, u8, B}) -> {value, ?BOOL, A > B}.
std_gt_u16_u16({value, u16, A}, {value, u16, B}) -> {value, ?BOOL, A > B}.
std_gt_u32_u32({value, u32, A}, {value, u32, B}) -> {value, ?BOOL, A > B}.
std_gt_u64_u64({value, u64, A}, {value, u64, B}) -> {value, ?BOOL, A > B}.
std_gt_integer_integer({value, integer, A}, {value, integer, B}) -> {value, ?BOOL, A > B}.
std_gt_boolean_boolean({value, ?BOOL, A}, {value, ?BOOL, B}) -> {value, ?BOOL, A > B}.
std_gt_absent_absent({value, absent, A}, {value, absent, B}) -> {value, ?BOOL, A > B}.
std_gt_string_string({value, T, A}, {value, T, B}) -> {value, ?BOOL, A > B}.

std_gt_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =:= 1}.

std_gt_numeric_fixed_numeric_fixed({value, {numeric, _, _}, A}, {value, {numeric, _, _}, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =:= 1}.

%%====================================================================
%% std: lte
%%====================================================================

-spec std_lte_i8_i8(value(), value()) -> value().
std_lte_i8_i8({value, i8, A}, {value, i8, B}) -> {value, ?BOOL, A =< B}.

-spec std_lte_i16_i16(value(), value()) -> value().
std_lte_i16_i16({value, i16, A}, {value, i16, B}) -> {value, ?BOOL, A =< B}.

-spec std_lte_i32_i32(value(), value()) -> value().
std_lte_i32_i32({value, i32, A}, {value, i32, B}) -> {value, ?BOOL, A =< B}.

-spec std_lte_i64_i64(value(), value()) -> value().
std_lte_i64_i64({value, i64, A}, {value, i64, B}) -> {value, ?BOOL, A =< B}.

std_lte_u8_u8({value, u8, A}, {value, u8, B}) -> {value, ?BOOL, A =< B}.
std_lte_u16_u16({value, u16, A}, {value, u16, B}) -> {value, ?BOOL, A =< B}.
std_lte_u32_u32({value, u32, A}, {value, u32, B}) -> {value, ?BOOL, A =< B}.
std_lte_u64_u64({value, u64, A}, {value, u64, B}) -> {value, ?BOOL, A =< B}.
std_lte_integer_integer({value, integer, A}, {value, integer, B}) -> {value, ?BOOL, A =< B}.
std_lte_boolean_boolean({value, ?BOOL, A}, {value, ?BOOL, B}) -> {value, ?BOOL, A =< B}.
std_lte_absent_absent({value, absent, A}, {value, absent, B}) -> {value, ?BOOL, A =< B}.
std_lte_string_string({value, T, A}, {value, T, B}) -> {value, ?BOOL, A =< B}.

std_lte_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =/= 1}.

std_lte_numeric_fixed_numeric_fixed({value, {numeric, _, _}, A}, {value, {numeric, _, _}, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =/= 1}.

%%====================================================================
%% std: gte
%%====================================================================

-spec std_gte_i8_i8(value(), value()) -> value().
std_gte_i8_i8({value, i8, A}, {value, i8, B}) -> {value, ?BOOL, A >= B}.

-spec std_gte_i16_i16(value(), value()) -> value().
std_gte_i16_i16({value, i16, A}, {value, i16, B}) -> {value, ?BOOL, A >= B}.

-spec std_gte_i32_i32(value(), value()) -> value().
std_gte_i32_i32({value, i32, A}, {value, i32, B}) -> {value, ?BOOL, A >= B}.

-spec std_gte_i64_i64(value(), value()) -> value().
std_gte_i64_i64({value, i64, A}, {value, i64, B}) -> {value, ?BOOL, A >= B}.

std_gte_u8_u8({value, u8, A}, {value, u8, B}) -> {value, ?BOOL, A >= B}.
std_gte_u16_u16({value, u16, A}, {value, u16, B}) -> {value, ?BOOL, A >= B}.
std_gte_u32_u32({value, u32, A}, {value, u32, B}) -> {value, ?BOOL, A >= B}.
std_gte_u64_u64({value, u64, A}, {value, u64, B}) -> {value, ?BOOL, A >= B}.
std_gte_integer_integer({value, integer, A}, {value, integer, B}) -> {value, ?BOOL, A >= B}.
std_gte_boolean_boolean({value, ?BOOL, A}, {value, ?BOOL, B}) -> {value, ?BOOL, A >= B}.
std_gte_absent_absent({value, absent, A}, {value, absent, B}) -> {value, ?BOOL, A >= B}.
std_gte_string_string({value, T, A}, {value, T, B}) -> {value, ?BOOL, A >= B}.

std_gte_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =/= -1}.

std_gte_numeric_fixed_numeric_fixed({value, {numeric, _, _}, A}, {value, {numeric, _, _}, B}) ->
    {value, ?BOOL, decimal:fast_cmp(A, B) =/= -1}.

%%====================================================================
%% float: f64 comparison
%%====================================================================

-spec std_eq_f64_f64(value(), value()) -> value().
std_eq_f64_f64({value, f64, nan}, _) -> throw(drop_row);
std_eq_f64_f64(_, {value, f64, nan}) -> throw(drop_row);
std_eq_f64_f64({value, f64, infinity}, {value, f64, infinity}) -> {value, ?BOOL, true};
std_eq_f64_f64({value, f64, neg_infinity}, {value, f64, neg_infinity}) -> {value, ?BOOL, true};
std_eq_f64_f64({value, f64, infinity}, _) -> {value, ?BOOL, false};
std_eq_f64_f64(_, {value, f64, infinity}) -> {value, ?BOOL, false};
std_eq_f64_f64({value, f64, neg_infinity}, _) -> {value, ?BOOL, false};
std_eq_f64_f64(_, {value, f64, neg_infinity}) -> {value, ?BOOL, false};
std_eq_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A == B}.

-spec std_neq_f64_f64(value(), value()) -> value().
std_neq_f64_f64({value, f64, nan}, _) -> throw(drop_row);
std_neq_f64_f64(_, {value, f64, nan}) -> throw(drop_row);
std_neq_f64_f64({value, f64, infinity}, {value, f64, infinity}) -> {value, ?BOOL, false};
std_neq_f64_f64({value, f64, neg_infinity}, {value, f64, neg_infinity}) -> {value, ?BOOL, false};
std_neq_f64_f64({value, f64, infinity}, _) -> {value, ?BOOL, true};
std_neq_f64_f64(_, {value, f64, infinity}) -> {value, ?BOOL, true};
std_neq_f64_f64({value, f64, neg_infinity}, _) -> {value, ?BOOL, true};
std_neq_f64_f64(_, {value, f64, neg_infinity}) -> {value, ?BOOL, true};
std_neq_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A /= B}.

-spec std_lt_f64_f64(value(), value()) -> value().
std_lt_f64_f64({value, f64, nan}, _) -> throw(drop_row);
std_lt_f64_f64(_, {value, f64, nan}) -> throw(drop_row);
std_lt_f64_f64({value, f64, neg_infinity}, {value, f64, infinity}) -> {value, ?BOOL, true};
std_lt_f64_f64({value, f64, neg_infinity}, {value, f64, _}) -> {value, ?BOOL, true};
std_lt_f64_f64({value, f64, _}, {value, f64, neg_infinity}) -> {value, ?BOOL, false};
std_lt_f64_f64({value, f64, infinity}, {value, f64, _}) -> {value, ?BOOL, false};
std_lt_f64_f64({value, f64, _}, {value, f64, infinity}) -> {value, ?BOOL, true};
std_lt_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A < B}.

-spec std_gt_f64_f64(value(), value()) -> value().
std_gt_f64_f64({value, f64, nan}, _) -> throw(drop_row);
std_gt_f64_f64(_, {value, f64, nan}) -> throw(drop_row);
std_gt_f64_f64({value, f64, infinity}, {value, f64, neg_infinity}) -> {value, ?BOOL, true};
std_gt_f64_f64({value, f64, infinity}, {value, f64, _}) -> {value, ?BOOL, true};
std_gt_f64_f64({value, f64, _}, {value, f64, infinity}) -> {value, ?BOOL, false};
std_gt_f64_f64({value, f64, neg_infinity}, {value, f64, _}) -> {value, ?BOOL, false};
std_gt_f64_f64({value, f64, _}, {value, f64, neg_infinity}) -> {value, ?BOOL, true};
std_gt_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A > B}.

-spec std_lte_f64_f64(value(), value()) -> value().
std_lte_f64_f64({value, f64, nan}, _) -> throw(drop_row);
std_lte_f64_f64(_, {value, f64, nan}) -> throw(drop_row);
std_lte_f64_f64({value, f64, neg_infinity}, {value, f64, _}) -> {value, ?BOOL, true};
std_lte_f64_f64({value, f64, infinity}, {value, f64, infinity}) -> {value, ?BOOL, true};
std_lte_f64_f64({value, f64, infinity}, {value, f64, _}) -> {value, ?BOOL, false};
std_lte_f64_f64({value, f64, _}, {value, f64, infinity}) -> {value, ?BOOL, true};
std_lte_f64_f64({value, f64, _}, {value, f64, neg_infinity}) -> {value, ?BOOL, false};
std_lte_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A =< B}.

-spec std_gte_f64_f64(value(), value()) -> value().
std_gte_f64_f64({value, f64, nan}, _) -> throw(drop_row);
std_gte_f64_f64(_, {value, f64, nan}) -> throw(drop_row);
std_gte_f64_f64({value, f64, infinity}, {value, f64, _}) -> {value, ?BOOL, true};
std_gte_f64_f64({value, f64, _}, {value, f64, infinity}) -> {value, ?BOOL, false};
std_gte_f64_f64({value, f64, neg_infinity}, {value, f64, _}) -> {value, ?BOOL, false};
std_gte_f64_f64({value, f64, _}, {value, f64, neg_infinity}) -> {value, ?BOOL, true};
std_gte_f64_f64({value, f64, neg_infinity}, {value, f64, neg_infinity}) -> {value, ?BOOL, true};
std_gte_f64_f64({value, f64, infinity}, {value, f64, infinity}) -> {value, ?BOOL, true};
std_gte_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A >= B}.

%%====================================================================
%% float: f32 comparison
%%====================================================================

-spec std_eq_f32_f32(value(), value()) -> value().
std_eq_f32_f32({value, f32, nan}, _) -> throw(drop_row);
std_eq_f32_f32(_, {value, f32, nan}) -> throw(drop_row);
std_eq_f32_f32({value, f32, infinity}, {value, f32, infinity}) -> {value, ?BOOL, true};
std_eq_f32_f32({value, f32, neg_infinity}, {value, f32, neg_infinity}) -> {value, ?BOOL, true};
std_eq_f32_f32({value, f32, infinity}, _) -> {value, ?BOOL, false};
std_eq_f32_f32(_, {value, f32, infinity}) -> {value, ?BOOL, false};
std_eq_f32_f32({value, f32, neg_infinity}, _) -> {value, ?BOOL, false};
std_eq_f32_f32(_, {value, f32, neg_infinity}) -> {value, ?BOOL, false};
std_eq_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A == B}.

-spec std_neq_f32_f32(value(), value()) -> value().
std_neq_f32_f32({value, f32, nan}, _) -> throw(drop_row);
std_neq_f32_f32(_, {value, f32, nan}) -> throw(drop_row);
std_neq_f32_f32({value, f32, infinity}, {value, f32, infinity}) -> {value, ?BOOL, false};
std_neq_f32_f32({value, f32, neg_infinity}, {value, f32, neg_infinity}) -> {value, ?BOOL, false};
std_neq_f32_f32({value, f32, infinity}, _) -> {value, ?BOOL, true};
std_neq_f32_f32(_, {value, f32, infinity}) -> {value, ?BOOL, true};
std_neq_f32_f32({value, f32, neg_infinity}, _) -> {value, ?BOOL, true};
std_neq_f32_f32(_, {value, f32, neg_infinity}) -> {value, ?BOOL, true};
std_neq_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A /= B}.

-spec std_lt_f32_f32(value(), value()) -> value().
std_lt_f32_f32({value, f32, nan}, _) -> throw(drop_row);
std_lt_f32_f32(_, {value, f32, nan}) -> throw(drop_row);
std_lt_f32_f32({value, f32, neg_infinity}, {value, f32, infinity}) -> {value, ?BOOL, true};
std_lt_f32_f32({value, f32, neg_infinity}, {value, f32, _}) -> {value, ?BOOL, true};
std_lt_f32_f32({value, f32, _}, {value, f32, neg_infinity}) -> {value, ?BOOL, false};
std_lt_f32_f32({value, f32, infinity}, {value, f32, _}) -> {value, ?BOOL, false};
std_lt_f32_f32({value, f32, _}, {value, f32, infinity}) -> {value, ?BOOL, true};
std_lt_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A < B}.

-spec std_gt_f32_f32(value(), value()) -> value().
std_gt_f32_f32({value, f32, nan}, _) -> throw(drop_row);
std_gt_f32_f32(_, {value, f32, nan}) -> throw(drop_row);
std_gt_f32_f32({value, f32, infinity}, {value, f32, neg_infinity}) -> {value, ?BOOL, true};
std_gt_f32_f32({value, f32, infinity}, {value, f32, _}) -> {value, ?BOOL, true};
std_gt_f32_f32({value, f32, _}, {value, f32, infinity}) -> {value, ?BOOL, false};
std_gt_f32_f32({value, f32, neg_infinity}, {value, f32, _}) -> {value, ?BOOL, false};
std_gt_f32_f32({value, f32, _}, {value, f32, neg_infinity}) -> {value, ?BOOL, true};
std_gt_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A > B}.

-spec std_lte_f32_f32(value(), value()) -> value().
std_lte_f32_f32({value, f32, nan}, _) -> throw(drop_row);
std_lte_f32_f32(_, {value, f32, nan}) -> throw(drop_row);
std_lte_f32_f32({value, f32, neg_infinity}, {value, f32, _}) -> {value, ?BOOL, true};
std_lte_f32_f32({value, f32, infinity}, {value, f32, infinity}) -> {value, ?BOOL, true};
std_lte_f32_f32({value, f32, infinity}, {value, f32, _}) -> {value, ?BOOL, false};
std_lte_f32_f32({value, f32, _}, {value, f32, infinity}) -> {value, ?BOOL, true};
std_lte_f32_f32({value, f32, _}, {value, f32, neg_infinity}) -> {value, ?BOOL, false};
std_lte_f32_f32({value, f32, neg_infinity}, {value, f32, neg_infinity}) -> {value, ?BOOL, true};
std_lte_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A =< B}.

-spec std_gte_f32_f32(value(), value()) -> value().
std_gte_f32_f32({value, f32, nan}, _) -> throw(drop_row);
std_gte_f32_f32(_, {value, f32, nan}) -> throw(drop_row);
std_gte_f32_f32({value, f32, infinity}, {value, f32, _}) -> {value, ?BOOL, true};
std_gte_f32_f32({value, f32, _}, {value, f32, infinity}) -> {value, ?BOOL, false};
std_gte_f32_f32({value, f32, neg_infinity}, {value, f32, _}) -> {value, ?BOOL, false};
std_gte_f32_f32({value, f32, _}, {value, f32, neg_infinity}) -> {value, ?BOOL, true};
std_gte_f32_f32({value, f32, neg_infinity}, {value, f32, neg_infinity}) -> {value, ?BOOL, true};
std_gte_f32_f32({value, f32, infinity}, {value, f32, infinity}) -> {value, ?BOOL, true};
std_gte_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    {value, ?BOOL, A >= B}.

%%====================================================================
%% std: Logic
%%====================================================================

-spec std_not_boolean(value()) -> value().
std_not_boolean({value, ?BOOL, B}) -> {value, ?BOOL, not B}.

-spec std_and_boolean_boolean(value(), value()) -> value().
std_and_boolean_boolean({value, ?BOOL, A}, {value, ?BOOL, B}) ->
    {value, ?BOOL, A andalso B}.

-spec std_or_boolean_boolean(value(), value()) -> value().
std_or_boolean_boolean({value, ?BOOL, A}, {value, ?BOOL, B}) ->
    {value, ?BOOL, A orelse B}.

%%====================================================================
%% bytes comparison
%%====================================================================

-spec std_eq_bytes_bytes(value(), value()) -> value().
std_eq_bytes_bytes({value, T, A}, {value, T, B}) when T =:= bytes; is_tuple(T), element(1, T) =:= bytes ->
    {value, ?BOOL, A =:= B}.

-spec std_neq_bytes_bytes(value(), value()) -> value().
std_neq_bytes_bytes({value, T, A}, {value, T, B}) when T =:= bytes; is_tuple(T), element(1, T) =:= bytes ->
    {value, ?BOOL, A =/= B}.

-spec std_lt_bytes_bytes(value(), value()) -> value().
std_lt_bytes_bytes({value, T, A}, {value, T, B}) when T =:= bytes; is_tuple(T), element(1, T) =:= bytes ->
    {value, ?BOOL, A < B}.

-spec std_gt_bytes_bytes(value(), value()) -> value().
std_gt_bytes_bytes({value, T, A}, {value, T, B}) when T =:= bytes; is_tuple(T), element(1, T) =:= bytes ->
    {value, ?BOOL, A > B}.

-spec std_lte_bytes_bytes(value(), value()) -> value().
std_lte_bytes_bytes({value, T, A}, {value, T, B}) when T =:= bytes; is_tuple(T), element(1, T) =:= bytes ->
    {value, ?BOOL, A =< B}.

-spec std_gte_bytes_bytes(value(), value()) -> value().
std_gte_bytes_bytes({value, T, A}, {value, T, B}) when T =:= bytes; is_tuple(T), element(1, T) =:= bytes ->
    {value, ?BOOL, A >= B}.

%%====================================================================
%% bits comparison
%%====================================================================

-spec std_eq_bits_bits(value(), value()) -> value().
std_eq_bits_bits({value, T, A}, {value, T, B}) when T =:= bits; is_tuple(T), element(1, T) =:= bits ->
    {value, ?BOOL, A =:= B}.

-spec std_neq_bits_bits(value(), value()) -> value().
std_neq_bits_bits({value, T, A}, {value, T, B}) when T =:= bits; is_tuple(T), element(1, T) =:= bits ->
    {value, ?BOOL, A =/= B}.

-spec std_lt_bits_bits(value(), value()) -> value().
std_lt_bits_bits({value, T, A}, {value, T, B}) when T =:= bits; is_tuple(T), element(1, T) =:= bits ->
    {value, ?BOOL, A < B}.

-spec std_gt_bits_bits(value(), value()) -> value().
std_gt_bits_bits({value, T, A}, {value, T, B}) when T =:= bits; is_tuple(T), element(1, T) =:= bits ->
    {value, ?BOOL, A > B}.

-spec std_lte_bits_bits(value(), value()) -> value().
std_lte_bits_bits({value, T, A}, {value, T, B}) when T =:= bits; is_tuple(T), element(1, T) =:= bits ->
    {value, ?BOOL, A =< B}.

-spec std_gte_bits_bits(value(), value()) -> value().
std_gte_bits_bits({value, T, A}, {value, T, B}) when T =:= bits; is_tuple(T), element(1, T) =:= bits ->
    {value, ?BOOL, A >= B}.

%%====================================================================
%% Dynamic comparison — unwraps {value, dynamic, _} before comparing.
%% eq: same type and value → true.  neq: different type or value → true.
%% lt/gt/le/ge: same type → compare values; different type → false.
%%====================================================================

-spec unwrap_dyn(value()) -> term().
unwrap_dyn({value, {dynamic, T}, V}) -> {value, T, V};
unwrap_dyn(V) -> gdbsp_value:assert_value_tag(V).

-spec same_typed_value_kind(term(), term()) -> {ok, term(), term()} | false.
same_typed_value_kind({value, T1, A}, {value, T2, B}) ->
    case T1 =:= T2 of
        true  -> {ok, A, B};
        false -> false
    end;
same_typed_value_kind(_, _) ->
    false.

-spec std_eq_dynamic_dynamic(value(), value()) -> value().
std_eq_dynamic_dynamic(A, B) ->
    UA = unwrap_dyn(A), UB = unwrap_dyn(B),
    case same_typed_value_kind(UA, UB) of
        {ok, VA, VB} -> {value, ?BOOL, VA =:= VB};
        false -> {value, ?BOOL, false}
    end.

-spec std_neq_dynamic_dynamic(value(), value()) -> value().
std_neq_dynamic_dynamic(A, B) ->
    UA = unwrap_dyn(A), UB = unwrap_dyn(B),
    case same_typed_value_kind(UA, UB) of
        {ok, VA, VB} -> {value, ?BOOL, VA =/= VB};
        false -> {value, ?BOOL, true}
    end.

-spec std_lt_dynamic_dynamic(value(), value()) -> value().
std_lt_dynamic_dynamic(A, B) ->
    UA = unwrap_dyn(A), UB = unwrap_dyn(B),
    case same_typed_value_kind(UA, UB) of
        {ok, VA, VB} -> {value, ?BOOL, VA < VB};
        false -> {value, ?BOOL, false}
    end.

-spec std_gt_dynamic_dynamic(value(), value()) -> value().
std_gt_dynamic_dynamic(A, B) ->
    UA = unwrap_dyn(A), UB = unwrap_dyn(B),
    case same_typed_value_kind(UA, UB) of
        {ok, VA, VB} -> {value, ?BOOL, VA > VB};
        false -> {value, ?BOOL, false}
    end.

-spec std_ge_dynamic_dynamic(value(), value()) -> value().
std_ge_dynamic_dynamic(A, B) ->
    UA = unwrap_dyn(A), UB = unwrap_dyn(B),
    case same_typed_value_kind(UA, UB) of
        {ok, VA, VB} -> {value, ?BOOL, VA >= VB};
        false -> {value, ?BOOL, false}
    end.

-spec std_le_dynamic_dynamic(value(), value()) -> value().
std_le_dynamic_dynamic(A, B) ->
    UA = unwrap_dyn(A), UB = unwrap_dyn(B),
    case same_typed_value_kind(UA, UB) of
        {ok, VA, VB} -> {value, ?BOOL, VA =< VB};
        false -> {value, ?BOOL, false}
    end.


%%====================================================================
%% Generic enum comparison (catch-all for arbitrary enum types)
%%====================================================================

-spec std_eq_enum_enum(value(), value()) -> value().
std_eq_enum_enum({value, _, A}, {value, _, B}) -> {value, ?BOOL, A =:= B}.

-spec std_neq_enum_enum(value(), value()) -> value().
std_neq_enum_enum({value, _, A}, {value, _, B}) -> {value, ?BOOL, A =/= B}.
