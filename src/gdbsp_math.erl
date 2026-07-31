%%%-------------------------------------------------------------------
%%% @doc Runtime typed-value module — math: arithmetic operations.
%%%
%%% Covers integer (wrapping), float (IEEE 754), and numeric (decimal)
%%% arithmetic.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_math).

-include("gdbsp_type.hrl").

%% ── Macros ──────────────────────────────────────────────────────────

-define(SIGNED_BINOP(Fn, Op, Type, Bits),
    Fn({value, Type, A}, {value, Type, B}) ->
        {value, Type, wrap_signed(A Op B, Bits)}).

-define(UNSIGNED_BINOP(Fn, Op, Type, Bits),
    Fn({value, Type, A}, {value, Type, B}) ->
        {value, Type, wrap_unsigned(A Op B, Bits)}).

-define(SIGNED_DIVMOD(Fn, Op, Type),
    Fn({value, Type, _A}, {value, Type, 0}) -> throw(drop_row);
    Fn({value, Type, A}, {value, Type, B}) ->
        {value, Type, A Op B}).

-define(UNSIGNED_DIVMOD(Fn, Op, Type),
    Fn({value, Type, _A}, {value, Type, 0}) -> throw(drop_row);
    Fn({value, Type, A}, {value, Type, B}) ->
        {value, Type, A Op B}).

%% ── math: Binary Arithmetic ─────────────────────────────────────────
-export([math_add_i8_i8/2, math_add_i16_i16/2, math_add_i32_i32/2, math_add_i64_i64/2]).
-export([math_add_u8_u8/2, math_add_u16_u16/2, math_add_u32_u32/2, math_add_u64_u64/2]).
-export([math_add_integer_integer/2]).
-export([math_add_numeric_numeric/2, math_add_numeric_fixed_numeric_fixed/2]).
-export([math_add_f64_f64/2, math_add_f32_f32/2]).
-export([math_sub_i8_i8/2, math_sub_i16_i16/2, math_sub_i32_i32/2, math_sub_i64_i64/2]).
-export([math_sub_u8_u8/2, math_sub_u16_u16/2, math_sub_u32_u32/2, math_sub_u64_u64/2]).
-export([math_sub_integer_integer/2]).
-export([math_sub_numeric_numeric/2, math_sub_numeric_fixed_numeric_fixed/2]).
-export([math_sub_f64_f64/2, math_sub_f32_f32/2]).
-export([math_mul_i8_i8/2, math_mul_i16_i16/2, math_mul_i32_i32/2, math_mul_i64_i64/2]).
-export([math_mul_u8_u8/2, math_mul_u16_u16/2, math_mul_u32_u32/2, math_mul_u64_u64/2]).
-export([math_mul_integer_integer/2]).
-export([math_mul_numeric_numeric/2, math_mul_numeric_fixed_numeric_fixed/2]).
-export([math_mul_f64_f64/2, math_mul_f32_f32/2]).
-export([math_div_i8_i8/2, math_div_i16_i16/2, math_div_i32_i32/2, math_div_i64_i64/2]).
-export([math_div_u8_u8/2, math_div_u16_u16/2, math_div_u32_u32/2, math_div_u64_u64/2]).
-export([math_div_integer_integer/2]).
-export([math_div_numeric_numeric/2, math_div_numeric_fixed_numeric_fixed/2]).
-export([math_div_f64_f64/2, math_div_f32_f32/2]).
-export([math_mod_i8_i8/2, math_mod_i16_i16/2, math_mod_i32_i32/2, math_mod_i64_i64/2]).
-export([math_mod_u8_u8/2, math_mod_u16_u16/2, math_mod_u32_u32/2, math_mod_u64_u64/2]).
-export([math_mod_integer_integer/2]).

%% ── math: Unary Arithmetic ──────────────────────────────────────────
-export([math_neg_integer/1, math_neg_f64/1]).
-export([math_abs_integer/1, math_abs_f64/1]).
-export([math_sign_integer/1, math_sign_f64/1]).

%% ── float: Detection ────────────────────────────────────────────────
-export([math_is_nan_f64/1, math_is_nan_f32/1]).
-export([math_is_infinite_f64/1, math_is_infinite_f32/1]).
-export([math_is_finite_f64/1, math_is_finite_f32/1]).

%% ── math: Exponentials and Constants ────────────────────────────────
-export([math_pow_f64_f64/2]).
-export([math_sqrt_f64/1, math_ln_f64/1, math_log10_f64/1]).
-export([math_log_value_base/2, math_pi/0]).

%% ── math: Rounding ──────────────────────────────────────────────────
-export([math_ceil_f64/1, math_floor_f64/1, math_round_f64/1]).

