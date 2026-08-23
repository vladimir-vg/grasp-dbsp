%%%-------------------------------------------------------------------
%%% @doc Expression lowering and type-checking test suite.
%%%
%%% Covers:
%%%   - Phase 4a: lower_expr/2 (17 tests)
%%%   - Phase 4b: check_fn_body/3 (6 tests)
%%%   - Phase 4c: check_all_fns/1 integration (5 tests)
%%%   - Phase 5:  builtins lookup + operator desugaring (5 tests)
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_compile_expr_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_parse.hrl").
-include("gdbsp_expr.hrl").
-include("gdbsp_type.hrl").

-export([all/0]).
-export([t01_lower_integer/1, t02_lower_string/1, t03_lower_absent/1,
         t04_lower_true/1, t05_lower_null/1, t06_lower_var/1,
         t07_lower_var_no_binding/1, t08_lower_binop_add/1,
         t09_lower_binop_operators/1, t10_lower_unop/1,
         t11_lower_dot_access/1, t12_lower_array/1,
         t13_lower_dict/1, t14_lower_call/1, t15_lower_call_kw/1,
         t16_lower_subscript_index/1, t17_lower_subscript_slice/1,
         t18_check_ok/1, t19_check_return_mismatch/1,
         t20_check_ok_arg/1, t21_check_unbound_var/1,
         t22_check_ok_call/1, t23_check_call_mismatch/1,
         t24_check_all_matching/1, t25_check_all_missing_ts/1,
         t26_check_all_param_count/1, t27_check_all_kw_mismatch/1,
         t28_check_all_roundtrip/1,
         t29_builtin_resolve_ops/1, t30_builtin_resolve_comparison/1,
         t31_builtin_resolve_logic/1, t32_builtin_binop_name/1,
         t33_builtin_resolve_concat/1
        ]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [t01_lower_integer, t02_lower_string, t03_lower_absent,
     t04_lower_true, t05_lower_null, t06_lower_var,
     t07_lower_var_no_binding, t08_lower_binop_add,
     t09_lower_binop_operators, t10_lower_unop,
     t11_lower_dot_access, t12_lower_array,
     t13_lower_dict, t14_lower_call, t15_lower_call_kw,
     t16_lower_subscript_index, t17_lower_subscript_slice,
     t18_check_ok, t19_check_return_mismatch,
     t20_check_ok_arg, t21_check_unbound_var,
     t22_check_ok_call, t23_check_call_mismatch,
     t24_check_all_matching, t25_check_all_missing_ts,
     t26_check_all_param_count, t27_check_all_kw_mismatch,
     t28_check_all_roundtrip,
     t29_builtin_resolve_ops, t30_builtin_resolve_comparison,
     t31_builtin_resolve_logic, t32_builtin_binop_name,
     t33_builtin_resolve_concat
    ].

%%====================================================================
%% Phase 4a — Lowering tests
%%====================================================================

t01_lower_integer(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {const, 1, 42, integer, undefined, undefined}, #{}),
    {value, integer, 42} = Result.

t02_lower_string(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {const, 1, <<"hi">>, string, undefined, undefined}, #{}),
    {value, {string, <<"UTF-8">>}, <<"hi">>} = Result.

t03_lower_absent(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {const, 1, absent, absent, undefined, undefined}, #{}),
    {value, absent, absent} = Result.

t04_lower_true(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {symbol, 1, <<"true">>}, #{}),
    {value, {enum,[<<"false">>,<<"true">>]}, <<"true">>} = Result.

t05_lower_null(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {symbol, 1, <<"null">>}, #{}),
    {value, {enum,[<<"null">>]}, <<"null">>} = Result.

t06_lower_var(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {var, 1, <<"x">>}, #{<<"x">> => <<"x">>}),
    {arg, <<"x">>} = Result.

t07_lower_var_no_binding(_Config) ->
    %% Unbound variables are not rejected during lowering; they surface
    %% as {unbound_var, Name} during type inference (see t21).
    {arg, <<"y">>} = gdbsp_compile_expr:lower_expr(
        {var, 1, <<"y">>}, #{}).

t08_lower_binop_add(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {binop, 1, '+',
         {var, 1, <<"x">>},
         {var, 1, <<"y">>}},
        #{<<"x">> => <<"x">>, <<"y">> => <<"y">>}),
    {call, <<"+">>, [{arg, <<"x">>}, {arg, <<"y">>}], #{}} = Result.

t09_lower_binop_operators(_Config) ->
    Ops = [
        {'+',  <<"+">>},   {'-',  <<"-">>},
        {'*',  <<"*">>},   {'/',  <<"/">>},
        {'%',  <<"%">>},   {'=',  <<"=">>},
        {'!=', <<"!=">>},  {'<',  <<"<">>},
        {'>',  <<">">>},   {'<=', <<"<=">>},
        {'>=', <<">=">>},  {'++', <<"++">>},
        {'<<', <<"<<">>},  {'>>',  <<">>">>},
        {'<<<',<<"<<<">>}, {'>>>',<<">>>">>},
        {'&',  <<"&">>},   {'|',  <<"|">>},
        {'^',  <<"^">>}
    ],
    Bindings = #{<<"x">> => <<"x">>, <<"y">> => <<"y">>},
    lists:foreach(
        fun({Op, FnName}) ->
            E = {binop, 1, Op, {var, 1, <<"x">>}, {var, 1, <<"y">>}},
            {call, FnName, [{arg, <<"x">>}, {arg, <<"y">>}], #{}} =
                gdbsp_compile_expr:lower_expr(E, Bindings)
        end, Ops).

t10_lower_unop(_Config) ->
    Uops = [
        {'-',   <<"-">>},
        {'~',   <<"~">>},
        {'not', <<"not">>}
    ],
    Bindings = #{<<"x">> => <<"x">>},
    lists:foreach(
        fun({Op, FnName}) ->
            E = {unop, 1, Op, {var, 1, <<"x">>}},
            {call, FnName, [{arg, <<"x">>}], #{}} =
                gdbsp_compile_expr:lower_expr(E, Bindings)
        end, Uops).

t11_lower_dot_access(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {dot_access, 1, {var, 1, <<"r">>}, <<"f">>},
        #{<<"r">> => <<"r">>}),
    {call, <<"std.struct_get">>, [{arg, <<"r">>}], KwMap} = Result,
    {value, {string, <<"UTF-8">>}, <<"f">>} = maps:get(<<"key">>, KwMap),
    ok.

t12_lower_array(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {array_literal, 1, [
            {const, 1, 1, integer, undefined, undefined},
            {const, 1, 2, integer, undefined, undefined}
        ]},
        #{}),
    {call, <<"array">>,
     [{value, integer, 1}, {value, integer, 2}], #{}} = Result.

t13_lower_dict(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {dict_literal, 1, [
            {kv, <<"a">>, {const, 1, 1, integer, undefined, undefined}}
        ], undefined},
        #{}),
    {call, <<"map">>, [], KwMap} = Result,
    {value, integer, 1} = maps:get(<<"a">>, KwMap).

t14_lower_call(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {call, 1, <<"sqrt">>, [
            {const, 1, 4, integer, undefined, undefined}
        ]},
        #{}),
    {call, <<"sqrt">>, [{value, integer, 4}], #{}} = Result.

t15_lower_call_kw(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {call, 1, <<"f">>, [
            {const, 1, 1, integer, undefined, undefined},
            {kv, <<"k">>, {const, 1, 2, integer, undefined, undefined}}
        ]},
        #{}),
    {call, <<"f">>, [{value, integer, 1}], KwMap} = Result,
    {value, integer, 2} = maps:get(<<"k">>, KwMap).

t16_lower_subscript_index(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {subscript, 1,
         {var, 1, <<"a">>},
         {index, {const, 1, 0, integer, undefined, undefined}}},
        #{<<"a">> => <<"a">>}),
    {get, {arg, <<"a">>}, [{value, integer, 0}]} = Result.

t17_lower_subscript_slice(_Config) ->
    Result = gdbsp_compile_expr:lower_expr(
        {subscript, 1,
         {var, 1, <<"a">>},
         {slice,
          {const, 1, 0, integer, undefined, undefined},
          {const, 1, 5, integer, undefined, undefined},
          undefined}},
        #{<<"a">> => <<"a">>}),
    {slice, {arg, <<"a">>},
     {value, integer, 0}, {value, integer, 5}, undefined} = Result.

%%====================================================================
%% Phase 4b — Type checking tests
%%====================================================================

t18_check_ok(_Config) ->
    ok = gdbsp_compile_expr:check_fn_body(
        {value, integer, 42}, #{<<"x">> => i64}, integer, #{}).

t19_check_return_mismatch(_Config) ->
    {error, [{return_type_mismatch, _, _}]} =
        gdbsp_compile_expr:check_fn_body(
            {value, integer, 42}, #{}, string, #{}).

t20_check_ok_arg(_Config) ->
    ok = gdbsp_compile_expr:check_fn_body(
        {arg, <<"x">>}, #{<<"x">> => i64}, i64, #{}).

t21_check_unbound_var(_Config) ->
    {error, Errors} = gdbsp_compile_expr:check_fn_body(
        {arg, <<"x">>}, #{}, i64, #{}),
    true = lists:any(fun({unbound_var, <<"x">>}) -> true; (_) -> false end, Errors).

t22_check_ok_call(_Config) ->
    Stdlib = test_stdlib(),
    ok = gdbsp_compile_expr:check_fn_body(
        {call, <<"+">>, [{arg, <<"x">>}, {arg, <<"y">>}], #{}},
        #{<<"x">> => i64, <<"y">> => i64}, i64, Stdlib).

t23_check_call_mismatch(_Config) ->
    Stdlib = test_stdlib(),
    {error, [{return_type_mismatch, _, _}]} =
        gdbsp_compile_expr:check_fn_body(
            {call, <<"+">>, [{arg, <<"x">>}, {arg, <<"y">>}], #{}},
            #{<<"x">> => i64, <<"y">> => i64}, string, Stdlib).

%%====================================================================
%% Phase 4c — Integration tests (check_all_fns/1)
%%====================================================================

t24_check_all_matching(_Config) ->
    Stdlib = test_stdlib(),
    Prog = #gdbsp_program{
        nodes = [],
        typespecs = [
            #gdbsp_typespec{name = <<"square">>,
                            spec = {function, [i64], #{}, i64},
                            line = 1}
        ],
        circuits = [],
        fn_defs = [
            #gdbsp_fn_def{name = <<"square">>,
                          params = [{pos, <<"x">>}],
                          body = {binop, 1, '*',
                                  {var, 1, <<"x">>},
                                  {var, 1, <<"x">>}},
                          line = 2}
        ]
    },
    {ok, FnJsonMap, []} = gdbsp_compile_expr:check_all_fns(Prog, Stdlib),
    true = maps:is_key(<<"square">>, FnJsonMap).

t25_check_all_missing_ts(_Config) ->
    Stdlib = test_stdlib(),
    Prog = #gdbsp_program{
        nodes = [],
        typespecs = [],
        circuits = [],
        fn_defs = [
            #gdbsp_fn_def{name = <<"f">>,
                          params = [{pos, <<"x">>}],
                          body = {var, 1, <<"x">>},
                          line = 1}
        ]
    },
    {error, ErrorMap} = gdbsp_compile_expr:check_all_fns(Prog, Stdlib),
    missing_typespec = maps:get(<<"f">>, ErrorMap).

t26_check_all_param_count(_Config) ->
    Stdlib = test_stdlib(),
    Prog = #gdbsp_program{
        nodes = [],
        typespecs = [
            #gdbsp_typespec{name = <<"f">>,
                            spec = {function, [i64, i64], #{}, i64},
                            line = 1}
        ],
        circuits = [],
        fn_defs = [
            #gdbsp_fn_def{name = <<"f">>,
                          params = [{pos, <<"x">>}],
                          body = {var, 1, <<"x">>},
                          line = 2}
        ]
    },
    {error, ErrorMap} = gdbsp_compile_expr:check_all_fns(Prog, Stdlib),
    [{param_count_mismatch, _, _}] = maps:get(<<"f">>, ErrorMap).

t27_check_all_kw_mismatch(_Config) ->
    Stdlib = test_stdlib(),
    Prog = #gdbsp_program{
        nodes = [],
        typespecs = [
            #gdbsp_typespec{name = <<"f">>,
                            spec = {function, [i64], #{<<"d">> => i64}, i64},
                            line = 1}
        ],
        circuits = [],
        fn_defs = [
            #gdbsp_fn_def{name = <<"f">>,
                          params = [{pos, <<"x">>}, {kw, <<"e">>, <<"e">>}],
                          body = {var, 1, <<"x">>},
                          line = 2}
        ]
    },
    {error, ErrorMap} = gdbsp_compile_expr:check_all_fns(Prog, Stdlib),
    KwErrors = maps:get(<<"f">>, ErrorMap),
    true = lists:any(
        fun({extra_kw_params, _}) -> true;
           ({missing_kw_params, _}) -> true;
           ({kw_param_mismatch, _, _}) -> true;
           (_) -> false
        end, KwErrors).

t28_check_all_roundtrip(_Config) ->
    Stdlib = test_stdlib(),
    Prog = #gdbsp_program{
        nodes = [],
        typespecs = [
            #gdbsp_typespec{name = <<"square">>,
                            spec = {function, [i64], #{}, i64},
                            line = 1}
        ],
        circuits = [],
        fn_defs = [
            #gdbsp_fn_def{name = <<"square">>,
                          params = [{pos, <<"x">>}],
                          body = {binop, 1, '*',
                                  {var, 1, <<"x">>},
                                  {var, 1, <<"x">>}},
                          line = 2}
        ]
    },
    {ok, FnJsonMap, []} = gdbsp_compile_expr:check_all_fns(Prog, Stdlib),
    Json = maps:get(<<"square">>, FnJsonMap),
    {ok, Expr} = gdbsp_expr:json_to_expr(Json),
    {call, <<"*">>, [{arg, <<"x">>}, {arg, <<"x">>}], #{}} = Expr.

%%====================================================================
%% Phase 5 — Builtins tests (updated for new API)
%%====================================================================

t29_builtin_resolve_ops(_Config) ->
    Stdlib = test_stdlib(),
    {ok, i64, _} = gdbsp_builtins:resolve_call(<<"+">>, [i64, i64], [], Stdlib),
    {ok, i64, _} = gdbsp_builtins:resolve_call(<<"-">>, [i64, i64], [], Stdlib).

t30_builtin_resolve_comparison(_Config) ->
    Stdlib = test_stdlib(),
    {ok, ?BOOL, _} = gdbsp_builtins:resolve_call(<<"=">>, [i64, i64], [], Stdlib),
    {ok, ?BOOL, _} = gdbsp_builtins:resolve_call(<<"!=">>, [string, string], [], Stdlib),
    {ok, ?BOOL, _} = gdbsp_builtins:resolve_call(<<"<">>, [i64, i64], [], Stdlib).

t31_builtin_resolve_logic(_Config) ->
    Stdlib = test_stdlib(),
    BoolT = {enum, [<<"false">>, <<"true">>]},
    {ok, BoolT, _} = gdbsp_builtins:resolve_call(<<"not">>, [BoolT], [], Stdlib),
    {ok, BoolT, _} = gdbsp_builtins:resolve_call(<<"and">>, [BoolT, BoolT], [], Stdlib).

t32_builtin_binop_name(_Config) ->
    <<"+">> = gdbsp_builtins:binop_fn_name('+').

t33_builtin_resolve_concat(_Config) ->
    Stdlib = test_stdlib(),
    {ok, {string, <<"UTF-8">>}, _} =
        gdbsp_builtins:resolve_call(<<"++">>, [{string, <<"UTF-8">>}, {string, <<"UTF-8">>}], [], Stdlib),
    {ok, bytes, _} = gdbsp_builtins:resolve_call(<<"++">>, [bytes, bytes], [], Stdlib),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

test_stdlib() ->
    {ok, M} = gdbsp_compile:load_stdlib(),
    M.
