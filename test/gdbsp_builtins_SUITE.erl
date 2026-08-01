%%%-------------------------------------------------------------------
%%% @doc Builtins test suite — unit tests for operator tables,
%%% concrete function resolution, type-variable unification, and
%%% implementation lookup.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_builtins_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_type.hrl").

-export([all/0]).
-export([t01_binop_plus/1, t02_binop_minus/1, t03_binop_mul/1,
         t04_binop_eq/1, t05_binop_concat/1, t06_unop_not/1,
         t07_operand_types_plus/1, t08_operand_types_mul/1,
         t09_operand_types_mod/1, t10_operand_types_eq/1,
         t11_operand_types_not/1, t12_operand_types_concat/1,
         t13_operand_types_shl/1, t14_operand_types_bitand/1,
         t15_operand_types_logic_and/1, t16_operand_types_bitnot/1,
         t17_is_valid_operand_ok/1, t18_is_valid_operand_fail/1,
         t19_concrete_add_i64/1, t20_concrete_add_numeric/1,
         t21_concrete_sub_i32/1, t22_concrete_mul_f64/1,
         t23_concrete_eq_string/1, t24_concrete_neq_bits/1,
         t25_concrete_lt_date/1, t26_concrete_gt_i64/1,
         t27_concrete_not/1, t28_concrete_concat_string/1,
         t29_concrete_concat_array/1, t30_concrete_invalid/1,
         t31_concrete_bits_or/1, t32_concrete_bits_shl/1,
         t33_unify_same/1, t34_unify_conflict/1,
         t35_unify_single/1, t36_unify_nested/1,
         t37_unify_struct/1, t38_impl_add_i64/1,
         t39_impl_not/1, t40_impl_unknown/1
        ]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [t01_binop_plus, t02_binop_minus, t03_binop_mul,
     t04_binop_eq, t05_binop_concat, t06_unop_not,
     t07_operand_types_plus, t08_operand_types_mul,
     t09_operand_types_mod, t10_operand_types_eq,
     t11_operand_types_not, t12_operand_types_concat,
     t13_operand_types_shl, t14_operand_types_bitand,
     t15_operand_types_logic_and, t16_operand_types_bitnot,
     t17_is_valid_operand_ok, t18_is_valid_operand_fail,
     t19_concrete_add_i64, t20_concrete_add_numeric,
     t21_concrete_sub_i32, t22_concrete_mul_f64,
     t23_concrete_eq_string, t24_concrete_neq_bits,
     t25_concrete_lt_date, t26_concrete_gt_i64,
     t27_concrete_not, t28_concrete_concat_string,
     t29_concrete_concat_array, t30_concrete_invalid,
     t31_concrete_bits_or, t32_concrete_bits_shl,
     t33_unify_same, t34_unify_conflict,
     t35_unify_single, t36_unify_nested,
     t37_unify_struct, t38_impl_add_i64,
     t39_impl_not, t40_impl_unknown
    ].

%%====================================================================
%% B1. Operator → Method Mapping (6 tests)
%% NOTE: Currently returns method names (add, sub, etc.).
%% Phase C will change these to operator chars (+, -, etc.).
%%====================================================================

t01_binop_plus(_Config) ->
    <<"add">> = gdbsp_builtins:binop_fn_name('+').

t02_binop_minus(_Config) ->
    <<"sub">> = gdbsp_builtins:binop_fn_name('-').

t03_binop_mul(_Config) ->
    <<"mul">> = gdbsp_builtins:binop_fn_name('*').

t04_binop_eq(_Config) ->
    <<"eq">> = gdbsp_builtins:binop_fn_name('=').

t05_binop_concat(_Config) ->
    <<"concat">> = gdbsp_builtins:binop_fn_name('++').

t06_unop_not(_Config) ->
    <<"not">> = gdbsp_builtins:unop_fn_name('not').

%%====================================================================
%% B2. Operator Validity (12 tests)
%%====================================================================

t07_operand_types_plus(_Config) ->
    Types = gdbsp_builtins:operand_types(<<"+">>),
    assert_contains(i64, Types),
    assert_contains(numeric, Types),
    assert_contains(f64, Types),
    assert_contains(interval, Types),
    assert_not_contains(string, Types).

t08_operand_types_mul(_Config) ->
    Types = gdbsp_builtins:operand_types(<<"*">>),
    assert_contains(i64, Types),
    assert_contains(numeric, Types),
    assert_contains(f64, Types),
    assert_not_contains(interval, Types).

t09_operand_types_mod(_Config) ->
    Types = gdbsp_builtins:operand_types(<<"%">>),
    assert_contains(i64, Types),
    assert_contains(integer, Types),
    assert_not_contains(f64, Types).

t10_operand_types_eq(_Config) ->
    Types = gdbsp_builtins:operand_types(<<"=">>),
    true = is_all_except_set(Types).

t11_operand_types_not(_Config) ->
    [{enum, [<<"false">>, <<"true">>]}] = gdbsp_builtins:operand_types(<<"not">>).

t12_operand_types_concat(_Config) ->
    Types = gdbsp_builtins:operand_types(<<"++">>),
    assert_contains({string, <<"UTF-8">>}, Types),
    assert_contains(bytes, Types),
    assert_contains(bits, Types),
    append_array_type(Types).

t13_operand_types_shl(_Config) ->
    [bits] = gdbsp_builtins:operand_types(<<"<<">>).

t14_operand_types_bitand(_Config) ->
    [bits] = gdbsp_builtins:operand_types(<<"&">>).

t15_operand_types_logic_and(_Config) ->
    [{enum, [<<"false">>, <<"true">>]}] = gdbsp_builtins:operand_types(<<"and">>).

t16_operand_types_bitnot(_Config) ->
    [bits] = gdbsp_builtins:operand_types(<<"~">>).

t17_is_valid_operand_ok(_Config) ->
    true = gdbsp_builtins:is_valid_operand(<<"+">>, i64),
    true = gdbsp_builtins:is_valid_operand(<<"=">>, string_with_encoding),
    true = gdbsp_builtins:is_valid_operand(<<"&">>, bits).

t18_is_valid_operand_fail(_Config) ->
    false = gdbsp_builtins:is_valid_operand(<<"+">>,
                                             {string, <<"UTF-8">>}),
    false = gdbsp_builtins:is_valid_operand(<<"not">>, i64),
    false = gdbsp_builtins:is_valid_operand(<<"=">>, dynamic).

%%====================================================================
%% B3. Concrete Function Name Resolution (14 tests)
%%====================================================================

t19_concrete_add_i64(_Config) ->
    <<"std.add_i64">> = gdbsp_builtins:concrete_fn(<<"+">>, [i64, i64], #{}).

t20_concrete_add_numeric(_Config) ->
    <<"std.add_numeric">> = gdbsp_builtins:concrete_fn(<<"+">>, [numeric, numeric], #{}).

t21_concrete_sub_i32(_Config) ->
    <<"std.sub_i32">> = gdbsp_builtins:concrete_fn(<<"-">>, [i32, i32], #{}).

t22_concrete_mul_f64(_Config) ->
    <<"std.mul_f64">> = gdbsp_builtins:concrete_fn(<<"*">>, [f64, f64], #{}).

t23_concrete_eq_string(_Config) ->
    <<"std.eq_string">> = gdbsp_builtins:concrete_fn(<<"=">>,
        [{string, <<"UTF-8">>}, {string, <<"UTF-8">>}], #{}).

t24_concrete_neq_bits(_Config) ->
    <<"std.neq_bits">> = gdbsp_builtins:concrete_fn(<<"!=">>, [bits, bits], #{}).

t25_concrete_lt_date(_Config) ->
    <<"std.lt_date">> = gdbsp_builtins:concrete_fn(<<"<">>, [date, date], #{}).

t26_concrete_gt_i64(_Config) ->
    <<"std.gt_i64">> = gdbsp_builtins:concrete_fn(<<">">>, [i64, i64], #{}).

t27_concrete_not(_Config) ->
    <<"std.not">> = gdbsp_builtins:concrete_fn(<<"not">>,
        [{enum, [<<"false">>, <<"true">>]}], #{}).

t28_concrete_concat_string(_Config) ->
    <<"std.concat_string">> = gdbsp_builtins:concrete_fn(<<"++">>,
        [{string, <<"UTF-8">>}, {string, <<"UTF-8">>}], #{}).

t29_concrete_concat_array(_Config) ->
    <<"std.concat_array">> = gdbsp_builtins:concrete_fn(<<"++">>,
        [{array, i64, varsize}, {array, i64, varsize}], #{}).

t30_concrete_invalid(_Config) ->
    {error, not_an_operator} = gdbsp_builtins:concrete_fn(<<"+">>,
        [{string, <<"UTF-8">>}, {string, <<"UTF-8">>}], #{}).

t31_concrete_bits_or(_Config) ->
    <<"std.bits_or">> = gdbsp_builtins:concrete_fn(<<"|">>, [bits, bits], #{}).

t32_concrete_bits_shl(_Config) ->
    <<"std.bits_shl">> = gdbsp_builtins:concrete_fn(<<"<<">>, [bits, integer], #{}).

%%====================================================================
%% B4. Type-Variable Unification (5 tests)
%%====================================================================

t33_unify_same(_Config) ->
    {ok, Subs} = gdbsp_builtins:unify_types(
        [{type_var, <<"T">>}, {type_var, <<"T">>}], [i64, i64], #{}),
    i64 = maps:get({type_var, <<"T">>}, Subs).

t34_unify_conflict(_Config) ->
    {error, {type_var_conflict, <<"T">>}} = gdbsp_builtins:unify_types(
        [{type_var, <<"T">>}, {type_var, <<"T">>}], [i64, f64], #{}).

t35_unify_single(_Config) ->
    {ok, Subs} = gdbsp_builtins:unify_types(
        [{type_var, <<"T">>}], [i64], #{}),
    i64 = maps:get({type_var, <<"T">>}, Subs).

t36_unify_nested(_Config) ->
    %% Flat unification: two type vars in sequence
    {ok, Subs} = gdbsp_builtins:unify_types(
        [{type_var, <<"K">>}, {type_var, <<"V">>}],
        [{string, <<"UTF-8">>}, i64], #{}),
    {string, <<"UTF-8">>} = maps:get({type_var, <<"K">>}, Subs),
    i64 = maps:get({type_var, <<"V">>}, Subs).

t37_unify_struct(_Config) ->
    StructType = {struct, #{<<"x">> => i64}, exact},
    {ok, Subs} = gdbsp_builtins:unify_types(
        [{type_var, <<"T">>}],
        [StructType], #{}),
    StructType = maps:get({type_var, <<"T">>}, Subs).

%%====================================================================
%% B5. Implementation Lookup (3 tests)
%%====================================================================

t38_impl_add_i64(_Config) ->
    {ok, {gdbsp_math, math_add_i64_i64, 2}} = gdbsp_builtins:fn_impl(<<"std.add_i64">>).

t39_impl_not(_Config) ->
    {ok, {gdbsp_std, std_not_boolean, 1}} = gdbsp_builtins:fn_impl(<<"std.not">>).

t40_impl_unknown(_Config) ->
    {error, unknown_impl} = gdbsp_builtins:fn_impl(<<"nonexistent">>).

%%====================================================================
%% Helpers
%%====================================================================

assert_contains(Element, List) ->
    case lists:member(Element, List) of
        true -> ok;
        false ->
            ct:fail("expected ~p to be in list ~p", [Element, List])
    end.

assert_not_contains(Element, List) ->
    case lists:member(Element, List) of
        false -> ok;
        true ->
            ct:fail("expected ~p NOT to be in list ~p", [Element, List])
    end.

is_all_except_set(List) ->
    lists:member(all_except, List).

append_array_type(Types) ->
    %% The array type in the validity set must include array (unparameterized)
    true = lists:member(array, Types) orelse
        lists:any(fun({array, _, _}) -> true; (_) -> false end, Types).