%% ── math: Trigonometry ──────────────────────────────────────────────
-export([math_sin_f64/1, math_cos_f64/1, math_tan_f64/1]).
-export([math_asin_f64/1, math_acos_f64/1, math_atan_f64/1]).
-export([math_atan2_f64_f64/2]).

%% ── math: Array Statistics ───────────────────────────────────────────
-export([math_min_array/1, math_max_array/1]).

%%====================================================================
%% math: Binary Arithmetic — add
%%====================================================================

%% -spec for each signed variant: math_add_T_T(value(), value()) -> value().
?SIGNED_BINOP(math_add_i8_i8, +, i8, 8).
?SIGNED_BINOP(math_add_i16_i16, +, i16, 16).
?SIGNED_BINOP(math_add_i32_i32, +, i32, 32).
?SIGNED_BINOP(math_add_i64_i64, +, i64, 64).

?UNSIGNED_BINOP(math_add_u8_u8, +, u8, 8).
?UNSIGNED_BINOP(math_add_u16_u16, +, u16, 16).
?UNSIGNED_BINOP(math_add_u32_u32, +, u32, 32).
?UNSIGNED_BINOP(math_add_u64_u64, +, u64, 64).

math_add_integer_integer({value, integer, A}, {value, integer, B}) ->
    {value, integer, A + B};
math_add_integer_integer({value, _, A}, {value, _, B}) when is_integer(A), is_integer(B) ->
    {value, integer, A + B}.

math_add_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    {value, numeric, decimal:add(A, B)}.

math_add_numeric_fixed_numeric_fixed({value, {numeric, P, S}, A}, {value, {numeric, P, S}, B}) ->
    Sum = decimal:add(A, B),
    case gdbsp_value:decimal_fits_precision(Sum, P, S) of
        true  -> {value, {numeric, P, S}, Sum};
        false -> throw(drop_row)
    end.

%% -- f64 add --

-spec math_add_f64_f64(value(), value()) -> value().
math_add_f64_f64({value, f64, nan}, _) -> {value, f64, nan};
math_add_f64_f64(_, {value, f64, nan}) -> {value, f64, nan};
math_add_f64_f64({value, f64, infinity}, {value, f64, neg_infinity}) -> {value, f64, nan};
math_add_f64_f64({value, f64, neg_infinity}, {value, f64, infinity}) -> {value, f64, nan};
math_add_f64_f64({value, f64, infinity}, {value, f64, _}) -> {value, f64, infinity};
math_add_f64_f64({value, f64, _}, {value, f64, infinity}) -> {value, f64, infinity};
math_add_f64_f64({value, f64, neg_infinity}, {value, f64, _}) -> {value, f64, neg_infinity};
math_add_f64_f64({value, f64, _}, {value, f64, neg_infinity}) -> {value, f64, neg_infinity};
math_add_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    try A + B of
        R when is_float(R) -> {value, f64, R}
    catch
        error:badarith ->
            if A >= 0.0, B >= 0.0 -> {value, f64, infinity};
               A =< 0.0, B =< 0.0 -> {value, f64, neg_infinity};
               true -> {value, f64, infinity}
            end
    end.

%% -- f32 add --

-spec math_add_f32_f32(value(), value()) -> value().
math_add_f32_f32({value, f32, nan}, _) -> {value, f32, nan};
math_add_f32_f32(_, {value, f32, nan}) -> {value, f32, nan};
math_add_f32_f32({value, f32, infinity}, {value, f32, neg_infinity}) -> {value, f32, nan};
math_add_f32_f32({value, f32, neg_infinity}, {value, f32, infinity}) -> {value, f32, nan};
math_add_f32_f32({value, f32, infinity}, {value, f32, _}) -> {value, f32, infinity};
math_add_f32_f32({value, f32, _}, {value, f32, infinity}) -> {value, f32, infinity};
math_add_f32_f32({value, f32, neg_infinity}, {value, f32, _}) -> {value, f32, neg_infinity};
math_add_f32_f32({value, f32, _}, {value, f32, neg_infinity}) -> {value, f32, neg_infinity};
math_add_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    try A + B of
        R when is_float(R) ->
            try
                Coerced = gdbsp_value:coerce_f32(R),
                {value, f32, Coerced}
            catch
                error:badarith ->
                    if R > 0.0 -> {value, f32, infinity};
                       R < 0.0 -> {value, f32, neg_infinity};
                       true -> {value, f32, nan}
                    end
            end
    catch
        error:badarith ->
            if A >= 0.0, B >= 0.0 -> {value, f32, infinity};
               A =< 0.0, B =< 0.0 -> {value, f32, neg_infinity};
               true -> {value, f32, infinity}
            end
    end.

%%====================================================================
%% math: Binary Arithmetic — sub
%%====================================================================

