%%%-------------------------------------------------------------------
%%% @doc Tests for gdbsp_value_json — canonical value encoding/decoding
%%% round trips across all types.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_value_json_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("gdbsp_type.hrl").

-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1]).

-export([
    scalar_roundtrips/1,
    optional_roundtrips/1,
    dynamic_roundtrips/1,
    json_roundtrips/1,
    closure_roundtrips/1,
    container_roundtrips/1,
    row_roundtrip/1
]).

all() -> [{group, value_json}].

groups() ->
    [{value_json, [parallel], [
        scalar_roundtrips,
        optional_roundtrips,
        dynamic_roundtrips,
        json_roundtrips,
        closure_roundtrips,
        container_roundtrips,
        row_roundtrip
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(jsx),
    Config.

end_per_suite(_Config) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

%% encode_value(Type, Raw) =:= Json and decode_value(Type, Json) =:= {ok, Raw}
value_rt(Type, Raw) ->
    Json = gdbsp_value_json:encode_value(Type, Raw),
    {ok, Raw} = gdbsp_value_json:decode_value(Type, Json),
    ok.

%% decode_field(Type, Json) =:= {ok, _} and encode_field(Type, Decoded) =:= Json
field_rt(Type, Json) ->
    {ok, Decoded} = gdbsp_value_json:decode_field(Type, Json),
    Json = gdbsp_value_json:encode_field(Type, Decoded),
    ok.

%%====================================================================
%% Scalars
%%====================================================================

scalar_roundtrips(_Config) ->
    ok = value_rt(i64, 5),
    ok = value_rt(i8, -1),
    ok = value_rt(u64, 42),
    ok = value_rt(integer, 5),
    ok = value_rt(f64, 1.5),
    ok = value_rt(f64, infinity),
    ok = value_rt(f64, neg_infinity),
    ok = value_rt(f32, 2.5),
    ok = value_rt(numeric, {12345, -2}),
    ok = value_rt(string, <<"hello">>),
    ok = value_rt({string, <<"UTF-8">>}, <<"hello">>),
    ok = value_rt(string_with_encoding, {<<"CP1251">>, <<"hi">>}),
    ok = value_rt(date, 7306),
    ok = value_rt(time, {12, 30, 0, 0}),
    ok = value_rt(timestamp, 1600000000000000),
    ok = value_rt(timestamp_with_timezone, {1600000000000000, 3600, <<"Europe/Berlin">>}),
    ok = value_rt(interval, {1, 2, 3}),
    ok = value_rt(bytes, <<1, 2, 3>>),
    ok = value_rt(bits, <<1, 2, 3>>),
    ok = value_rt(?BOOL, true),
    ok = value_rt(?BOOL, false).

%%====================================================================
%% Optional
%%====================================================================

optional_roundtrips(_Config) ->
    ok = value_rt({optional, i64}, absent),
    ok = value_rt({optional, i64}, 5),
    ok = value_rt({optional, string}, <<"x">>),
    %% wire null encodes to null and decodes back to absent
    null = gdbsp_value_json:encode_value({optional, i64}, absent),
    {ok, absent} = gdbsp_value_json:decode_value({optional, i64}, null).

%%====================================================================
%% Dynamic
%%====================================================================

dynamic_roundtrips(_Config) ->
    Json = #{<<"type">> => <<"i64">>, <<"value">> => <<"10">>},
    {ok, {value, {dynamic, i64}, 10}} =
        gdbsp_value_json:decode_field({dynamic, i64}, Json),
    Json = gdbsp_value_json:encode_field(
        {dynamic, i64}, {value, {dynamic, i64}, 10}).

%%====================================================================
%% Json
%%====================================================================

json_roundtrips(_Config) ->
    Obj = #{<<"k">> => <<"v">>},
    ok = field_rt(json, Obj),
    Arr = [<<"a">>, <<"b">>],
    ok = field_rt(json, Arr),
    ok = field_rt({json, dynamic}, Obj).

%%====================================================================
%% Closure
%%====================================================================

closure_roundtrips(_Config) ->
    ExprJson = #{<<"arg">> => <<"x">>},
    {ok, {arg, <<"x">>}} =
        gdbsp_value_json:decode_field({closure, [], i64}, ExprJson),
    ExprJson = gdbsp_value_json:encode_field(
        {closure, [], i64}, {arg, <<"x">>}).

%%====================================================================
%% Containers
%%====================================================================

container_roundtrips(_Config) ->
    ok = value_rt({array, i64, varsize}, [1, 2]),
    ok = value_rt({array, string, 2}, [<<"a">>, <<"b">>]),
    ok = value_rt({map, string, i64}, #{<<"k">> => 5}),
    ok = value_rt({map, i64, {array, i64, varsize}}, #{1 => [1, 2]}).

%%====================================================================
%% Full row round trip: decode → map_to_struct → encode typed values
%%====================================================================

row_roundtrip(_Config) ->
    Type = {struct, #{
        <<"id">> => i64,
        <<"name">> => {string, <<"UTF-8">>},
        <<"age">> => {optional, i64},
        <<"payload">> => dynamic,
        <<"meta">> => json,
        <<"tags">> => {array, i64, varsize}
    }, exact},

    Json = #{
        <<"id">> => <<"1">>,
        <<"name">> => <<"Alice">>,
        <<"age">> => <<"30">>,
        <<"payload">> => #{<<"type">> => <<"string">>, <<"value">> => <<"hi">>},
        <<"meta">> => #{<<"k">> => [1, 2]},
        <<"tags">> => [<<"7">>, <<"8">>]
    },

    {ok, Decoded} = gdbsp_value_json:decode_row(Type, Json),
    StructVal = gdbsp_struct:map_to_struct(Decoded, Type),
    {value, {struct, _, _}, TypedValues} = StructVal,

    Encoded = gdbsp_value_json:encode_row(Type, TypedValues),
    <<"1">> = maps:get(<<"id">>, Encoded),
    <<"Alice">> = maps:get(<<"name">>, Encoded),
    <<"30">> = maps:get(<<"age">>, Encoded),
    #{<<"type">> := <<"string">>, <<"value">> := <<"hi">>} =
        maps:get(<<"payload">>, Encoded),
    #{<<"k">> := [1.0, 2.0]} = maps:get(<<"meta">>, Encoded),
    [<<"7">>, <<"8">>] = maps:get(<<"tags">>, Encoded).

