%%%-------------------------------------------------------------------
%%% @doc Built-in function, aggregate, and constructor registry.
%%% Provides name resolution and overload tables for type inference.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_builtins).

-export([binop_fn_name/1, resolve_name/1]).
-export([lookup_fn/3, lookup_agg/2]).

-include("gdbsp_type.hrl").

-type impl_ref() :: {module(), atom(), non_neg_integer()} | undefined | special_implementation.
-type agg_ref() :: {impl_ref(), impl_ref(), impl_ref()}.

%%====================================================================
%% Name resolution
%%====================================================================

-spec binop_fn_name(atom()) -> binary().
binop_fn_name('+')  -> <<"math:add">>;
binop_fn_name('-')  -> <<"math:sub">>;
binop_fn_name('*')  -> <<"math:mul">>;
binop_fn_name('/')  -> <<"math:div">>;
binop_fn_name('%')  -> <<"math:mod">>;
binop_fn_name('=')  -> <<"eq">>;
binop_fn_name('!=') -> <<"neq">>;
binop_fn_name('<')  -> <<"lt">>;
binop_fn_name('>')  -> <<"gt">>;
binop_fn_name('<=') -> <<"lte">>;
binop_fn_name('>=') -> <<"gte">>;
binop_fn_name('++') -> <<"concat">>;
binop_fn_name('<<') -> <<"bits:shl">>;
binop_fn_name('>>') -> <<"bits:shr">>;
binop_fn_name('<<<') -> <<"bits:rotl">>;
binop_fn_name('>>>') -> <<"bits:rotr">>;
binop_fn_name('&')  -> <<"bits:and">>;
binop_fn_name('|')  -> <<"bits:or">>;
binop_fn_name('^')  -> <<"bits:xor">>.

-spec resolve_name(binary()) -> binary().
resolve_name(<<"date">>) -> <<"temporal:date">>;
resolve_name(<<"time">>) -> <<"temporal:time">>;
resolve_name(<<"timestamp">>) -> <<"temporal:timestamp">>;
resolve_name(<<"timestamp_with_timezone">>) -> <<"temporal:timestamp_with_timezone">>;
resolve_name(<<"interval">>) -> <<"temporal:interval">>;
resolve_name(<<"blob">>) -> <<"storage:blob">>;
resolve_name(<<"bytes">>) -> <<"bytes:bytes">>;
resolve_name(<<"bits">>) -> <<"bits:bits">>;
resolve_name(<<"struct">>) -> <<"struct:struct">>;
resolve_name(<<"sum">>) -> <<"agg:sum">>;
resolve_name(<<"count">>) -> <<"agg:count">>;
resolve_name(<<"min">>) -> <<"agg:min">>;
resolve_name(<<"max">>) -> <<"agg:max">>;
resolve_name(<<"avg">>) -> <<"agg:avg">>;
resolve_name(<<"xor">>) -> <<"agg:xor">>;
resolve_name(Other) -> Other.

%%====================================================================
%% Function lookup
%%====================================================================

-spec lookup_fn(binary(), [gdbsp_column_type()], [{binary(), gdbsp_column_type()}]) ->
    {ok, gdbsp_column_type(), impl_ref()} | {error, term()}.
lookup_fn(Name, PosTypes, KwPairs) ->
    FQN = resolve_name(Name),
    case fn_overloads(FQN) of
        {ok, Overloads} -> match_overloads(Overloads, PosTypes, KwPairs);
        {error, _} = E -> E
    end.

-spec lookup_agg(binary(), [gdbsp_column_type()]) ->
    {ok, gdbsp_column_type(), agg_ref()} | {error, term()}.
lookup_agg(Name, ArgTypes) ->
    FQN = resolve_name(Name),
    case agg_overloads(FQN) of
        {ok, Overloads} ->
            match_overloads(Overloads, ArgTypes, []);
        {error, _} = E -> E
    end.

%%====================================================================
%% Overload matching (exact type equality; `dynamic` matches any type)
%%====================================================================

match_overloads([], _PosTypes, _KwPairs) ->
    {error, no_matching_overload};
match_overloads([{_, Pos, Kw, Ret, Impl} | Rest], PosTypes, KwPairs) ->
    case match_pos(Pos, PosTypes) andalso match_kw(Kw, KwPairs) of
        true -> {ok, Ret, Impl};
        false -> match_overloads(Rest, PosTypes, KwPairs)
    end.

match_pos([], []) -> true;
match_pos([PT | PRest], [AT | ARest]) ->
    case exact_match(PT, AT) of
        true -> match_pos(PRest, ARest);
        false -> false
    end;
match_pos(_, _) -> false.

match_kw(Kw, KwPairs) ->
    maps:fold(fun(K, PT, true) ->
        case lists:keyfind(K, 1, KwPairs) of
            {K, AT} -> exact_match(PT, AT);
            false -> false
        end
    end, true, Kw).

%% ── exact_match ─────────────────────────────────────────────────────
%% Exact type equality; `dynamic` matches any type (wildcard).

exact_match(dynamic, _) -> true;
exact_match(_, dynamic) -> true;
exact_match(Same, Same) when is_atom(Same) -> true;
exact_match({optional, A}, {optional, B}) -> exact_match(A, B);
exact_match({closure, AP, AE}, {closure, BP, BE}) ->
    closure_params_exact_match(AP, BP) andalso exact_match(AE, BE);
exact_match({array, AE, _}, {array, BE, _}) -> exact_match(AE, BE);
exact_match({map, AK, AV}, {map, BK, BV}) ->
    exact_match(AK, BK) andalso exact_match(AV, BV);
exact_match({bytes, _}, {bytes, _}) -> true;
exact_match({bits, _}, {bits, _}) -> true;
exact_match({numeric, _, _}, {numeric, _, _}) -> true;
exact_match({string, _}, {string, _}) -> true;
exact_match({enum, _}, {enum, _}) -> true;
exact_match({dynamic, A}, {dynamic, B}) -> exact_match(A, B);
exact_match({json, A}, {json, B}) -> exact_match(A, B);
exact_match({type_var, _}, _) -> true;
exact_match(_, {type_var, _}) -> true;
exact_match({struct, _, _}, {struct, _, _}) -> true;
exact_match(_, _) -> false.

closure_params_exact_match(AP, BP) ->
    {APos, ANamed} = lists:partition(fun({Name, _}) -> Name =:= undefined end, AP),
    {BPos, BNamed} = lists:partition(fun({Name, _}) -> Name =:= undefined end, BP),
    APos =:= BPos andalso lists:sort(ANamed) =:= lists:sort(BNamed).

%%====================================================================
%% Implementation reference helpers
%%====================================================================

%% Map integer subtypes to the integer implementation name.
is_int_impl(i8)  -> integer;
is_int_impl(i16) -> integer;
is_int_impl(i32) -> integer;
is_int_impl(i64) -> integer;
is_int_impl(u8)  -> integer;
is_int_impl(u16) -> integer;
is_int_impl(u32) -> integer;
is_int_impl(u64) -> integer;
is_int_impl(T)   -> T.

math_fn(O, T1, T2) ->
    Fn = list_to_atom("math_" ++ atom_to_list(O) ++ "_"
                      ++ atom_to_list(T1) ++ "_" ++ atom_to_list(T2)),
    {gdbsp_math, Fn, 2}.

math1_fn(O, T) ->
    ImplT = is_int_impl(T),
    Fn = list_to_atom("math_" ++ atom_to_list(O) ++ "_" ++ atom_to_list(ImplT)),
    {gdbsp_math, Fn, 1}.