%% -spec for each signed variant: math_sub_T_T(value(), value()) -> value().
?SIGNED_BINOP(math_sub_i8_i8, -, i8, 8).
?SIGNED_BINOP(math_sub_i16_i16, -, i16, 16).
?SIGNED_BINOP(math_sub_i32_i32, -, i32, 32).
?SIGNED_BINOP(math_sub_i64_i64, -, i64, 64).

?UNSIGNED_BINOP(math_sub_u8_u8, -, u8, 8).
?UNSIGNED_BINOP(math_sub_u16_u16, -, u16, 16).
?UNSIGNED_BINOP(math_sub_u32_u32, -, u32, 32).
?UNSIGNED_BINOP(math_sub_u64_u64, -, u64, 64).

math_sub_integer_integer({value, integer, A}, {value, integer, B}) ->
    {value, integer, A - B};
math_sub_integer_integer({value, _, A}, {value, _, B}) when is_integer(A), is_integer(B) ->
    {value, integer, A - B}.

math_sub_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    {value, numeric, decimal:sub(A, B)}.

math_sub_numeric_fixed_numeric_fixed({value, {numeric, P, S}, A}, {value, {numeric, P, S}, B}) ->
    Diff = decimal:sub(A, B),
    case gdbsp_value:decimal_fits_precision(Diff, P, S) of
        true  -> {value, {numeric, P, S}, Diff};
        false -> throw(drop_row)
    end.

%% -- f64 sub --

-spec math_sub_f64_f64(value(), value()) -> value().
math_sub_f64_f64({value, f64, nan}, _) -> {value, f64, nan};
math_sub_f64_f64(_, {value, f64, nan}) -> {value, f64, nan};
math_sub_f64_f64({value, f64, infinity}, {value, f64, infinity}) -> {value, f64, nan};
math_sub_f64_f64({value, f64, neg_infinity}, {value, f64, neg_infinity}) -> {value, f64, nan};
math_sub_f64_f64({value, f64, infinity}, {value, f64, neg_infinity}) -> {value, f64, infinity};
math_sub_f64_f64({value, f64, neg_infinity}, {value, f64, infinity}) -> {value, f64, neg_infinity};
math_sub_f64_f64({value, f64, infinity}, {value, f64, _}) -> {value, f64, infinity};
math_sub_f64_f64({value, f64, _}, {value, f64, infinity}) -> {value, f64, neg_infinity};
math_sub_f64_f64({value, f64, neg_infinity}, {value, f64, _}) -> {value, f64, neg_infinity};
math_sub_f64_f64({value, f64, _}, {value, f64, neg_infinity}) -> {value, f64, infinity};
math_sub_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    try A - B of
        R when is_float(R) -> {value, f64, R}
    catch
        error:badarith ->
            if A >= 0.0, B =< 0.0 -> {value, f64, infinity};
               A =< 0.0, B >= 0.0 -> {value, f64, neg_infinity};
               true -> {value, f64, infinity}
            end
    end.

%% -- f32 sub --

-spec math_sub_f32_f32(value(), value()) -> value().
math_sub_f32_f32({value, f32, nan}, _) -> {value, f32, nan};
math_sub_f32_f32(_, {value, f32, nan}) -> {value, f32, nan};
math_sub_f32_f32({value, f32, infinity}, {value, f32, infinity}) -> {value, f32, nan};
math_sub_f32_f32({value, f32, neg_infinity}, {value, f32, neg_infinity}) -> {value, f32, nan};
math_sub_f32_f32({value, f32, infinity}, {value, f32, neg_infinity}) -> {value, f32, infinity};
math_sub_f32_f32({value, f32, neg_infinity}, {value, f32, infinity}) -> {value, f32, neg_infinity};
math_sub_f32_f32({value, f32, infinity}, {value, f32, _}) -> {value, f32, infinity};
math_sub_f32_f32({value, f32, _}, {value, f32, infinity}) -> {value, f32, neg_infinity};
math_sub_f32_f32({value, f32, neg_infinity}, {value, f32, _}) -> {value, f32, neg_infinity};
math_sub_f32_f32({value, f32, _}, {value, f32, neg_infinity}) -> {value, f32, infinity};
math_sub_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    try A - B of
        R when is_float(R) ->
            try
                Coerced = gdbsp_value:coerce_f32(R),
                {value, f32, Coerced}
            catch
                error:badarith ->
                    if R > 0.0 -> {value, f32, infinity};
                       R < 0.0 -> {value, f32, neg_infinity};
                       true -> {value, f32, nan}
                    end
            end
    catch
        error:badarith ->
            if A >= 0.0, B =< 0.0 -> {value, f32, infinity};
               A =< 0.0, B >= 0.0 -> {value, f32, neg_infinity};
               true -> {value, f32, infinity}
            end
    end.

%%====================================================================
%% math: Binary Arithmetic — mul
%%====================================================================

