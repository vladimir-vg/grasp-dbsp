%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_eval — name-aware keyword-argument dispatch.
%%%
%%% Covers the seam where caller kwargs (a map, order-irrelevant) are
%%% assembled into the callee's positional argument list by NAME, using
%%% the declared kwarg order from the derived kwarg-order table.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_eval_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([struct_set_reversed_kwargs/1,
         struct_set_key_before_value/1,
         struct_set_missing_kwarg/1,
         struct_set_unexpected_kwarg/1,
         struct_get_single_kwarg/1,
         no_kwarg_order/1]).

-define(STRUCT_SET_ORDER, #{<<"std.struct_set">> => [<<"key">>, <<"value">>]}).
-define(STRUCT_GET_ORDER, #{<<"std.struct_get">> => [<<"key">>]}).

all() ->
    [struct_set_reversed_kwargs,
     struct_set_key_before_value,
     struct_set_missing_kwarg,
     struct_set_unexpected_kwarg,
     struct_get_single_kwarg,
     no_kwarg_order].

%%====================================================================
%% Helpers
%%====================================================================

name_row() ->
    gdbsp_value:map_to_struct(
        #{<<"name">> => <<"old">>},
        {struct, #{<<"name">> => string}, exact}).

eval(Expr, KwargOrder) ->
    gdbsp_eval:eval_with_row(Expr, name_row(), <<"row">>, KwargOrder).

%%====================================================================
%% Tests
%%====================================================================

%% Caller supplies `value` before `key`; dispatch must look each up by NAME.
struct_set_reversed_kwargs(_Config) ->
    Expr = {call, <<"std.struct_set">>,
            [{arg, <<"row">>}],
            #{<<"value">> => {value, string, <<"new">>},
              <<"key">> => {value, string, <<"name">>}}},
    {ok, {value, {struct, _, _}, Vals}} = eval(Expr, ?STRUCT_SET_ORDER),
    {value, string, <<"new">>} = maps:get(<<"name">>, Vals).

struct_set_key_before_value(_Config) ->
    Expr = {call, <<"std.struct_set">>,
            [{arg, <<"row">>}],
            #{<<"key">> => {value, string, <<"name">>},
              <<"value">> => {value, string, <<"new">>}}},
    {ok, {value, {struct, _, _}, Vals}} = eval(Expr, ?STRUCT_SET_ORDER),
    {value, string, <<"new">>} = maps:get(<<"name">>, Vals).

struct_set_missing_kwarg(_Config) ->
    Expr = {call, <<"std.struct_set">>,
            [{arg, <<"row">>}],
            #{<<"key">> => {value, string, <<"name">>}}},
    {error, {missing_kw_arg, <<"value">>}} = eval(Expr, ?STRUCT_SET_ORDER).

struct_set_unexpected_kwarg(_Config) ->
    Expr = {call, <<"std.struct_set">>,
            [{arg, <<"row">>}],
            #{<<"key">> => {value, string, <<"name">>},
              <<"value">> => {value, string, <<"new">>},
              <<"extra">> => {value, string, <<"x">>}}},
    {error, {unexpected_kw_arg, <<"extra">>}} = eval(Expr, ?STRUCT_SET_ORDER).

struct_get_single_kwarg(_Config) ->
    Expr = {call, <<"std.struct_get">>,
            [{arg, <<"row">>}],
            #{<<"key">> => {value, string, <<"name">>}}},
    {ok, {value, string, <<"old">>}} = eval(Expr, ?STRUCT_GET_ORDER).

no_kwarg_order(_Config) ->
    Expr = {call, <<"std.struct_get">>,
            [{arg, <<"row">>}],
            #{<<"key">> => {value, string, <<"name">>}}},
    {error, {no_kwarg_order, <<"std.struct_get">>}} = eval(Expr, #{}).