std_fn(O, T) ->
    Fn = list_to_atom("std_" ++ atom_to_list(O) ++ "_"
                      ++ atom_to_list(T) ++ "_" ++ atom_to_list(T)),
    {gdbsp_std, Fn, 2}.

dyn_fn(O) ->
    Fn = list_to_atom("std_" ++ atom_to_list(O) ++ "_dynamic_dynamic"),
    {gdbsp_std, Fn, 2}.

agg_ref(count, _Type) ->
    {{gdbsp_agg, agg_count_init, 3},
     {gdbsp_agg, agg_count_feed, 2},
     {gdbsp_agg, agg_count_result, 1}};
agg_ref(Op, {optional, T}) ->
    agg_ref(Op, list_to_atom("optional_" ++ atom_to_list(T)));
agg_ref(Op, Type) when is_atom(Type) ->
    {{gdbsp_agg, list_to_atom("agg_" ++ atom_to_list(Op) ++ "_"
                                    ++ atom_to_list(Type) ++ "_init"), 3},
     {gdbsp_agg, list_to_atom("agg_" ++ atom_to_list(Op) ++ "_"
                                    ++ atom_to_list(Type) ++ "_feed"), 2},
     {gdbsp_agg, list_to_atom("agg_" ++ atom_to_list(Op) ++ "_"
                                    ++ atom_to_list(Type) ++ "_result"), 1}}.

%%====================================================================
%% Function overloads
%%====================================================================