%% -spec for each signed variant: math_mul_T_T(value(), value()) -> value().
?SIGNED_BINOP(math_mul_i8_i8, *, i8, 8).
?SIGNED_BINOP(math_mul_i16_i16, *, i16, 16).
?SIGNED_BINOP(math_mul_i32_i32, *, i32, 32).
?SIGNED_BINOP(math_mul_i64_i64, *, i64, 64).

?UNSIGNED_BINOP(math_mul_u8_u8, *, u8, 8).
?UNSIGNED_BINOP(math_mul_u16_u16, *, u16, 16).
?UNSIGNED_BINOP(math_mul_u32_u32, *, u32, 32).
?UNSIGNED_BINOP(math_mul_u64_u64, *, u64, 64).

math_mul_integer_integer({value, integer, A}, {value, integer, B}) ->
    {value, integer, A * B};
math_mul_integer_integer({value, _, A}, {value, _, B}) when is_integer(A), is_integer(B) ->
    {value, integer, A * B}.

math_mul_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    {value, numeric, decimal:mult(A, B)}.

math_mul_numeric_fixed_numeric_fixed({value, {numeric, P, S}, A}, {value, {numeric, P, S}, B}) ->
    Prod = decimal:mult(A, B),
    Reduced = decimal:reduce(Prod),
    {_, Exp} = Reduced,
    Scale = -Exp,
    case Scale =< S of
        true ->
            Rescaled = numeric_rescale(Reduced, S),
            case gdbsp_value:decimal_fits_precision(Rescaled, P, S) of
                true  -> {value, {numeric, P, S}, Rescaled};
                false -> throw(drop_row)
            end;
        false ->
            throw(drop_row)
    end.

%% -- f64 mul --

-spec math_mul_f64_f64(value(), value()) -> value().
math_mul_f64_f64({value, f64, nan}, _) -> {value, f64, nan};
math_mul_f64_f64(_, {value, f64, nan}) -> {value, f64, nan};
math_mul_f64_f64({value, f64, infinity}, {value, f64, infinity}) -> {value, f64, infinity};
math_mul_f64_f64({value, f64, infinity}, {value, f64, neg_infinity}) -> {value, f64, neg_infinity};
math_mul_f64_f64({value, f64, neg_infinity}, {value, f64, infinity}) -> {value, f64, neg_infinity};
math_mul_f64_f64({value, f64, neg_infinity}, {value, f64, neg_infinity}) -> {value, f64, infinity};
math_mul_f64_f64({value, f64, infinity}, {value, f64, A}) when is_float(A), A > 0.0 -> {value, f64, infinity};
math_mul_f64_f64({value, f64, infinity}, {value, f64, A}) when is_float(A), A < 0.0 -> {value, f64, neg_infinity};
math_mul_f64_f64({value, f64, infinity}, {value, f64, _}) -> {value, f64, nan};
math_mul_f64_f64({value, f64, A}, {value, f64, infinity}) when is_float(A), A > 0.0 -> {value, f64, infinity};
math_mul_f64_f64({value, f64, A}, {value, f64, infinity}) when is_float(A), A < 0.0 -> {value, f64, neg_infinity};
math_mul_f64_f64({value, f64, _}, {value, f64, infinity}) -> {value, f64, nan};
math_mul_f64_f64({value, f64, neg_infinity}, {value, f64, A}) when is_float(A), A > 0.0 -> {value, f64, neg_infinity};
math_mul_f64_f64({value, f64, neg_infinity}, {value, f64, A}) when is_float(A), A < 0.0 -> {value, f64, infinity};
math_mul_f64_f64({value, f64, neg_infinity}, {value, f64, _}) -> {value, f64, nan};
math_mul_f64_f64({value, f64, A}, {value, f64, neg_infinity}) when is_float(A), A > 0.0 -> {value, f64, neg_infinity};
math_mul_f64_f64({value, f64, A}, {value, f64, neg_infinity}) when is_float(A), A < 0.0 -> {value, f64, infinity};
math_mul_f64_f64({value, f64, _}, {value, f64, neg_infinity}) -> {value, f64, nan};
math_mul_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    try A * B of
        R when is_float(R) -> {value, f64, R}
    catch
        error:badarith ->
            if A > 0.0, B > 0.0 -> {value, f64, infinity};
               A < 0.0, B < 0.0 -> {value, f64, infinity};
               true -> {value, f64, neg_infinity}
            end
    end.

%% -- f32 mul --

-spec math_mul_f32_f32(value(), value()) -> value().
math_mul_f32_f32({value, f32, nan}, _) -> {value, f32, nan};
math_mul_f32_f32(_, {value, f32, nan}) -> {value, f32, nan};
math_mul_f32_f32({value, f32, infinity}, {value, f32, infinity}) -> {value, f32, infinity};
math_mul_f32_f32({value, f32, infinity}, {value, f32, neg_infinity}) -> {value, f32, neg_infinity};
math_mul_f32_f32({value, f32, neg_infinity}, {value, f32, infinity}) -> {value, f32, neg_infinity};
math_mul_f32_f32({value, f32, neg_infinity}, {value, f32, neg_infinity}) -> {value, f32, infinity};
math_mul_f32_f32({value, f32, infinity}, {value, f32, A}) when is_float(A), A > 0.0 -> {value, f32, infinity};
math_mul_f32_f32({value, f32, infinity}, {value, f32, A}) when is_float(A), A < 0.0 -> {value, f32, neg_infinity};
math_mul_f32_f32({value, f32, infinity}, {value, f32, _}) -> {value, f32, nan};
math_mul_f32_f32({value, f32, A}, {value, f32, infinity}) when is_float(A), A > 0.0 -> {value, f32, infinity};
math_mul_f32_f32({value, f32, A}, {value, f32, infinity}) when is_float(A), A < 0.0 -> {value, f32, neg_infinity};
math_mul_f32_f32({value, f32, _}, {value, f32, infinity}) -> {value, f32, nan};
math_mul_f32_f32({value, f32, neg_infinity}, {value, f32, A}) when is_float(A), A > 0.0 -> {value, f32, neg_infinity};
math_mul_f32_f32({value, f32, neg_infinity}, {value, f32, A}) when is_float(A), A < 0.0 -> {value, f32, infinity};
math_mul_f32_f32({value, f32, neg_infinity}, {value, f32, _}) -> {value, f32, nan};
math_mul_f32_f32({value, f32, A}, {value, f32, neg_infinity}) when is_float(A), A > 0.0 -> {value, f32, neg_infinity};
math_mul_f32_f32({value, f32, A}, {value, f32, neg_infinity}) when is_float(A), A < 0.0 -> {value, f32, infinity};
math_mul_f32_f32({value, f32, _}, {value, f32, neg_infinity}) -> {value, f32, nan};
math_mul_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    try A * B of
        R when is_float(R) ->
            try
                Coerced = gdbsp_value:coerce_f32(R),
                {value, f32, Coerced}
            catch
                error:badarith ->
                    if R > 0.0 -> {value, f32, infinity};
                       R < 0.0 -> {value, f32, neg_infinity};
                       true -> {value, f32, nan}
                    end
            end
    catch
        error:badarith ->
            if A > 0.0, B > 0.0 -> {value, f32, infinity};
               A < 0.0, B < 0.0 -> {value, f32, infinity};
               true -> {value, f32, neg_infinity}
            end
    end.

%%====================================================================
%% math: Binary Arithmetic — div
%%====================================================================

%% -spec for each signed variant: math_div_T_T(value(), value()) -> value().
?SIGNED_DIVMOD(math_div_i8_i8, div, i8).
?SIGNED_DIVMOD(math_div_i16_i16, div, i16).
?SIGNED_DIVMOD(math_div_i32_i32, div, i32).
?SIGNED_DIVMOD(math_div_i64_i64, div, i64).

?UNSIGNED_DIVMOD(math_div_u8_u8, div, u8).
?UNSIGNED_DIVMOD(math_div_u16_u16, div, u16).
?UNSIGNED_DIVMOD(math_div_u32_u32, div, u32).
?UNSIGNED_DIVMOD(math_div_u64_u64, div, u64).

math_div_integer_integer({value, integer, _A}, {value, integer, 0}) -> throw(drop_row);
math_div_integer_integer({value, integer, A}, {value, integer, B}) ->
    {value, integer, A div B};
math_div_integer_integer(_, {value, _, 0}) -> throw(drop_row);
math_div_integer_integer({value, _, A}, {value, _, B}) when is_integer(A), is_integer(B) ->
    {value, integer, A div B}.