fn_overloads(<<"math:add">>) -> {ok, [
    {function, [i8, i8], #{}, i8, math_fn(add, i8, i8)},
    {function, [i16, i16], #{}, i16, math_fn(add, i16, i16)},
    {function, [i32, i32], #{}, i32, math_fn(add, i32, i32)},
    {function, [i64, i64], #{}, i64, math_fn(add, i64, i64)},
    {function, [u8, u8], #{}, u8, math_fn(add, u8, u8)},
    {function, [u16, u16], #{}, u16, math_fn(add, u16, u16)},
    {function, [u32, u32], #{}, u32, math_fn(add, u32, u32)},
    {function, [u64, u64], #{}, u64, math_fn(add, u64, u64)},
    {function, [integer, integer], #{}, integer, math_fn(add, integer, integer)},
    {function, [f64, f64], #{}, f64, math_fn(add, f64, f64)},
    {function, [numeric, numeric], #{}, numeric, math_fn(add, numeric, numeric)},
    {function, [interval, interval], #{}, interval,
     {gdbsp_temporal, temporal_add_interval_interval, 2}}
]};
fn_overloads(<<"math:sub">>) -> {ok, [
    {function, [i8, i8], #{}, i8, math_fn(sub, i8, i8)},
    {function, [i16, i16], #{}, i16, math_fn(sub, i16, i16)},
    {function, [i32, i32], #{}, i32, math_fn(sub, i32, i32)},
    {function, [i64, i64], #{}, i64, math_fn(sub, i64, i64)},
    {function, [u8, u8], #{}, u8, math_fn(sub, u8, u8)},
    {function, [u16, u16], #{}, u16, math_fn(sub, u16, u16)},
    {function, [u32, u32], #{}, u32, math_fn(sub, u32, u32)},
    {function, [u64, u64], #{}, u64, math_fn(sub, u64, u64)},
    {function, [integer, integer], #{}, integer, math_fn(sub, integer, integer)},
    {function, [f64, f64], #{}, f64, math_fn(sub, f64, f64)},
    {function, [numeric, numeric], #{}, numeric, math_fn(sub, numeric, numeric)},
    {function, [timestamp, timestamp], #{}, interval,
     {gdbsp_temporal, temporal_sub_ts_ts, 2}},
    {function, [timestamp_with_timezone, timestamp_with_timezone], #{}, interval,
     {gdbsp_temporal, temporal_sub_tstz_tstz, 2}},
    {function, [date, date], #{}, interval,
     {gdbsp_temporal, temporal_sub_date_date, 2}},
    {function, [time, time], #{}, interval,
     {gdbsp_temporal, temporal_sub_time_time, 2}}
]};
fn_overloads(<<"math:mul">>) -> {ok, [
    {function, [i8, i8], #{}, i8, math_fn(mul, i8, i8)},
    {function, [i16, i16], #{}, i16, math_fn(mul, i16, i16)},
    {function, [i32, i32], #{}, i32, math_fn(mul, i32, i32)},
    {function, [i64, i64], #{}, i64, math_fn(mul, i64, i64)},
    {function, [u8, u8], #{}, u8, math_fn(mul, u8, u8)},
    {function, [u16, u16], #{}, u16, math_fn(mul, u16, u16)},
    {function, [u32, u32], #{}, u32, math_fn(mul, u32, u32)},
    {function, [u64, u64], #{}, u64, math_fn(mul, u64, u64)},
    {function, [integer, integer], #{}, integer, math_fn(mul, integer, integer)},
    {function, [f64, f64], #{}, f64, math_fn(mul, f64, f64)},
    {function, [numeric, numeric], #{}, numeric, math_fn(mul, numeric, numeric)}
]};
fn_overloads(<<"math:div">>) -> {ok, [
    {function, [i8, i8], #{}, i8, math_fn('div', i8, i8)},
    {function, [i16, i16], #{}, i16, math_fn('div', i16, i16)},
    {function, [i32, i32], #{}, i32, math_fn('div', i32, i32)},
    {function, [i64, i64], #{}, i64, math_fn('div', i64, i64)},
    {function, [u8, u8], #{}, u8, math_fn('div', u8, u8)},
    {function, [u16, u16], #{}, u16, math_fn('div', u16, u16)},
    {function, [u32, u32], #{}, u32, math_fn('div', u32, u32)},
    {function, [u64, u64], #{}, u64, math_fn('div', u64, u64)},
    {function, [integer, integer], #{}, integer, math_fn('div', integer, integer)},
    {function, [f64, f64], #{}, f64, math_fn('div', f64, f64)},
    {function, [numeric, numeric], #{}, numeric, math_fn('div', numeric, numeric)}
]};
fn_overloads(<<"math:mod">>) -> {ok, [
    {function, [i8, i8], #{}, i8, math_fn(mod, i8, i8)},
    {function, [i16, i16], #{}, i16, math_fn(mod, i16, i16)},
    {function, [i32, i32], #{}, i32, math_fn(mod, i32, i32)},
    {function, [i64, i64], #{}, i64, math_fn(mod, i64, i64)},
    {function, [u8, u8], #{}, u8, math_fn(mod, u8, u8)},
    {function, [u16, u16], #{}, u16, math_fn(mod, u16, u16)},
    {function, [u32, u32], #{}, u32, math_fn(mod, u32, u32)},
    {function, [u64, u64], #{}, u64, math_fn(mod, u64, u64)},
    {function, [integer, integer], #{}, integer, math_fn(mod, integer, integer)}
]};

%% ── math: unary ─────────────────────────────────────────────────────
fn_overloads(<<"math:neg">>) -> {ok, unary_overloads(neg)};
fn_overloads(<<"math:abs">>) -> {ok, unary_overloads(abs)};
fn_overloads(<<"math:sign">>) -> {ok, sign_overloads()};

%% ── math: float detection ───────────────────────────────────────────
fn_overloads(<<"math:is_nan">>) -> {ok, [
    {function, [f32], #{}, {enum, [<<"false">>, <<"true">>]}, math1_fn(is_nan, f32)},
    {function, [f64], #{}, {enum, [<<"false">>, <<"true">>]}, math1_fn(is_nan, f64)}
]};
fn_overloads(<<"math:is_infinite">>) -> {ok, [
    {function, [f32], #{}, {enum, [<<"false">>, <<"true">>]}, math1_fn(is_infinite, f32)},
    {function, [f64], #{}, {enum, [<<"false">>, <<"true">>]}, math1_fn(is_infinite, f64)}
]};
fn_overloads(<<"math:is_finite">>) -> {ok, [
    {function, [f32], #{}, {enum, [<<"false">>, <<"true">>]}, math1_fn(is_finite, f32)},
    {function, [f64], #{}, {enum, [<<"false">>, <<"true">>]}, math1_fn(is_finite, f64)}
]};

%% ── math: exponentials and constants ────────────────────────────────
fn_overloads(<<"math:pow">>) -> {ok, [
    {function, [f64, f64], #{}, f64, {gdbsp_math, math_pow_f64_f64, 2}}
]};
fn_overloads(<<"math:sqrt">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_sqrt_f64, 1}}
]};
fn_overloads(<<"math:ln">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_ln_f64, 1}}
]};
fn_overloads(<<"math:log">>) -> {ok, [
    {function, [], #{<<"value">> => f64, <<"base">> => f64}, f64,
     {gdbsp_math, math_log_value_base, 2}}
]};
fn_overloads(<<"math:log10">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_log10_f64, 1}}
]};
fn_overloads(<<"math:pi">>) -> {ok, [
    {function, [], #{}, f64, {gdbsp_math, math_pi, 0}}
]};

%% ── math: rounding ──────────────────────────────────────────────────
fn_overloads(<<"math:ceil">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_ceil_f64, 1}}
]};
fn_overloads(<<"math:floor">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_floor_f64, 1}}
]};
fn_overloads(<<"math:round">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_round_f64, 1}}
]};

%% ── math: trigonometry ──────────────────────────────────────────────
fn_overloads(<<"math:sin">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_sin_f64, 1}}
]};
fn_overloads(<<"math:cos">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_cos_f64, 1}}
]};
fn_overloads(<<"math:tan">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_tan_f64, 1}}
]};
fn_overloads(<<"math:asin">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_asin_f64, 1}}
]};
fn_overloads(<<"math:acos">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_acos_f64, 1}}
]};
fn_overloads(<<"math:atan">>) -> {ok, [
    {function, [f64], #{}, f64, {gdbsp_math, math_atan_f64, 1}}
]};
fn_overloads(<<"math:atan2">>) -> {ok, [
    {function, [f64, f64], #{}, f64, {gdbsp_math, math_atan2_f64_f64, 2}}
]};

%% ── math: array statistics ──────────────────────────────────────────
fn_overloads(<<"math:min">>) -> {ok, [
    {function, [{array, dynamic, varsize}], #{}, dynamic,
     {gdbsp_math, math_min_array, 1}}
]};
fn_overloads(<<"math:max">>) -> {ok, [
    {function, [{array, dynamic, varsize}], #{}, dynamic,
     {gdbsp_math, math_max_array, 1}}
]};

%% ── string: inspection ──────────────────────────────────────────────
fn_overloads(<<"string:length">>) -> {ok, [
    {function, [string], #{}, integer, {gdbsp_string, string_length, 1}}
]};
fn_overloads(<<"string:starts_with">>) -> {ok, [
    {function, [string], #{<<"prefix">> => string}, {enum, [<<"false">>, <<"true">>]},
     {gdbsp_string, string_starts_with_prefix, 2}}
]};
fn_overloads(<<"string:ends_with">>) -> {ok, [
    {function, [string], #{<<"suffix">> => string}, {enum, [<<"false">>, <<"true">>]},
     {gdbsp_string, string_ends_with_suffix, 2}}
]};
fn_overloads(<<"string:contains">>) -> {ok, [
    {function, [string], #{<<"sub">> => string}, {enum, [<<"false">>, <<"true">>]},
     {gdbsp_string, string_contains_sub, 2}}
]};

%% ── string: case ────────────────────────────────────────────────────
fn_overloads(<<"string:upper">>) -> {ok, [
    {function, [string], #{}, string, {gdbsp_string, string_upper, 1}}
]};
fn_overloads(<<"string:lower">>) -> {ok, [
    {function, [string], #{}, string, {gdbsp_string, string_lower, 1}}
]};

%% ── string: trim ────────────────────────────────────────────────────
fn_overloads(<<"string:trim">>) -> {ok, [
    {function, [string], #{}, string, {gdbsp_string, string_trim, 1}}
]};
fn_overloads(<<"string:ltrim">>) -> {ok, [
    {function, [string], #{}, string, {gdbsp_string, string_ltrim, 1}}
]};
fn_overloads(<<"string:rtrim">>) -> {ok, [
    {function, [string], #{}, string, {gdbsp_string, string_rtrim, 1}}
]};

fn_overloads(<<"string:at">>) -> {ok, [
    {function, [string], #{<<"index">> => i64}, string,
     {gdbsp_string, string_at_index, 2}}
]};
fn_overloads(<<"string:slice">>) -> {ok, [
    {function, [string], #{<<"start">> => i64, <<"stop">> => i64, <<"step">> => i64}, string,
     {gdbsp_string, string_slice_start_stop_step, 4}},
    {function, [string], #{<<"start">> => i64, <<"stop">> => i64}, string,
     {gdbsp_string, string_slice_start_stop, 3}},
    {function, [string], #{<<"stop">> => i64}, string,
     {gdbsp_string, string_slice_stop, 2}}
]};
fn_overloads(<<"string:substring">>) -> {ok, [
    {function, [string], #{<<"start">> => i64, <<"length">> => i64}, string,
     {gdbsp_string, string_substring_start_length, 3}},
    {function, [string], #{<<"start">> => i64}, string,
     {gdbsp_string, string_substring_start, 2}}
]};
fn_overloads(<<"string:replace">>) -> {ok, [
    {function, [string], #{<<"from">> => string, <<"to">> => string}, string,
     {gdbsp_string, string_replace_from_to, 3}}
]};
fn_overloads(<<"string:split">>) -> {ok, [
    {function, [string], #{<<"delimiter">> => string}, {array, string, varsize},
     {gdbsp_string, string_split_delimiter, 2}}
]};

%% ── array: inspection ───────────────────────────────────────────────
fn_overloads(<<"array:size">>) -> {ok, [
    {function, [{array, dynamic, varsize}], #{}, integer,
     {gdbsp_array, array_size, 1}}
]};

%% ── array: manipulation ─────────────────────────────────────────────
fn_overloads(<<"array:append">>) -> {ok, [
    {function, [{array, dynamic, varsize}], #{<<"element">> => dynamic}, {array, dynamic, varsize},
     {gdbsp_array, array_append_element, 2}}
]};
fn_overloads(<<"array:prepend">>) -> {ok, [
    {function, [{array, dynamic, varsize}], #{<<"element">> => dynamic}, {array, dynamic, varsize},
     {gdbsp_array, array_prepend_element, 2}}
]};
fn_overloads(<<"array:contains">>) -> {ok, [
    {function, [{array, dynamic, varsize}], #{<<"element">> => dynamic}, {enum, [<<"false">>, <<"true">>]},
     {gdbsp_array, array_contains_element, 2}}
]};
fn_overloads(<<"array:reverse">>) -> {ok, [
    {function, [{array, dynamic, varsize}], #{}, {array, dynamic, varsize},
     {gdbsp_array, array_reverse, 1}}
]};

%% ── array: sort ─────────────────────────────────────────────────────
fn_overloads(<<"array:sort">>) -> {ok, [
    {function, [{array, dynamic, varsize}], #{<<"direction">> => string}, {array, dynamic, varsize},
     {gdbsp_array, array_sort_direction, 2}},
    {function, [{array, dynamic, varsize}], #{}, {array, dynamic, varsize},
     {gdbsp_array, array_sort, 1}}
]};

%% ── array: index and slice ──────────────────────────────────────────
fn_overloads(<<"array:at">>) -> {ok, [
    {function, [{array, dynamic, varsize}, dynamic], #{}, dynamic,
     {gdbsp_array, array_at_pos, 2}},
    {function, [{array, dynamic, varsize}], #{<<"index">> => dynamic}, dynamic,
     {gdbsp_array, array_at_index_kw, 2}},
    {function, [{array, dynamic, varsize}], #{<<"index">> => i64}, dynamic,
     {gdbsp_array, array_at_index, 2}}
]};
fn_overloads(<<"array:slice">>) -> {ok, [
    {function, [{array, dynamic, varsize}, dynamic, dynamic, dynamic], #{}, {array, dynamic, varsize},
     {gdbsp_array, array_slice_pos, 4}},
    {function, [{array, dynamic, varsize}, dynamic, dynamic], #{}, {array, dynamic, varsize},
     {gdbsp_array, array_slice_pos, 3}},
    {function, [{array, dynamic, varsize}, dynamic], #{}, {array, dynamic, varsize},
     {gdbsp_array, array_slice_pos, 2}},
    {function, [{array, dynamic, varsize}],
     #{<<"start">> => i64, <<"stop">> => i64, <<"step">> => i64},
     {array, dynamic, varsize},
     {gdbsp_array, array_slice_start_stop_step, 4}},
    {function, [{array, dynamic, varsize}], #{<<"start">> => i64, <<"stop">> => i64},
     {array, dynamic, varsize},
     {gdbsp_array, array_slice_start_stop, 3}},
    {function, [{array, dynamic, varsize}], #{<<"stop">> => i64}, {array, dynamic, varsize},
      {gdbsp_array, array_slice_stop, 2}}
]};

%% ── concat: string, array, bytes, bits ──────────────────────────────
fn_overloads(<<"string:concat">>) -> {ok, [
    {function, [string, string], #{}, string,
     {gdbsp_string, string_concat_a_b, 2}}
]};
fn_overloads(<<"array:concat">>) -> {ok, [
    {function, [{array, dynamic, varsize}, {array, dynamic, varsize}], #{}, {array, dynamic, varsize},
     {gdbsp_array, array_concat_a_b, 2}}
]};
fn_overloads(<<"bytes:concat">>) -> {ok, [
    {function, [bytes, bytes], #{}, bytes,
     {gdbsp_bytes, bytes_concat_a_b, 2}}
]};
fn_overloads(<<"bits:concat">>) -> {ok, [
    {function, [bits, bits], #{}, bits,
     {gdbsp_bits, bits_concat_a_b, 2}}
]};

%% ── concat: type-dispatched (++ operator) ───────────────────────────
fn_overloads(<<"concat">>) -> {ok, [
    {function, [string, string], #{}, string,
     {gdbsp_string, string_concat_a_b, 2}},
    {function, [{array, dynamic, varsize}, {array, dynamic, varsize}], #{}, {array, dynamic, varsize},
     {gdbsp_array, array_concat_a_b, 2}},
    {function, [bytes, bytes], #{}, bytes,
     {gdbsp_bytes, bytes_concat_a_b, 2}},
    {function, [bits, bits], #{}, bits,
     {gdbsp_bits, bits_concat_a_b, 2}},
    {function, [dynamic, dynamic], #{}, dynamic,
     {gdbsp_dyn_type, dyn_type_concat, 2}}
]};

%% ── map: inspection ─────────────────────────────────────────────────
fn_overloads(<<"map:size">>) -> {ok, [
    {function, [{map, dynamic, dynamic}], #{}, integer,
     {gdbsp_map, map_size, 1}}
]};

%% ── map: key/value access ───────────────────────────────────────────
fn_overloads(<<"map:keys">>) -> {ok, [
    {function, [{map, dynamic, dynamic}], #{}, {array, dynamic, varsize},
     {gdbsp_map, map_keys, 1}}
]};
fn_overloads(<<"map:values">>) -> {ok, [
    {function, [{map, dynamic, dynamic}], #{}, {array, dynamic, varsize},
     {gdbsp_map, map_values, 1}}
]};
fn_overloads(<<"map:has">>) -> {ok, [
    {function, [{map, dynamic, dynamic}],
     #{<<"key">> => dynamic}, {enum, [<<"false">>, <<"true">>]},
     {gdbsp_map, map_has, 2}}
]};
fn_overloads(<<"map:get">>) -> {ok, [
    {function, [{map, dynamic, dynamic}],
     #{<<"key">> => dynamic}, dynamic,
     {gdbsp_map, map_get, 2}}
]};

%% ── map: manipulation ───────────────────────────────────────────────
fn_overloads(<<"map:without">>) -> {ok, [
    {function, [{map, dynamic, dynamic}],
     #{<<"keys">> => {array, dynamic, varsize}},
     {map, dynamic, dynamic},
     {gdbsp_map, map_without, 2}}
]};
fn_overloads(<<"map:merge">>) -> {ok, [
    {function, [{map, dynamic, dynamic}, {map, dynamic, dynamic}], #{}, {map, dynamic, dynamic},
     {gdbsp_map, map_merge, 2}}
]};

%% ── bytes: inspection ───────────────────────────────────────────────
fn_overloads(<<"bytes:size">>) -> {ok, [
    {function, [bytes], #{}, integer,
     {gdbsp_bytes, bytes_size, 1}}
]};

%% ── bytes: encoding ─────────────────────────────────────────────────
fn_overloads(<<"bytes:to_hex">>) -> {ok, [
    {function, [bytes], #{}, string,
     {gdbsp_bytes, bytes_to_hex, 1}}
]};

%% ── bytes: index and slice ──────────────────────────────────────────
fn_overloads(<<"bytes:at">>) -> {ok, [
    {function, [bytes], #{<<"index">> => i64}, {bytes, 1},
     {gdbsp_bytes, bytes_at_index, 2}}
]};
fn_overloads(<<"bytes:slice">>) -> {ok, [
    {function, [bytes],
     #{<<"start">> => i64, <<"stop">> => i64, <<"step">> => i64}, bytes,
     {gdbsp_bytes, bytes_slice_start_stop_step, 4}},
    {function, [bytes], #{<<"start">> => i64, <<"stop">> => i64}, bytes,
     {gdbsp_bytes, bytes_slice_start_stop, 3}},
    {function, [bytes], #{<<"stop">> => i64}, bytes,
     {gdbsp_bytes, bytes_slice_stop, 2}}
]};

%% ── crypto: hashing — hex output ─────────────────────────────────────
fn_overloads(<<"crypto:sha256">>) -> {ok, [
    {function, [bytes], #{}, string, {gdbsp_crypto, crypto_sha256, 1}},
    {function, [string], #{}, string, {gdbsp_crypto, crypto_sha256, 1}}
]};
fn_overloads(<<"crypto:sha1">>) -> {ok, [
    {function, [bytes], #{}, string, {gdbsp_crypto, crypto_sha1, 1}},
    {function, [string], #{}, string, {gdbsp_crypto, crypto_sha1, 1}}
]};
fn_overloads(<<"crypto:git_sha1">>) -> {ok, [
    {function, [bytes], #{}, string, {gdbsp_crypto, crypto_git_sha1, 1}},
    {function, [string], #{}, string, {gdbsp_crypto, crypto_git_sha1, 1}}
]};
fn_overloads(<<"crypto:md5">>) -> {ok, [
    {function, [bytes], #{}, string, {gdbsp_crypto, crypto_md5, 1}},
    {function, [string], #{}, string, {gdbsp_crypto, crypto_md5, 1}}
]};

%% ── crypto: hashing — raw output ─────────────────────────────────────
fn_overloads(<<"crypto:sha256_raw">>) -> {ok, [
    {function, [bytes], #{}, {bytes, 32}, {gdbsp_crypto, crypto_sha256_raw, 1}},
    {function, [string], #{}, {bytes, 32}, {gdbsp_crypto, crypto_sha256_raw, 1}}
]};
fn_overloads(<<"crypto:sha1_raw">>) -> {ok, [
    {function, [bytes], #{}, {bytes, 20}, {gdbsp_crypto, crypto_sha1_raw, 1}},
    {function, [string], #{}, {bytes, 20}, {gdbsp_crypto, crypto_sha1_raw, 1}}
]};
fn_overloads(<<"crypto:git_sha1_raw">>) -> {ok, [
    {function, [bytes], #{}, {bytes, 20}, {gdbsp_crypto, crypto_git_sha1_raw, 1}},
    {function, [string], #{}, {bytes, 20}, {gdbsp_crypto, crypto_git_sha1_raw, 1}}
]};
fn_overloads(<<"crypto:md5_raw">>) -> {ok, [
    {function, [bytes], #{}, {bytes, 16}, {gdbsp_crypto, crypto_md5_raw, 1}},
    {function, [string], #{}, {bytes, 16}, {gdbsp_crypto, crypto_md5_raw, 1}}
]};

%% ── bytes: constructor ──────────────────────────────────────────────
fn_overloads(<<"bytes:bytes">>) -> {ok, [
    {function, [], #{<<"hex">> => string}, bytes,
     {gdbsp_bytes, bytes_constructor_hex, 1}},
    {function, [], #{<<"b">> => bits}, bytes,
     {gdbsp_bytes, bytes_constructor_bits, 1}}
]};

%% ── boolean logic ───────────────────────────────────────────────────
fn_overloads(<<"and">>) -> {ok, [{function, [{enum, [<<"false">>, <<"true">>]}, {enum, [<<"false">>, <<"true">>]}], #{}, {enum, [<<"false">>, <<"true">>]},
                                   {gdbsp_std, std_and_boolean_boolean, 2}}]};
fn_overloads(<<"or">>) -> {ok, [{function, [{enum, [<<"false">>, <<"true">>]}, {enum, [<<"false">>, <<"true">>]}], #{}, {enum, [<<"false">>, <<"true">>]},
                                   {gdbsp_std, std_or_boolean_boolean, 2}}]};
fn_overloads(<<"not">>) -> {ok, [{function, [{enum, [<<"false">>, <<"true">>]}], #{}, {enum, [<<"false">>, <<"true">>]},
                                   {gdbsp_std, std_not_boolean, 1}}]};

%% ── comparison ops ──────────────────────────────────────────────────
fn_overloads(<<"eq">>) ->
    {ok, comparison_overloads(eq) ++ [{function, [{enum, []}, {enum, []}], #{}, {enum, [<<"false">>, <<"true">>]},
                                       {gdbsp_std, std_eq_enum_enum, 2}}]};
fn_overloads(<<"neq">>) ->
    {ok, comparison_overloads(neq) ++ [{function, [{enum, []}, {enum, []}], #{}, {enum, [<<"false">>, <<"true">>]},
                                        {gdbsp_std, std_neq_enum_enum, 2}}]};
fn_overloads(<<"lt">>) -> {ok, comparison_overloads(lt)};
fn_overloads(<<"gt">>) -> {ok, comparison_overloads(gt)};
fn_overloads(<<"lte">>) -> {ok, comparison_overloads(lte)};
fn_overloads(<<"gte">>) -> {ok, comparison_overloads(gte)};

%% ── string: comparison ──────────────────────────────────────────────
fn_overloads(<<"string:eq">>) -> {ok, [{function, [string, string], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(eq, string)}]};
fn_overloads(<<"string:neq">>) -> {ok, [{function, [string, string], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(neq, string)}]};
fn_overloads(<<"string:lt">>) -> {ok, [{function, [string, string], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(lt, string)}]};
fn_overloads(<<"string:gt">>) -> {ok, [{function, [string, string], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(gt, string)}]};
fn_overloads(<<"string:lte">>) -> {ok, [{function, [string, string], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(lte, string)}]};
fn_overloads(<<"string:gte">>) -> {ok, [{function, [string, string], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(gte, string)}]};

%% ── bytes: comparison ───────────────────────────────────────────────
fn_overloads(<<"bytes:eq">>) -> {ok, [{function, [bytes, bytes], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(eq, bytes)}]};
fn_overloads(<<"bytes:neq">>) -> {ok, [{function, [bytes, bytes], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(neq, bytes)}]};
fn_overloads(<<"bytes:lt">>) -> {ok, [{function, [bytes, bytes], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(lt, bytes)}]};
fn_overloads(<<"bytes:gt">>) -> {ok, [{function, [bytes, bytes], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(gt, bytes)}]};
fn_overloads(<<"bytes:lte">>) -> {ok, [{function, [bytes, bytes], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(lte, bytes)}]};
fn_overloads(<<"bytes:gte">>) -> {ok, [{function, [bytes, bytes], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(gte, bytes)}]};

%% ── bits: comparison ────────────────────────────────────────────────
fn_overloads(<<"bits:eq">>) -> {ok, [{function, [bits, bits], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(eq, bits)}]};
fn_overloads(<<"bits:neq">>) -> {ok, [{function, [bits, bits], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(neq, bits)}]};
fn_overloads(<<"bits:lt">>) -> {ok, [{function, [bits, bits], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(lt, bits)}]};
fn_overloads(<<"bits:gt">>) -> {ok, [{function, [bits, bits], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(gt, bits)}]};
fn_overloads(<<"bits:lte">>) -> {ok, [{function, [bits, bits], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(lte, bits)}]};
fn_overloads(<<"bits:gte">>) -> {ok, [{function, [bits, bits], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(gte, bits)}]};

%% ── integer: comparison (all integer types) ─────────────────────────
fn_overloads(<<"integer:eq">>) -> {ok, integer_comparison_overloads(eq)};
fn_overloads(<<"integer:neq">>) -> {ok, integer_comparison_overloads(neq)};
fn_overloads(<<"integer:lt">>) -> {ok, integer_comparison_overloads(lt)};
fn_overloads(<<"integer:gt">>) -> {ok, integer_comparison_overloads(gt)};
fn_overloads(<<"integer:lte">>) -> {ok, integer_comparison_overloads(lte)};
fn_overloads(<<"integer:gte">>) -> {ok, integer_comparison_overloads(gte)};

%% ── float: comparison ───────────────────────────────────────────────
fn_overloads(<<"float:eq">>) -> {ok, float_comparison_overloads(eq)};
fn_overloads(<<"float:neq">>) -> {ok, float_comparison_overloads(neq)};
fn_overloads(<<"float:lt">>) -> {ok, float_comparison_overloads(lt)};
fn_overloads(<<"float:gt">>) -> {ok, float_comparison_overloads(gt)};
fn_overloads(<<"float:lte">>) -> {ok, float_comparison_overloads(lte)};
fn_overloads(<<"float:gte">>) -> {ok, float_comparison_overloads(gte)};

%% ── numeric: comparison ─────────────────────────────────────────────
fn_overloads(<<"numeric:eq">>) -> {ok, numeric_comparison_overloads(eq)};
fn_overloads(<<"numeric:neq">>) -> {ok, numeric_comparison_overloads(neq)};
fn_overloads(<<"numeric:lt">>) -> {ok, numeric_comparison_overloads(lt)};
fn_overloads(<<"numeric:gt">>) -> {ok, numeric_comparison_overloads(gt)};
fn_overloads(<<"numeric:lte">>) -> {ok, numeric_comparison_overloads(lte)};
fn_overloads(<<"numeric:gte">>) -> {ok, numeric_comparison_overloads(gte)};

%% ── boolean: logic ───────────────────────────────────────────────────
fn_overloads(<<"boolean:not">>) -> {ok, [
    {function, [{enum, [<<"false">>, <<"true">>]}], #{}, {enum, [<<"false">>, <<"true">>]}, {gdbsp_std, std_not_boolean, 1}}
]};
fn_overloads(<<"boolean:and">>) -> {ok, [
    {function, [{enum, [<<"false">>, <<"true">>]}, {enum, [<<"false">>, <<"true">>]}], #{}, {enum, [<<"false">>, <<"true">>]},
     {gdbsp_std, std_and_boolean_boolean, 2}}
]};
fn_overloads(<<"boolean:or">>) -> {ok, [
    {function, [{enum, [<<"false">>, <<"true">>]}, {enum, [<<"false">>, <<"true">>]}], #{}, {enum, [<<"false">>, <<"true">>]},
     {gdbsp_std, std_or_boolean_boolean, 2}}
]};

%% ── bits: inspection ────────────────────────────────────────────────
fn_overloads(<<"bits:size">>) -> {ok, [
    {function, [bits], #{}, integer,
     {gdbsp_bits, bits_size, 1}}
]};

%% ── bits: index and slice ───────────────────────────────────────────
fn_overloads(<<"bits:at">>) -> {ok, [
    {function, [bits], #{<<"index">> => i64}, {bits, 1},
     {gdbsp_bits, bits_at_index, 2}}
]};
fn_overloads(<<"bits:slice">>) -> {ok, [
    {function, [bits],
     #{<<"start">> => i64, <<"stop">> => i64, <<"step">> => i64}, bits,
     {gdbsp_bits, bits_slice_start_stop_step, 4}},
    {function, [bits], #{<<"start">> => i64, <<"stop">> => i64}, bits,
     {gdbsp_bits, bits_slice_start_stop, 3}},
    {function, [bits], #{<<"stop">> => i64}, bits,
     {gdbsp_bits, bits_slice_stop, 2}}
]};

%% ── bits: bitwise ───────────────────────────────────────────────────
fn_overloads(<<"bits:and">>) -> {ok, [
    {function, [bits, bits], #{}, bits,
     {gdbsp_bits, bits_and, 2}}
]};
fn_overloads(<<"bits:or">>) -> {ok, [
    {function, [bits, bits], #{}, bits,
     {gdbsp_bits, bits_or, 2}}
]};
fn_overloads(<<"bits:xor">>) -> {ok, [
    {function, [bits, bits], #{}, bits,
     {gdbsp_bits, bits_xor, 2}}
]};
fn_overloads(<<"bits:not">>) -> {ok, [
    {function, [bits], #{}, bits,
     {gdbsp_bits, bits_not, 1}}
]};

%% ── bits: shift and rotate ──────────────────────────────────────────
fn_overloads(<<"bits:shl">>) -> {ok, [
    {function, [bits, integer], #{}, bits,
     {gdbsp_bits, bits_shl, 2}}
]};
fn_overloads(<<"bits:shr">>) -> {ok, [
    {function, [bits, integer], #{}, bits,
     {gdbsp_bits, bits_shr, 2}}
]};
fn_overloads(<<"bits:rotl">>) -> {ok, [
    {function, [bits, integer], #{}, bits,
     {gdbsp_bits, bits_rotl, 2}}
]};
fn_overloads(<<"bits:rotr">>) -> {ok, [
    {function, [bits, integer], #{}, bits,
     {gdbsp_bits, bits_rotr, 2}}
]};

%% ── bits: constructors ──────────────────────────────────────────────
fn_overloads(<<"bits:bits">>) -> {ok, [
    {function, [], #{<<"b">> => bytes}, bits,
     {gdbsp_bits, bits_constructor_bytes, 1}},
    {function, [], #{<<"s">> => string}, bits,
     {gdbsp_bits, bits_constructor_string, 1}},
    {function, [], #{<<"hex">> => string}, bits,
     {gdbsp_bits, bits_constructor_hex, 1}}
]};

%% ── struct: operations ───────────────────────────────────────────────
fn_overloads(<<"struct:struct">>) -> {ok, [
    {function, [type, {map, dynamic, dynamic}], #{}, dynamic,
     {gdbsp_struct, struct_constructor, 2}}
]};
fn_overloads(<<"struct:get">>) -> {ok, [
    {function, [{type_var, <<"S">>}], #{<<"key">> => string}, {type_var, <<"V">>},
     {gdbsp_struct, struct_get, 2}}
]};
fn_overloads(<<"struct:set">>) -> {ok, [
    {function, [{type_var, <<"S">>}, {type_var, <<"V">>}],
     #{<<"key">> => string}, {type_var, <<"S">>},
     {gdbsp_struct, struct_set, 3}}
]};

%% ── temporal constructors ───────────────────────────────────────────
fn_overloads(<<"temporal:date">>) -> {ok, [
    {function, [string], #{}, date,
     {gdbsp_temporal, temporal_date_string, 1}},
    {function, [timestamp], #{}, date,
     {gdbsp_temporal, temporal_date_ts, 1}},
    {function, [timestamp_with_timezone], #{}, date,
     {gdbsp_temporal, temporal_date_tstz, 1}},
    {function, [], #{<<"year">> => i64, <<"month">> => i64, <<"day">> => i64}, date,
     {gdbsp_temporal, temporal_date_ymd, 3}},
    {function, [], #{<<"year">> => i64, <<"month">> => i64}, date,
     {gdbsp_temporal, temporal_date_ym, 2}},
    {function, [], #{<<"year">> => i64}, date,
     {gdbsp_temporal, temporal_date_y, 1}},
    {function, [], #{}, date,
     {gdbsp_temporal, temporal_date_empty, 0}}
]};
fn_overloads(<<"temporal:time">>) -> {ok, [
    {function, [string], #{}, time,
     {gdbsp_temporal, temporal_time_string, 1}},
    {function, [timestamp], #{}, time,
     {gdbsp_temporal, temporal_time_ts, 1}},
    {function, [timestamp_with_timezone], #{}, time,
     {gdbsp_temporal, temporal_time_tstz, 1}},
    {function, [],
     #{<<"hour">> => i64, <<"minute">> => i64, <<"second">> => i64,
       <<"microsecond">> => i64}, time,
     {gdbsp_temporal, temporal_time_hmsm, 4}},
    {function, [], #{<<"hour">> => i64, <<"minute">> => i64, <<"second">> => i64}, time,
     {gdbsp_temporal, temporal_time_hms, 3}},
    {function, [], #{<<"hour">> => i64, <<"minute">> => i64}, time,
     {gdbsp_temporal, temporal_time_hm, 2}},
    {function, [], #{<<"hour">> => i64}, time,
     {gdbsp_temporal, temporal_time_h, 1}},
    {function, [], #{}, time,
     {gdbsp_temporal, temporal_time_empty, 0}}
]};
fn_overloads(<<"temporal:timestamp">>) -> {ok, [
    {function, [string], #{}, timestamp,
     {gdbsp_temporal, temporal_ts_string, 1}},
    {function, [timestamp_with_timezone], #{}, timestamp,
     {gdbsp_temporal, temporal_ts_tstz, 1}},
    {function, [], #{<<"date">> => date, <<"time">> => time}, timestamp,
     {gdbsp_temporal, temporal_ts_dt, 2}},
    {function, [], #{<<"epoch_microseconds">> => i64}, timestamp,
     {gdbsp_temporal, temporal_ts_epoch_micros, 1}},
    {function, [], #{}, timestamp,
     {gdbsp_temporal, temporal_ts_empty, 0}}
]};
fn_overloads(<<"temporal:timestamp_with_timezone">>) -> {ok, [
    {function, [string], #{}, timestamp_with_timezone,
     {gdbsp_temporal, temporal_tstz_string, 1}},
    {function, [timestamp],
     #{<<"zone">> => string, <<"offset">> => string}, timestamp_with_timezone, undefined},
    {function, [timestamp],
     #{<<"zone">> => string}, timestamp_with_timezone, undefined},
    {function, [timestamp],
     #{<<"offset">> => string}, timestamp_with_timezone,
     {gdbsp_temporal, temporal_tstz_ts_offset, 2}},
    {function, [],
     #{<<"date">> => date, <<"time">> => time,
       <<"zone">> => string, <<"offset">> => string},
     timestamp_with_timezone, undefined},
    {function, [],
     #{<<"date">> => date, <<"time">> => time, <<"zone">> => string},
     timestamp_with_timezone, undefined},
    {function, [],
     #{<<"date">> => date, <<"time">> => time, <<"offset">> => string},
     timestamp_with_timezone,
     {gdbsp_temporal, temporal_tstz_dt_offset, 3}}
]};
fn_overloads(<<"temporal:interval">>) -> {ok, [
    {function, [],
     #{<<"months">> => i64, <<"days">> => i64, <<"microseconds">> => i64},
     interval,
     {gdbsp_temporal, temporal_interval_mdm, 3}},
    {function, [], #{<<"months">> => i64, <<"days">> => i64}, interval,
     {gdbsp_temporal, temporal_interval_md, 2}},
    {function, [], #{<<"months">> => i64}, interval,
     {gdbsp_temporal, temporal_interval_m, 1}},
    {function, [], #{}, interval,
     {gdbsp_temporal, temporal_interval_empty, 0}}
]};

fn_overloads(<<"storage:blob">>) -> {ok, [
    {function, [], #{<<"sha256">> => string}, {closure, [], bytes},
     {gdbsp_bytes, bytes_blob_sha256, 1}},
    {function, [], #{<<"git_sha1">> => string}, {closure, [], bytes},
     {gdbsp_bytes, bytes_blob_git_sha1, 1}}
]};

%% ── temporal: extract fields ────────────────────────────────────────
fn_overloads(<<"temporal:year">>) -> {ok, temporal_extract_overloads(year)};
fn_overloads(<<"temporal:month">>) -> {ok, temporal_extract_overloads(month)};
fn_overloads(<<"temporal:day">>) -> {ok, temporal_extract_overloads(day)};
fn_overloads(<<"temporal:hour">>) -> {ok, temporal_extract_overloads(hour)};
fn_overloads(<<"temporal:minute">>) -> {ok, temporal_extract_overloads(minute)};
fn_overloads(<<"temporal:second">>) -> {ok, temporal_extract_overloads(second)};
fn_overloads(<<"temporal:day_of_week">>) -> {ok, temporal_extract_overloads(dow)};
fn_overloads(<<"temporal:day_of_year">>) -> {ok, temporal_extract_overloads(doy)};

%% ── temporal: arithmetic ────────────────────────────────────────────
fn_overloads(<<"temporal:add">>) -> {ok, [
    {function, [date, interval], #{}, date, tfn(add, date_interval)},
    {function, [time, interval], #{}, time, tfn(add, time_interval)},
    {function, [timestamp, interval], #{}, timestamp, tfn(add, ts_interval)},
    {function, [timestamp_with_timezone, interval], #{}, timestamp_with_timezone,
     tfn(add, tstz_interval)},
    {function, [interval, interval], #{}, interval, tfn(add, interval_interval)}
]};
fn_overloads(<<"temporal:sub">>) -> {ok, [
    {function, [date, interval], #{}, date, tfn(sub, date_interval)},
    {function, [time, interval], #{}, time, tfn(sub, time_interval)},
    {function, [timestamp, interval], #{}, timestamp, tfn(sub, ts_interval)},
    {function, [timestamp_with_timezone, interval], #{}, timestamp_with_timezone,
     tfn(sub, tstz_interval)},
    {function, [interval, interval], #{}, interval, tfn(sub, interval_interval)},
    {function, [date, date], #{}, interval, tfn(sub, date_date)},
    {function, [time, time], #{}, interval, tfn(sub, time_time)},
    {function, [timestamp, timestamp], #{}, interval, tfn(sub, ts_ts)},
    {function, [timestamp_with_timezone, timestamp_with_timezone], #{}, interval,
     tfn(sub, tstz_tstz)}
]};
fn_overloads(<<"temporal:neg">>) -> {ok, [
    {function, [interval], #{}, interval, tfn(neg, interval)}
]};

%% ── temporal: comparison ────────────────────────────────────────────
fn_overloads(<<"temporal:eq">>) -> {ok, temporal_comp_overloads(eq)};
fn_overloads(<<"temporal:neq">>) -> {ok, temporal_comp_overloads(neq)};
fn_overloads(<<"temporal:lt">>) -> {ok, temporal_comp_overloads(lt)};
fn_overloads(<<"temporal:gt">>) -> {ok, temporal_comp_overloads(gt)};
fn_overloads(<<"temporal:lte">>) -> {ok, temporal_comp_overloads(lte)};
fn_overloads(<<"temporal:gte">>) -> {ok, temporal_comp_overloads(gte)};

%% ── $dynamically_typed: runtime type dispatch (internal) ───────────
fn_overloads(<<"$dynamically_typed:is">>) -> {ok, [
    {function, [dynamic, type], #{}, {enum, [<<"false">>, <<"true">>]},
     {gdbsp_dyn_type, dyn_type_is, 2}}
]};
fn_overloads(<<"$dynamically_typed:ensure">>) -> {ok, [
    {function, [dynamic, type], #{}, dynamic,
     {gdbsp_dyn_type, dyn_type_ensure, 2}}
]};
fn_overloads(<<"$dynamically_typed:at">>) -> {ok, [
    {function, [dynamic], #{<<"key">> => dynamic}, dynamic,
     {gdbsp_dyn_type, dyn_type_at, 2}}
]};
fn_overloads(<<"$dynamically_typed:slice">>) -> {ok, [
    {function, [dynamic],
     #{<<"start">> => i64, <<"stop">> => i64, <<"step">> => i64}, dynamic,
     {gdbsp_dyn_type, dyn_type_slice_start_stop_step, 4}},
    {function, [dynamic], #{<<"start">> => i64, <<"stop">> => i64}, dynamic,
     {gdbsp_dyn_type, dyn_type_slice_start_stop, 3}},
    {function, [dynamic], #{<<"stop">> => i64}, dynamic,
     {gdbsp_dyn_type, dyn_type_slice_stop, 2}}
]};

fn_overloads(<<"$dynamically_typed:concat">>) -> {ok, [
    {function, [dynamic, dynamic], #{}, dynamic,
     {gdbsp_dyn_type, dyn_type_concat, 2}}
]};

fn_overloads(_) -> {error, not_found}.

%%====================================================================
%% Comparison overloads (shared by eq, neq, lt, gt, le, ge)
%%====================================================================

comparison_overloads(Op) ->
    WithImpl = [i8, i16, i32, i64, u8, u16, u32, u64, integer, f64, numeric, string],
    NoImpl = [date, time, timestamp, timestamp_with_timezone, interval, bytes],
    Dynamic = [{function, [dynamic, dynamic], #{}, {enum, [<<"false">>, <<"true">>]}, dyn_fn(Op)}],
    With = [{function, [T, T], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(Op, T)} || T <- WithImpl],
    Without = [{function, [T, T], #{}, {enum, [<<"false">>, <<"true">>]}, undefined} || T <- NoImpl],
    With ++ Without ++ Dynamic.

integer_comparison_overloads(Op) ->
    IntTypes = [i8, i16, i32, i64, u8, u16, u32, u64, integer],
    [{function, [T, T], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(Op, T)} || T <- IntTypes].

float_comparison_overloads(Op) ->
    FloatTypes = [f32, f64],
    [{function, [T, T], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(Op, T)} || T <- FloatTypes].

numeric_comparison_overloads(Op) ->
    [{function, [numeric, numeric], #{}, {enum, [<<"false">>, <<"true">>]}, std_fn(Op, numeric)}].

temporal_extract_overloads(Field) ->
    TsTypes = [date, timestamp, timestamp_with_timezone],
    case Field of
        Field2 when Field2 =:= hour; Field2 =:= minute; Field2 =:= second ->
            [{function, [date], #{}, i64,
              {gdbsp_temporal,
               list_to_atom("temporal_" ++ atom_to_list(Field) ++ "_date"), 1}},
             {function, [time], #{}, i64,
              {gdbsp_temporal,
               list_to_atom("temporal_" ++ atom_to_list(Field) ++ "_time"), 1}},
             {function, [timestamp], #{}, i64,
              {gdbsp_temporal,
               list_to_atom("temporal_" ++ atom_to_list(Field) ++ "_ts"), 1}},
             {function, [timestamp_with_timezone], #{}, i64,
              {gdbsp_temporal,
               list_to_atom("temporal_" ++ atom_to_list(Field) ++ "_tstz"), 1}}];
        _ ->
            [{function, [T], #{}, i64,
              {gdbsp_temporal,
               list_to_atom("temporal_" ++ atom_to_list(Field) ++ "_" ++ atom_to_list(T)), 1}}
             || T <- TsTypes]
    end.

tfn(Op, Suffix) ->
    {gdbsp_temporal,
     list_to_atom("temporal_" ++ atom_to_list(Op) ++ "_" ++ atom_to_list(Suffix)), 2}.

temporal_comp_overloads(Op) ->
    Types = [date, time, timestamp, timestamp_with_timezone, interval],
    [{function, [T, T], #{}, {enum, [<<"false">>, <<"true">>]},
      {gdbsp_temporal,
       list_to_atom("temporal_" ++ atom_to_list(Op) ++ "_" ++ atom_to_list(T) ++ "_" ++ atom_to_list(T)), 2}}
     || T <- Types].

%%====================================================================
%% Math unary overload helpers
%%====================================================================

unary_overloads(Op) ->
    IntTypes = [i8, i16, i32, i64, u8, u16, u32, u64, integer],
    FloatTypes = [f64],
    IntOverloads = [{function, [T], #{}, integer, math1_fn(Op, T)} || T <- IntTypes],
    FloatOverloads = [{function, [T], #{}, T, math1_fn(Op, T)} || T <- FloatTypes],
    IntOverloads ++ FloatOverloads.

sign_overloads() ->
    IntTypes = [i8, i16, i32, i64, u8, u16, u32, u64, integer],
    FloatTypes = [f64],
    IntOverloads = [{function, [T], #{}, i8, math1_fn(sign, T)} || T <- IntTypes],
    FloatOverloads = [{function, [T], #{}, f64, math1_fn(sign, T)} || T <- FloatTypes],
    IntOverloads ++ FloatOverloads.

%%====================================================================
%% Aggregate overloads
%%====================================================================

agg_overloads(<<"agg:sum">>) -> {ok, [
    {aggregate, [integer], #{}, integer, agg_ref(sum, integer)},
    {aggregate, [f64], #{}, f64, agg_ref(sum, f64)},
    {aggregate, [numeric], #{}, numeric, agg_ref(sum, numeric)},
    {aggregate, [{optional, integer}], #{}, {optional, integer},
     agg_ref(sum, {optional, integer})},
    {aggregate, [{optional, f64}], #{}, {optional, f64},
     agg_ref(sum, {optional, f64})},
    {aggregate, [{optional, numeric}], #{}, {optional, numeric},
     agg_ref(sum, {optional, numeric})}
]};
agg_overloads(<<"agg:count">>) -> {ok, [
    {aggregate, [], #{}, integer, agg_ref(count, none)}
]};
agg_overloads(<<"agg:max">>) -> {ok, [
    {aggregate, [integer], #{}, integer, agg_ref(max, integer)},
    {aggregate, [f64], #{}, f64, agg_ref(max, f64)},
    {aggregate, [numeric], #{}, numeric, agg_ref(max, numeric)},
    {aggregate, [{optional, integer}], #{}, {optional, integer},
     agg_ref(max, {optional, integer})},
    {aggregate, [{optional, f64}], #{}, {optional, f64},
     agg_ref(max, {optional, f64})},
    {aggregate, [{optional, numeric}], #{}, {optional, numeric},
     agg_ref(max, {optional, numeric})}
]};
agg_overloads(<<"agg:min">>) -> {ok, [
    {aggregate, [integer], #{}, integer, agg_ref(min, integer)},
    {aggregate, [f64], #{}, f64, agg_ref(min, f64)},
    {aggregate, [numeric], #{}, numeric, agg_ref(min, numeric)},
    {aggregate, [{optional, integer}], #{}, {optional, integer},
     agg_ref(min, {optional, integer})},
    {aggregate, [{optional, f64}], #{}, {optional, f64},
     agg_ref(min, {optional, f64})},
    {aggregate, [{optional, numeric}], #{}, {optional, numeric},
     agg_ref(min, {optional, numeric})}
]};
agg_overloads(<<"agg:avg">>) -> {ok, [
    {aggregate, [integer], #{}, f64, agg_ref(avg, integer)},
    {aggregate, [f64], #{}, f64, agg_ref(avg, f64)},
    {aggregate, [numeric], #{}, numeric, agg_ref(avg, numeric)},
    {aggregate, [{optional, integer}], #{}, {optional, f64},
     agg_ref(avg, {optional, integer})},
    {aggregate, [{optional, f64}], #{}, {optional, f64},
     agg_ref(avg, {optional, f64})},
    {aggregate, [{optional, numeric}], #{}, {optional, numeric},
     agg_ref(avg, {optional, numeric})}
]};
agg_overloads(<<"agg:xor">>) -> {ok, [
    {aggregate, [bytes], #{}, bytes, agg_ref('xor', bytes)},
    {aggregate, [{optional, bytes}], #{}, {optional, bytes},
     agg_ref('xor', {optional, bytes})}
]};
agg_overloads(_) -> {error, not_found}.