math_div_numeric_numeric({value, numeric, A}, {value, numeric, B}) ->
    case decimal:is_zero(B) of
        true  -> throw(drop_row);
        false -> {value, numeric, decimal:divide(A, B, #{precision => 20, rounding => round_half_up})}
    end.

math_div_numeric_fixed_numeric_fixed({value, {numeric, P, S}, A}, {value, {numeric, P, S}, B}) ->
    case decimal:is_zero(B) of
        true -> throw(drop_row);
        false ->
            ScaleFactor = gdbsp_value:pow10(S),
            Num = decimal:mult(A, {ScaleFactor, 0}),
            Q = decimal:divide(Num, B, #{precision => 0, rounding => round_half_up}),
            Check = decimal:mult(Q, B),
            case decimal:fast_cmp(Check, Num) of
                0 ->
                    Result = numeric_rescale(Q, S),
                    case gdbsp_value:decimal_fits_precision(Result, P, S) of
                        true  -> {value, {numeric, P, S}, Result};
                        false -> throw(drop_row)
                    end;
                _ ->
                    throw(drop_row)
            end
    end.

%% -- f64 div --

-spec math_div_f64_f64(value(), value()) -> value().
math_div_f64_f64({value, f64, nan}, _) -> {value, f64, nan};
math_div_f64_f64(_, {value, f64, nan}) -> {value, f64, nan};
math_div_f64_f64({value, f64, infinity}, {value, f64, infinity}) -> {value, f64, nan};
math_div_f64_f64({value, f64, infinity}, {value, f64, neg_infinity}) -> {value, f64, nan};
math_div_f64_f64({value, f64, neg_infinity}, {value, f64, infinity}) -> {value, f64, nan};
math_div_f64_f64({value, f64, neg_infinity}, {value, f64, neg_infinity}) -> {value, f64, nan};
math_div_f64_f64({value, f64, infinity}, {value, f64, A}) when is_float(A), A > 0.0 -> {value, f64, infinity};
math_div_f64_f64({value, f64, infinity}, {value, f64, A}) when is_float(A), A < 0.0 -> {value, f64, neg_infinity};
math_div_f64_f64({value, f64, neg_infinity}, {value, f64, A}) when is_float(A), A > 0.0 -> {value, f64, neg_infinity};
math_div_f64_f64({value, f64, neg_infinity}, {value, f64, A}) when is_float(A), A < 0.0 -> {value, f64, infinity};
math_div_f64_f64({value, f64, _}, {value, f64, infinity}) -> {value, f64, 0.0};
math_div_f64_f64({value, f64, _}, {value, f64, neg_infinity}) -> {value, f64, 0.0};
math_div_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B), B == 0.0 ->
    if A > 0.0 -> {value, f64, infinity};
       A < 0.0 -> {value, f64, neg_infinity};
       true -> {value, f64, nan}
    end;
math_div_f64_f64({value, f64, A}, {value, f64, B}) when is_float(A), is_float(B) ->
    try A / B of
        R when is_float(R) -> {value, f64, R}
    catch
        error:badarith ->
            if A > 0.0, B > 0.0 -> {value, f64, infinity};
               A < 0.0, B < 0.0 -> {value, f64, infinity};
               true -> {value, f64, neg_infinity}
            end
    end.

%% -- f32 div --

-spec math_div_f32_f32(value(), value()) -> value().
math_div_f32_f32({value, f32, nan}, _) -> {value, f32, nan};
math_div_f32_f32(_, {value, f32, nan}) -> {value, f32, nan};
math_div_f32_f32({value, f32, infinity}, {value, f32, infinity}) -> {value, f32, nan};
math_div_f32_f32({value, f32, infinity}, {value, f32, neg_infinity}) -> {value, f32, nan};
math_div_f32_f32({value, f32, neg_infinity}, {value, f32, infinity}) -> {value, f32, nan};
math_div_f32_f32({value, f32, neg_infinity}, {value, f32, neg_infinity}) -> {value, f32, nan};
math_div_f32_f32({value, f32, infinity}, {value, f32, A}) when is_float(A), A > 0.0 -> {value, f32, infinity};
math_div_f32_f32({value, f32, infinity}, {value, f32, A}) when is_float(A), A < 0.0 -> {value, f32, neg_infinity};
math_div_f32_f32({value, f32, neg_infinity}, {value, f32, A}) when is_float(A), A > 0.0 -> {value, f32, neg_infinity};
math_div_f32_f32({value, f32, neg_infinity}, {value, f32, A}) when is_float(A), A < 0.0 -> {value, f32, infinity};
math_div_f32_f32({value, f32, _}, {value, f32, infinity}) -> {value, f32, 0.0};
math_div_f32_f32({value, f32, _}, {value, f32, neg_infinity}) -> {value, f32, 0.0};
math_div_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B), B == 0.0 ->
    if A > 0.0 -> {value, f32, infinity};
       A < 0.0 -> {value, f32, neg_infinity};
       true -> {value, f32, nan}
    end;
math_div_f32_f32({value, f32, A}, {value, f32, B}) when is_float(A), is_float(B) ->
    try A / B of
        R when is_float(R) ->
            try
                Coerced = gdbsp_value:coerce_f32(R),
                {value, f32, Coerced}
            catch
                error:badarith ->
                    if R > 0.0 -> {value, f32, infinity};
                       R < 0.0 -> {value, f32, neg_infinity};
                       true -> {value, f32, nan}
                    end
            end
    catch
        error:badarith ->
            if A > 0.0, B > 0.0 -> {value, f32, infinity};
               A < 0.0, B < 0.0 -> {value, f32, infinity};
               true -> {value, f32, neg_infinity}
            end
    end.

%%====================================================================
%% math: Binary Arithmetic — mod
%%====================================================================

%% -spec for each signed variant: math_mod_T_T(value(), value()) -> value().
?SIGNED_DIVMOD(math_mod_i8_i8, rem, i8).
?SIGNED_DIVMOD(math_mod_i16_i16, rem, i16).
?SIGNED_DIVMOD(math_mod_i32_i32, rem, i32).
?SIGNED_DIVMOD(math_mod_i64_i64, rem, i64).

?UNSIGNED_DIVMOD(math_mod_u8_u8, rem, u8).
?UNSIGNED_DIVMOD(math_mod_u16_u16, rem, u16).
?UNSIGNED_DIVMOD(math_mod_u32_u32, rem, u32).
?UNSIGNED_DIVMOD(math_mod_u64_u64, rem, u64).

math_mod_integer_integer({value, integer, _A}, {value, integer, 0}) -> throw(drop_row);
math_mod_integer_integer({value, integer, A}, {value, integer, B}) ->
    {value, integer, A rem B};
math_mod_integer_integer(_, {value, _, 0}) -> throw(drop_row);
math_mod_integer_integer({value, _, A}, {value, _, B}) when is_integer(A), is_integer(B) ->
    {value, integer, A rem B}.

%%====================================================================
%% math: Unary Arithmetic — neg
%%====================================================================

-spec math_neg_integer(value()) -> value().
math_neg_integer({value, integer, A}) -> {value, integer, -A};
math_neg_integer({value, T, A}) when is_integer(A) -> {value, T, -A}.

%% -- neg f64 --

-spec math_neg_f64(value()) -> value().
math_neg_f64({value, f64, nan}) -> {value, f64, nan};
math_neg_f64({value, f64, infinity}) -> {value, f64, neg_infinity};
math_neg_f64({value, f64, neg_infinity}) -> {value, f64, infinity};
math_neg_f64({value, f64, A}) when is_float(A) -> {value, f64, -A}.

%%====================================================================
%% math: Unary Arithmetic — abs
%%====================================================================

-spec math_abs_integer(value()) -> value().
math_abs_integer({value, integer, A}) -> {value, integer, abs(A)};
math_abs_integer({value, T, A}) when is_integer(A) -> {value, T, abs(A)}.

%% -- abs f64 --

-spec math_abs_f64(value()) -> value().
math_abs_f64({value, f64, nan}) -> {value, f64, nan};
math_abs_f64({value, f64, infinity}) -> {value, f64, infinity};
math_abs_f64({value, f64, neg_infinity}) -> {value, f64, infinity};
math_abs_f64({value, f64, A}) when is_float(A) -> {value, f64, abs(A)}.

%%====================================================================
%% math: Unary Arithmetic — sign
%%====================================================================

-spec math_sign_integer(value()) -> value().
math_sign_integer({value, integer, A}) when A > 0 -> {value, i8, 1};
math_sign_integer({value, integer, 0}) -> {value, i8, 0};
math_sign_integer({value, integer, _}) -> {value, i8, -1};
math_sign_integer({value, _T, A}) when is_integer(A), A > 0 -> {value, i8, 1};
math_sign_integer({value, _T, 0}) -> {value, i8, 0};
math_sign_integer({value, _T, A}) when is_integer(A) -> {value, i8, -1}.

%% -- sign f64 --

-spec math_sign_f64(value()) -> value().
math_sign_f64({value, f64, nan}) -> {value, f64, nan};
math_sign_f64({value, f64, infinity}) -> {value, f64, 1.0};
math_sign_f64({value, f64, neg_infinity}) -> {value, f64, -1.0};
math_sign_f64({value, f64, A}) when A > 0.0 -> {value, f64, 1.0};
math_sign_f64({value, f64, A}) when A == 0.0 -> {value, f64, 0.0};
math_sign_f64({value, f64, A}) when A < 0.0 -> {value, f64, -1.0}.

%%====================================================================
%% float: Detection
%%====================================================================

-spec math_is_nan_f64(value()) -> value().
math_is_nan_f64({value, f64, nan}) -> {value, ?BOOL, true};
math_is_nan_f64({value, f64, _}) -> {value, ?BOOL, false}.

-spec math_is_nan_f32(value()) -> value().
math_is_nan_f32({value, f32, nan}) -> {value, ?BOOL, true};
math_is_nan_f32({value, f32, _}) -> {value, ?BOOL, false}.

-spec math_is_infinite_f64(value()) -> value().
math_is_infinite_f64({value, f64, infinity}) -> {value, ?BOOL, true};
math_is_infinite_f64({value, f64, neg_infinity}) -> {value, ?BOOL, true};
math_is_infinite_f64({value, f64, _}) -> {value, ?BOOL, false}.

-spec math_is_infinite_f32(value()) -> value().
math_is_infinite_f32({value, f32, infinity}) -> {value, ?BOOL, true};
math_is_infinite_f32({value, f32, neg_infinity}) -> {value, ?BOOL, true};
math_is_infinite_f32({value, f32, _}) -> {value, ?BOOL, false}.

-spec math_is_finite_f64(value()) -> value().
math_is_finite_f64({value, f64, A}) when is_float(A) -> {value, ?BOOL, true};
math_is_finite_f64({value, f64, _}) -> {value, ?BOOL, false}.

-spec math_is_finite_f32(value()) -> value().
math_is_finite_f32({value, f32, A}) when is_float(A) -> {value, ?BOOL, true};
math_is_finite_f32({value, f32, _}) -> {value, ?BOOL, false}.

%%====================================================================
%% Internal — wrapping
%%====================================================================

-spec wrap_signed(integer(), pos_integer()) -> integer().
wrap_signed(Value, Bits) ->
    Modulus = 1 bsl Bits,
    Half = 1 bsl (Bits - 1),
    U = Value rem Modulus,
    Unsigned = case U < 0 of
        true  -> U + Modulus;
        false -> U
    end,
    case Unsigned >= Half of
        true  -> Unsigned - Modulus;
        false -> Unsigned
    end.

-spec wrap_unsigned(integer(), pos_integer()) -> integer().
wrap_unsigned(Value, Bits) ->
    Modulus = 1 bsl Bits,
    U = Value rem Modulus,
    case U < 0 of
        true  -> U + Modulus;
        false -> U
    end.

%%====================================================================
%% Internal — numeric helpers
%%====================================================================

-spec numeric_rescale(decimal:decimal(), non_neg_integer()) -> decimal:decimal().
numeric_rescale({Coeff, Exp}, S) ->
    case Exp + S of
        0 -> {Coeff, -S};
        Adjust when Adjust < 0 -> throw(drop_row);
        Adjust when Adjust > 0 ->
            {Coeff * gdbsp_value:pow10(Adjust), -S}
    end.

%%====================================================================
%% math: Exponentials and Constants
%%====================================================================

-spec math_pow_f64_f64(value(), value()) -> value().
math_pow_f64_f64({value, f64, A}, {value, f64, B}) ->
    {value, f64, math:pow(A, B)}.

-spec math_sqrt_f64(value()) -> value().
math_sqrt_f64({value, f64, A}) ->
    {value, f64, math:sqrt(A)}.

-spec math_ln_f64(value()) -> value().
math_ln_f64({value, f64, A}) ->
    {value, f64, math:log(A)}.

-spec math_log10_f64(value()) -> value().
math_log10_f64({value, f64, A}) ->
    {value, f64, math:log10(A)}.

-spec math_log_value_base(value(), value()) -> value().
math_log_value_base({value, f64, V}, {value, f64, Base}) ->
    {value, f64, math:log(V) / math:log(Base)}.

-spec math_pi() -> value().
math_pi() ->
    {value, f64, math:pi()}.

%%====================================================================
%% math: Rounding
%%====================================================================

-spec math_ceil_f64(value()) -> value().
math_ceil_f64({value, f64, A}) ->
    {value, f64, float(math:ceil(A))}.

-spec math_floor_f64(value()) -> value().
math_floor_f64({value, f64, A}) ->
    {value, f64, float(math:floor(A))}.

-spec math_round_f64(value()) -> value().
math_round_f64({value, f64, A}) ->
    {value, f64, float(erlang:round(A))}.

%%====================================================================
%% math: Trigonometry
%%====================================================================

-spec math_sin_f64(value()) -> value().
math_sin_f64({value, f64, A}) ->
    {value, f64, math:sin(A)}.

-spec math_cos_f64(value()) -> value().
math_cos_f64({value, f64, A}) ->
    {value, f64, math:cos(A)}.

-spec math_tan_f64(value()) -> value().
math_tan_f64({value, f64, A}) ->
    {value, f64, math:tan(A)}.

-spec math_asin_f64(value()) -> value().
math_asin_f64({value, f64, A}) ->
    {value, f64, math:asin(A)}.

-spec math_acos_f64(value()) -> value().
math_acos_f64({value, f64, A}) ->
    {value, f64, math:acos(A)}.

-spec math_atan_f64(value()) -> value().
math_atan_f64({value, f64, A}) ->
    {value, f64, math:atan(A)}.

-spec math_atan2_f64_f64(value(), value()) -> value().
math_atan2_f64_f64({value, f64, Y}, {value, f64, X}) ->
    {value, f64, math:atan2(Y, X)}.

%%====================================================================
%% math: Array Statistics
%%====================================================================

-spec math_min_array(value()) -> value().
math_min_array({value, {array, T, _Size}, List}) ->
    {value, T, lists:min(List)}.

-spec math_max_array(value()) -> value().
math_max_array({value, {array, T, _Size}, List}) ->
    {value, T, lists:max(List)}.
