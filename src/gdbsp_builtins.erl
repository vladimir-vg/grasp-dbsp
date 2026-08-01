%%%-------------------------------------------------------------------
%%% @doc Built-in function, aggregate, and constructor registry.
%%% Provides name resolution and overload tables for type inference.
%%%
%%% Pure module — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_builtins).

-export([binop_fn_name/1, unop_fn_name/1]).
-export([resolve_call/4]).
-export([operand_types/1, is_valid_operand/2, concrete_fn/3]).
-export([unify_types/3, fn_impl/1, agg_impl/1]).

-include("gdbsp_type.hrl").
-include("gdbsp_parse.hrl").

-type impl_ref() :: {module(), atom(), non_neg_integer()} | undefined | special_implementation.

%%====================================================================
%% Name resolution
%%====================================================================

-spec binop_fn_name(atom()) -> binary().
binop_fn_name('+')   -> <<"+">>;
binop_fn_name('-')   -> <<"-">>;
binop_fn_name('*')   -> <<"*">>;
binop_fn_name('/')   -> <<"/">>;
binop_fn_name('%')   -> <<"%">>;
binop_fn_name('=')   -> <<"=">>;
binop_fn_name('!=')  -> <<"!=">>;
binop_fn_name('<')   -> <<"<">>;
binop_fn_name('>')   -> <<">">>;
binop_fn_name('<=')  -> <<"<=">>;
binop_fn_name('>=')  -> <<">=">>;
binop_fn_name('++')  -> <<"++">>;
binop_fn_name('<<')  -> <<"<<">>;
binop_fn_name('>>')  -> <<">>">>;
binop_fn_name('<<<') -> <<"<<<">>;
binop_fn_name('>>>') -> <<">>>">>;
binop_fn_name('&')   -> <<"&">>;
binop_fn_name('|')   -> <<"|">>;
binop_fn_name('^')   -> <<"^">>.

-spec unop_fn_name(atom()) -> binary().
unop_fn_name('-')   -> <<"-">>;
unop_fn_name('~')   -> <<"~">>;
unop_fn_name('not') -> <<"not">>.

%%====================================================================
%% stdlib-based call resolution (NEW — replaces lookup_fn)
%%====================================================================

-type stdlib_map() :: #{binary() => [#gdbsp_typespec{}]}.

-spec resolve_call(binary(), [gdbsp_column_type()], [{binary(), gdbsp_column_type()}],
                   stdlib_map()) ->
    {ok, gdbsp_column_type(), binary()} | {error, term()}.
resolve_call(Name, PosTypes, KwPairs, StdlibMap) ->
    Concrete = case maps:find(Name, StdlibMap) of
        {ok, [_ | _]} ->
            case is_operator_name(Name) of
                true -> operator_resolve(Name, PosTypes, KwPairs);
                false -> {ok, Name}
            end;
        error ->
            case is_operator_name(Name) of
                true -> operator_resolve(Name, PosTypes, KwPairs);
                false -> {error, {unknown_function, Name}}
            end
    end,
    case Concrete of
        {ok, ConcreteName} ->
            case find_concrete_ts(ConcreteName, PosTypes, KwPairs, StdlibMap) of
                {ok, RetType} -> {ok, RetType, ConcreteName};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

is_operator_name(<<"+">>)   -> true;
is_operator_name(<<"-">>)   -> true;
is_operator_name(<<"*">>)   -> true;
is_operator_name(<<"/">>)   -> true;
is_operator_name(<<"%">>)   -> true;
is_operator_name(<<"=">>)   -> true;
is_operator_name(<<"!=">>)  -> true;
is_operator_name(<<"<">>)   -> true;
is_operator_name(<<">">>)   -> true;
is_operator_name(<<"<=">>)  -> true;
is_operator_name(<<">=">>)  -> true;
is_operator_name(<<"++">>)  -> true;
is_operator_name(<<"<<">>)  -> true;
is_operator_name(<<">>">>)  -> true;
is_operator_name(<<"<<<">>) -> true;
is_operator_name(<<">>>">>) -> true;
is_operator_name(<<"&">>)   -> true;
is_operator_name(<<"|">>)   -> true;
is_operator_name(<<"^">>)   -> true;
is_operator_name(<<"~">>)   -> true;
is_operator_name(<<"not">>) -> true;
is_operator_name(<<"and">>) -> true;
is_operator_name(<<"or">>)  -> true;
is_operator_name(_) -> false.

operator_resolve(<<"not">>, PosTypes, _Kw) -> wrap_operator(concrete_fn(<<"not">>, PosTypes, #{}));
operator_resolve(<<"and">>, PosTypes, _Kw) -> wrap_operator(concrete_fn(<<"and">>, PosTypes, #{}));
operator_resolve(<<"or">>,  PosTypes, _Kw) -> wrap_operator(concrete_fn(<<"or">>,  PosTypes, #{}));
operator_resolve(<<"~">>,   PosTypes, _Kw) -> wrap_operator(concrete_fn(<<"~">>,   PosTypes, #{}));
operator_resolve(Name, PosTypes, _Kw) when length(PosTypes) =:= 1 ->
    wrap_operator(concrete_fn(Name, PosTypes, #{}));
operator_resolve(Name, PosTypes, KwPairs) ->
    wrap_operator(concrete_fn(Name, PosTypes, maps:from_list(KwPairs))).

wrap_operator({error, _} = E) -> E;
wrap_operator(CN) when is_binary(CN) -> {ok, CN}.

find_concrete_ts(Name, PosTypes, KwPairs, StdlibMap) ->
    case maps:find(Name, StdlibMap) of
        {ok, TSpecs} ->
            match_stdlib_ts(TSpecs, PosTypes, KwPairs);
        error ->
            {error, {missing_typespec, Name}}
    end.

match_stdlib_ts([], _PosTypes, _KwPairs) ->
    {error, no_matching_overload};
match_stdlib_ts([#gdbsp_typespec{spec = {function, Pos, Kw, Ret}} | Rest],
                PosTypes, KwPairs) ->
    case match_pos(Pos, PosTypes) andalso match_kw(Kw, KwPairs) of
        true -> {ok, Ret};
        false -> match_stdlib_ts(Rest, PosTypes, KwPairs)
    end;
match_stdlib_ts([#gdbsp_typespec{spec = {aggregate_function, Pos, Kw, Ret}} | Rest],
                PosTypes, KwPairs) ->
    case match_pos(Pos, PosTypes) andalso match_kw(Kw, KwPairs) of
        true -> {ok, Ret};
        false -> match_stdlib_ts(Rest, PosTypes, KwPairs)
    end.

%%====================================================================
%% Overload matching helpers
%%====================================================================

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
exact_match({string, _}, string) -> true;
exact_match(string, {string, _}) -> true;
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
%% Operator tables
%%====================================================================

-type operand_type_set() :: [gdbsp_column_type() | all_except].

-spec operand_types(binary()) -> operand_type_set().
operand_types(<<"+">>)   -> [i8, i16, i32, i64, u8, u16, u32, u64, integer, numeric, f64, interval];
operand_types(<<"-">>)   -> [i8, i16, i32, i64, u8, u16, u32, u64, integer, numeric, f64, interval];
operand_types(<<"*">>)   -> [i8, i16, i32, i64, u8, u16, u32, u64, integer, numeric, f64];
operand_types(<<"/">>)   -> [i8, i16, i32, i64, u8, u16, u32, u64, integer, numeric, f64];
operand_types(<<"%">>)   -> [i8, i16, i32, i64, u8, u16, u32, u64, integer];
operand_types(<<"=">>)   -> [all_except];
operand_types(<<"!=">>)  -> [all_except];
operand_types(<<"<">>)   -> [all_except];
operand_types(<<">">>)   -> [all_except];
operand_types(<<"<=">>)  -> [all_except];
operand_types(<<">=">>)  -> [all_except];
operand_types(<<"++">>)  -> [{string, <<"UTF-8">>}, bytes, bits, array];
operand_types(<<"<<">>)  -> [bits];
operand_types(<<">>">>)  -> [bits];
operand_types(<<"<<<">>) -> [bits];
operand_types(<<">>>">>) -> [bits];
operand_types(<<"|">>)   -> [bits];
operand_types(<<"^">>)   -> [bits];
operand_types(<<"&">>)   -> [bits];
operand_types(<<"not">>) -> [{enum, [<<"false">>, <<"true">>]}];
operand_types(<<"and">>) -> [{enum, [<<"false">>, <<"true">>]}];
operand_types(<<"or">>)  -> [{enum, [<<"false">>, <<"true">>]}];
operand_types(<<"~">>)   -> [bits].

-spec is_valid_operand(binary(), gdbsp_column_type()) -> boolean().
is_valid_operand(Op, Type) ->
    case operand_types(Op) of
        [all_except] -> not is_invalid_operand_type(Type);
        Types -> has_type(Types, Type)
    end.

is_invalid_operand_type(closure) -> true;
is_invalid_operand_type({closure, _, _}) -> true;
is_invalid_operand_type(dynamic) -> true;
is_invalid_operand_type({dynamic, _}) -> true;
is_invalid_operand_type(_) -> false.

has_type(Types, Type) ->
    lists:any(fun(T) -> operand_type_matches(T, Type) end, Types).

operand_type_matches(T, T) -> true;
operand_type_matches(integer, T)
  when T =:= i8; T =:= i16; T =:= i32; T =:= i64;
       T =:= u8; T =:= u16; T =:= u32; T =:= u64 -> true;
operand_type_matches({string, <<"UTF-8">>}, {string, _}) -> true;
operand_type_matches(string_with_encoding, {string, _}) -> true;
operand_type_matches(string_with_encoding, string_with_encoding) -> true;
operand_type_matches(array, {array, _, _}) -> true;
operand_type_matches(_, _) -> false.

%%--------------------------------------------------------------------
%% Concrete function name resolution
%%--------------------------------------------------------------------

-define(FIXED_INTS, (T =:= i8 orelse T =:= i16 orelse T =:= i32 orelse T =:= i64
                 orelse T =:= u8 orelse T =:= u16 orelse T =:= u32 orelse T =:= u64)).

-spec concrete_fn(binary(), [gdbsp_column_type()], #{binary() => gdbsp_column_type()}) ->
    binary() | {error, term()}.

%% Arithmetic
concrete_fn(<<"+">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.add_", (type_suffix(T))/binary>>;
concrete_fn(<<"+">>, [integer, integer], _) -> <<"std.add_integer">>;
concrete_fn(<<"+">>, [numeric, numeric], _) -> <<"std.add_numeric">>;
concrete_fn(<<"+">>, [f64, f64], _)         -> <<"std.add_f64">>;
concrete_fn(<<"+">>, [interval, interval], _) -> <<"std.add_interval">>;

concrete_fn(<<"-">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.sub_", (type_suffix(T))/binary>>;
concrete_fn(<<"-">>, [integer, integer], _) -> <<"std.sub_integer">>;
concrete_fn(<<"-">>, [numeric, numeric], _) -> <<"std.sub_numeric">>;
concrete_fn(<<"-">>, [f64, f64], _)         -> <<"std.sub_f64">>;
concrete_fn(<<"-">>, [interval, interval], _) -> <<"std.sub_interval">>;

concrete_fn(<<"*">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.mul_", (type_suffix(T))/binary>>;
concrete_fn(<<"*">>, [integer, integer], _) -> <<"std.mul_integer">>;
concrete_fn(<<"*">>, [numeric, numeric], _) -> <<"std.mul_numeric">>;
concrete_fn(<<"*">>, [f64, f64], _)         -> <<"std.mul_f64">>;

concrete_fn(<<"/">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.div_", (type_suffix(T))/binary>>;
concrete_fn(<<"/">>, [integer, integer], _) -> <<"std.div_integer">>;
concrete_fn(<<"/">>, [numeric, numeric], _) -> <<"std.div_numeric">>;
concrete_fn(<<"/">>, [f64, f64], _)         -> <<"std.div_f64">>;

concrete_fn(<<"%">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.mod_", (type_suffix(T))/binary>>;
concrete_fn(<<"%">>, [integer, integer], _) -> <<"std.mod_integer">>;

%% Comparison
concrete_fn(<<"=">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.eq_", (type_suffix(T))/binary>>;
concrete_fn(<<"=">>, [integer, integer], _) -> <<"std.eq_integer">>;
concrete_fn(<<"=">>, [f64, f64], _)         -> <<"std.eq_f64">>;
concrete_fn(<<"=">>, [numeric, numeric], _) -> <<"std.eq_numeric">>;
concrete_fn(<<"=">>, [string, string], _) -> <<"std.eq_string">>;
concrete_fn(<<"=">>, [{string, _}, {string, _}], _) -> <<"std.eq_string">>;
concrete_fn(<<"=">>, [{enum, _}, {enum, _}], _) -> <<"std.eq_boolean">>;
concrete_fn(<<"=">>, [bytes, bytes], _)     -> <<"std.eq_bytes">>;
concrete_fn(<<"=">>, [bits, bits], _)       -> <<"std.eq_bits">>;
concrete_fn(<<"=">>, [date, date], _)       -> <<"std.eq_date">>;
concrete_fn(<<"=">>, [time, time], _)       -> <<"std.eq_time">>;
concrete_fn(<<"=">>, [timestamp, timestamp], _) -> <<"std.eq_timestamp">>;
concrete_fn(<<"=">>, [interval, interval], _) -> <<"std.eq_interval">>;

concrete_fn(<<"!=">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.neq_", (type_suffix(T))/binary>>;
concrete_fn(<<"!=">>, [integer, integer], _) -> <<"std.neq_integer">>;
concrete_fn(<<"!=">>, [f64, f64], _)         -> <<"std.neq_f64">>;
concrete_fn(<<"!=">>, [numeric, numeric], _) -> <<"std.neq_numeric">>;
concrete_fn(<<"!=">>, [string, string], _) -> <<"std.neq_string">>;
concrete_fn(<<"!=">>, [{string, _}, {string, _}], _) -> <<"std.neq_string">>;
concrete_fn(<<"!=">>, [{enum, _}, {enum, _}], _) -> <<"std.neq_boolean">>;
concrete_fn(<<"!=">>, [bytes, bytes], _)     -> <<"std.neq_bytes">>;
concrete_fn(<<"!=">>, [bits, bits], _)       -> <<"std.neq_bits">>;
concrete_fn(<<"!=">>, [date, date], _)       -> <<"std.neq_date">>;
concrete_fn(<<"!=">>, [time, time], _)       -> <<"std.neq_time">>;
concrete_fn(<<"!=">>, [timestamp, timestamp], _) -> <<"std.neq_timestamp">>;
concrete_fn(<<"!=">>, [interval, interval], _) -> <<"std.neq_interval">>;

concrete_fn(<<"<">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.lt_", (type_suffix(T))/binary>>;
concrete_fn(<<"<">>, [integer, integer], _) -> <<"std.lt_integer">>;
concrete_fn(<<"<">>, [f64, f64], _)         -> <<"std.lt_f64">>;
concrete_fn(<<"<">>, [numeric, numeric], _) -> <<"std.lt_numeric">>;
concrete_fn(<<"<">>, [string, string], _) -> <<"std.lt_string">>;
concrete_fn(<<"<">>, [{string, _}, {string, _}], _) -> <<"std.lt_string">>;
concrete_fn(<<"<">>, [{enum, _}, {enum, _}], _) -> <<"std.lt_boolean">>;
concrete_fn(<<"<">>, [bytes, bytes], _)     -> <<"std.lt_bytes">>;
concrete_fn(<<"<">>, [bits, bits], _)       -> <<"std.lt_bits">>;
concrete_fn(<<"<">>, [date, date], _)       -> <<"std.lt_date">>;
concrete_fn(<<"<">>, [time, time], _)       -> <<"std.lt_time">>;
concrete_fn(<<"<">>, [timestamp, timestamp], _) -> <<"std.lt_timestamp">>;
concrete_fn(<<"<">>, [interval, interval], _) -> <<"std.lt_interval">>;

concrete_fn(<<">">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.gt_", (type_suffix(T))/binary>>;
concrete_fn(<<">">>, [integer, integer], _) -> <<"std.gt_integer">>;
concrete_fn(<<">">>, [f64, f64], _)         -> <<"std.gt_f64">>;
concrete_fn(<<">">>, [numeric, numeric], _) -> <<"std.gt_numeric">>;
concrete_fn(<<">">>, [string, string], _) -> <<"std.gt_string">>;
concrete_fn(<<">">>, [{string, _}, {string, _}], _) -> <<"std.gt_string">>;
concrete_fn(<<">">>, [{enum, _}, {enum, _}], _) -> <<"std.gt_boolean">>;
concrete_fn(<<">">>, [bytes, bytes], _)     -> <<"std.gt_bytes">>;
concrete_fn(<<">">>, [bits, bits], _)       -> <<"std.gt_bits">>;
concrete_fn(<<">">>, [date, date], _)       -> <<"std.gt_date">>;
concrete_fn(<<">">>, [time, time], _)       -> <<"std.gt_time">>;
concrete_fn(<<">">>, [timestamp, timestamp], _) -> <<"std.gt_timestamp">>;
concrete_fn(<<">">>, [interval, interval], _) -> <<"std.gt_interval">>;

concrete_fn(<<"<=">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.lte_", (type_suffix(T))/binary>>;
concrete_fn(<<"<=">>, [integer, integer], _) -> <<"std.lte_integer">>;
concrete_fn(<<"<=">>, [f64, f64], _)         -> <<"std.lte_f64">>;
concrete_fn(<<"<=">>, [numeric, numeric], _) -> <<"std.lte_numeric">>;
concrete_fn(<<"<=">>, [string, string], _) -> <<"std.lte_string">>;
concrete_fn(<<"<=">>, [{string, _}, {string, _}], _) -> <<"std.lte_string">>;
concrete_fn(<<"<=">>, [{enum, _}, {enum, _}], _) -> <<"std.lte_boolean">>;
concrete_fn(<<"<=">>, [bytes, bytes], _)     -> <<"std.lte_bytes">>;
concrete_fn(<<"<=">>, [bits, bits], _)       -> <<"std.lte_bits">>;
concrete_fn(<<"<=">>, [date, date], _)       -> <<"std.lte_date">>;
concrete_fn(<<"<=">>, [time, time], _)       -> <<"std.lte_time">>;
concrete_fn(<<"<=">>, [timestamp, timestamp], _) -> <<"std.lte_timestamp">>;
concrete_fn(<<"<=">>, [interval, interval], _) -> <<"std.lte_interval">>;

concrete_fn(<<">=">>, [T, T], _) when ?FIXED_INTS ->
    <<"std.gte_", (type_suffix(T))/binary>>;
concrete_fn(<<">=">>, [integer, integer], _) -> <<"std.gte_integer">>;
concrete_fn(<<">=">>, [f64, f64], _)         -> <<"std.gte_f64">>;
concrete_fn(<<">=">>, [numeric, numeric], _) -> <<"std.gte_numeric">>;
concrete_fn(<<">=">>, [string, string], _) -> <<"std.gte_string">>;
concrete_fn(<<">=">>, [{string, _}, {string, _}], _) -> <<"std.gte_string">>;
concrete_fn(<<">=">>, [{enum, _}, {enum, _}], _) -> <<"std.gte_boolean">>;
concrete_fn(<<">=">>, [bytes, bytes], _)     -> <<"std.gte_bytes">>;
concrete_fn(<<">=">>, [bits, bits], _)       -> <<"std.gte_bits">>;
concrete_fn(<<">=">>, [date, date], _)       -> <<"std.gte_date">>;
concrete_fn(<<">=">>, [time, time], _)       -> <<"std.gte_time">>;
concrete_fn(<<">=">>, [timestamp, timestamp], _) -> <<"std.gte_timestamp">>;
concrete_fn(<<">=">>, [interval, interval], _) -> <<"std.gte_interval">>;

%% Unary
concrete_fn(<<"-">>, [T], _) when ?FIXED_INTS ->
    <<"std.neg_", (type_suffix(T))/binary>>;
concrete_fn(<<"-">>, [integer], _) -> <<"std.neg_integer">>;
concrete_fn(<<"-">>, [f64], _)     -> <<"std.neg_f64">>;
concrete_fn(<<"-">>, [numeric], _) -> <<"std.neg_numeric">>;

%% Logic
concrete_fn(<<"not">>, [{enum, _}], _) -> <<"std.not">>;
concrete_fn(<<"and">>, [{enum, _}, {enum, _}], _) -> <<"std.and">>;
concrete_fn(<<"or">>,  [{enum, _}, {enum, _}], _) -> <<"std.or">>;

%% Concat
concrete_fn(<<"++">>, [string, string], _) -> <<"std.concat_string">>;
concrete_fn(<<"++">>, [{string, _}, {string, _}], _) -> <<"std.concat_string">>;
concrete_fn(<<"++">>, [bytes, bytes], _) -> <<"std.concat_bytes">>;
concrete_fn(<<"++">>, [bits, bits], _) -> <<"std.concat_bits">>;
concrete_fn(<<"++">>, [{array, T, _}, {array, T, _}], _) ->
    <<"std.concat_array">>;

%% Bits
concrete_fn(<<"&">>, [bits, bits], _) -> <<"std.bits_and">>;
concrete_fn(<<"|">>, [bits, bits], _) -> <<"std.bits_or">>;
concrete_fn(<<"^">>, [bits, bits], _) -> <<"std.bits_xor">>;
concrete_fn(<<"~">>, [bits], _)       -> <<"std.bits_not">>;
concrete_fn(<<"<<">>, [bits, integer], _)  -> <<"std.bits_shl">>;
concrete_fn(<<">>">>, [bits, integer], _)  -> <<"std.bits_shr">>;
concrete_fn(<<"<<<">>, [bits, integer], _) -> <<"std.bits_rotl">>;
concrete_fn(<<">>>">>, [bits, integer], _) -> <<"std.bits_rotr">>;

concrete_fn(_, _, _) -> {error, not_an_operator}.

type_suffix(i8)  -> <<"i8">>;
type_suffix(i16) -> <<"i16">>;
type_suffix(i32) -> <<"i32">>;
type_suffix(i64) -> <<"i64">>;
type_suffix(u8)  -> <<"u8">>;
type_suffix(u16) -> <<"u16">>;
type_suffix(u32) -> <<"u32">>;
type_suffix(u64) -> <<"u64">>.

%%--------------------------------------------------------------------
%% Type-variable unification
%%--------------------------------------------------------------------

-spec unify_types([gdbsp_column_type()], [gdbsp_column_type()],
                  #{{type_var, binary()} => gdbsp_column_type()}) ->
    {ok, #{{type_var, binary()} => gdbsp_column_type()}} | {error, term()}.
unify_types([], [], Subs) ->
    {ok, Subs};
unify_types([{type_var, N} | PRest], [AT | ARest], Subs) ->
    case maps:find({type_var, N}, Subs) of
        {ok, Existing} when Existing =:= AT ->
            unify_types(PRest, ARest, Subs);
        {ok, _} ->
            {error, {type_var_conflict, N}};
        error ->
            unify_types(PRest, ARest, Subs#{{type_var, N} => AT})
    end;
unify_types([PT | PRest], [AT | ARest], Subs) when PT =:= AT ->
    unify_types(PRest, ARest, Subs);
unify_types([PT | _], [AT | _], _Subs) ->
    {error, {type_mismatch, PT, AT}}.

%%--------------------------------------------------------------------
%% Implementation lookup
%%--------------------------------------------------------------------

-spec fn_impl(binary()) -> {ok, impl_ref()} | {error, term()}.
fn_impl(<<"std.add_i64">>)      -> {ok, {gdbsp_math, math_add_i64_i64, 2}};
fn_impl(<<"std.add_i32">>)      -> {ok, {gdbsp_math, math_add_i32_i32, 2}};
fn_impl(<<"std.add_i16">>)      -> {ok, {gdbsp_math, math_add_i16_i16, 2}};
fn_impl(<<"std.add_i8">>)       -> {ok, {gdbsp_math, math_add_i8_i8, 2}};
fn_impl(<<"std.add_u64">>)      -> {ok, {gdbsp_math, math_add_u64_u64, 2}};
fn_impl(<<"std.add_u32">>)      -> {ok, {gdbsp_math, math_add_u32_u32, 2}};
fn_impl(<<"std.add_u16">>)      -> {ok, {gdbsp_math, math_add_u16_u16, 2}};
fn_impl(<<"std.add_u8">>)       -> {ok, {gdbsp_math, math_add_u8_u8, 2}};
fn_impl(<<"std.add_integer">>)  -> {ok, {gdbsp_math, math_add_integer_integer, 2}};
fn_impl(<<"std.add_numeric">>)  -> {ok, {gdbsp_math, math_add_numeric_numeric, 2}};
fn_impl(<<"std.add_f64">>)      -> {ok, {gdbsp_math, math_add_f64_f64, 2}};
fn_impl(<<"std.add_interval">>) -> {ok, {gdbsp_temporal, temporal_add_interval_interval, 2}};

fn_impl(<<"std.sub_i64">>)      -> {ok, {gdbsp_math, math_sub_i64_i64, 2}};
fn_impl(<<"std.sub_numeric">>)  -> {ok, {gdbsp_math, math_sub_numeric_numeric, 2}};
fn_impl(<<"std.sub_f64">>)      -> {ok, {gdbsp_math, math_sub_f64_f64, 2}};

fn_impl(<<"std.mul_i64">>)      -> {ok, {gdbsp_math, math_mul_i64_i64, 2}};
fn_impl(<<"std.mul_numeric">>)  -> {ok, {gdbsp_math, math_mul_numeric_numeric, 2}};
fn_impl(<<"std.mul_f64">>)      -> {ok, {gdbsp_math, math_mul_f64_f64, 2}};

fn_impl(<<"std.div_i64">>)      -> {ok, {gdbsp_math, math_div_i64_i64, 2}};
fn_impl(<<"std.div_numeric">>)  -> {ok, {gdbsp_math, math_div_numeric_numeric, 2}};
fn_impl(<<"std.div_f64">>)      -> {ok, {gdbsp_math, math_div_f64_f64, 2}};

fn_impl(<<"std.mod_i64">>)      -> {ok, {gdbsp_math, math_mod_i64_i64, 2}};
fn_impl(<<"std.mod_integer">>)  -> {ok, {gdbsp_math, math_mod_integer_integer, 2}};

%% Comparison — specific implementations for float and numeric (nan/inf/decimal handling).
fn_impl(<<"std.eq_f64">>)       -> {ok, {gdbsp_std, std_eq_f64_f64, 2}};
fn_impl(<<"std.neq_f64">>)      -> {ok, {gdbsp_std, std_neq_f64_f64, 2}};
fn_impl(<<"std.lt_f64">>)       -> {ok, {gdbsp_std, std_lt_f64_f64, 2}};
fn_impl(<<"std.gt_f64">>)       -> {ok, {gdbsp_std, std_gt_f64_f64, 2}};
fn_impl(<<"std.lte_f64">>)      -> {ok, {gdbsp_std, std_lte_f64_f64, 2}};
fn_impl(<<"std.gte_f64">>)      -> {ok, {gdbsp_std, std_gte_f64_f64, 2}};
fn_impl(<<"std.eq_f32">>)       -> {ok, {gdbsp_std, std_eq_f32_f32, 2}};
fn_impl(<<"std.neq_f32">>)      -> {ok, {gdbsp_std, std_neq_f32_f32, 2}};
fn_impl(<<"std.lt_f32">>)       -> {ok, {gdbsp_std, std_lt_f32_f32, 2}};
fn_impl(<<"std.gt_f32">>)       -> {ok, {gdbsp_std, std_gt_f32_f32, 2}};
fn_impl(<<"std.lte_f32">>)      -> {ok, {gdbsp_std, std_lte_f32_f32, 2}};
fn_impl(<<"std.gte_f32">>)      -> {ok, {gdbsp_std, std_gte_f32_f32, 2}};
fn_impl(<<"std.eq_numeric">>)   -> {ok, {gdbsp_std, std_eq_numeric_numeric, 2}};
fn_impl(<<"std.neq_numeric">>)  -> {ok, {gdbsp_std, std_neq_numeric_numeric, 2}};
fn_impl(<<"std.lt_numeric">>)   -> {ok, {gdbsp_std, std_lt_numeric_numeric, 2}};
fn_impl(<<"std.gt_numeric">>)   -> {ok, {gdbsp_std, std_gt_numeric_numeric, 2}};
fn_impl(<<"std.lte_numeric">>)  -> {ok, {gdbsp_std, std_lte_numeric_numeric, 2}};
fn_impl(<<"std.gte_numeric">>)  -> {ok, {gdbsp_std, std_gte_numeric_numeric, 2}};
%% Comparison — generic fallback (all other types: i8-u64, integer, string, bytes, bits, enums, etc.).
fn_impl(<<"std.eq_", _/binary>>)  -> {ok, {gdbsp_std, std_eq, 2}};
fn_impl(<<"std.neq_", _/binary>>) -> {ok, {gdbsp_std, std_neq, 2}};
fn_impl(<<"std.lt_", _/binary>>)  -> {ok, {gdbsp_std, std_lt, 2}};
fn_impl(<<"std.gt_", _/binary>>)  -> {ok, {gdbsp_std, std_gt, 2}};
fn_impl(<<"std.lte_", _/binary>>) -> {ok, {gdbsp_std, std_lte, 2}};
fn_impl(<<"std.gte_", _/binary>>) -> {ok, {gdbsp_std, std_gte, 2}};

fn_impl(<<"std.neg_i64">>)      -> {ok, {gdbsp_math, math_neg_i64, 1}};
fn_impl(<<"std.neg_f64">>)      -> {ok, {gdbsp_math, math_neg_f64, 1}};
fn_impl(<<"std.neg_numeric">>)  -> {ok, {gdbsp_math, math_neg_numeric, 1}};

fn_impl(<<"std.not">>)          -> {ok, {gdbsp_std, std_not_boolean, 1}};
fn_impl(<<"std.and">>)          -> {ok, {gdbsp_std, std_and_boolean, 2}};
fn_impl(<<"std.or">>)           -> {ok, {gdbsp_std, std_or_boolean, 2}};

fn_impl(<<"std.concat_string">>) -> {ok, {gdbsp_string, string_concat, 2}};
fn_impl(<<"std.concat_bytes">>)  -> {ok, {gdbsp_bytes, bytes_concat, 2}};
fn_impl(<<"std.concat_bits">>)   -> {ok, {gdbsp_bits, bits_concat, 2}};
fn_impl(<<"std.concat_array">>)  -> {ok, {gdbsp_array, array_concat, 2}};

fn_impl(<<"std.bits_and">>)  -> {ok, {gdbsp_bits, bits_and, 2}};
fn_impl(<<"std.bits_or">>)   -> {ok, {gdbsp_bits, bits_or, 2}};
fn_impl(<<"std.bits_xor">>)  -> {ok, {gdbsp_bits, bits_xor, 2}};
fn_impl(<<"std.bits_not">>)  -> {ok, {gdbsp_bits, bits_not, 1}};
fn_impl(<<"std.bits_shl">>)  -> {ok, {gdbsp_bits, bits_shl, 2}};
fn_impl(<<"std.bits_shr">>)  -> {ok, {gdbsp_bits, bits_shr, 2}};
fn_impl(<<"std.bits_rotl">>) -> {ok, {gdbsp_bits, bits_rotl, 2}};
fn_impl(<<"std.bits_rotr">>) -> {ok, {gdbsp_bits, bits_rotr, 2}};

fn_impl(<<"std.string_upper">>) -> {ok, {gdbsp_string, string_upper, 1}};
fn_impl(<<"std.string_lower">>) -> {ok, {gdbsp_string, string_lower, 1}};
fn_impl(<<"std.string_length">>) -> {ok, {gdbsp_string, string_length, 1}};

fn_impl(<<"std.sqrt_f64">>) -> {ok, {gdbsp_math, math_sqrt_f64, 1}};
fn_impl(<<"std.abs_i64">>)   -> {ok, {gdbsp_math, math_abs_i64, 1}};
fn_impl(<<"std.abs_f64">>)   -> {ok, {gdbsp_math, math_abs_f64, 1}};

fn_impl(<<"std.struct_get">>) -> {ok, {gdbsp_struct, struct_get, 2}};

fn_impl(_) -> {error, unknown_impl}.

%%====================================================================
%% Aggregate implementation lookup
%%====================================================================

-spec agg_impl(binary()) ->
    {ok, {{module(), atom(), arity()},
          {module(), atom(), arity()},
          {module(), atom(), arity()}}} | {error, term()}.
agg_impl(<<"std.agg_sum_i64">>)      -> {ok, mfa_triple(gdbsp_agg, agg_op_sum)};
agg_impl(<<"std.agg_sum_numeric">>)  -> {ok, mfa_triple(gdbsp_agg, agg_op_sum)};
agg_impl(<<"std.agg_sum_f64">>)      -> {ok, mfa_triple(gdbsp_agg, agg_op_sum)};
agg_impl(<<"std.agg_count">>)         -> {ok, mfa_triple(gdbsp_agg, agg_op_count)};
agg_impl(<<"std.agg_avg_i64">>)      -> {ok, mfa_triple(gdbsp_agg, agg_op_sum)};
agg_impl(<<"std.agg_avg_numeric">>)  -> {ok, mfa_triple(gdbsp_agg, agg_op_sum)};
agg_impl(<<"std.agg_avg_f64">>)      -> {ok, mfa_triple(gdbsp_agg, agg_op_sum)};
agg_impl(<<"std.agg_min_i64">>)      -> {ok, mfa_triple(gdbsp_agg, agg_op_min)};
agg_impl(<<"std.agg_min_numeric">>)  -> {ok, mfa_triple(gdbsp_agg, agg_op_min)};
agg_impl(<<"std.agg_min_f64">>)      -> {ok, mfa_triple(gdbsp_agg, agg_op_min)};
agg_impl(<<"std.agg_max_i64">>)      -> {ok, mfa_triple(gdbsp_agg, agg_op_max)};
agg_impl(<<"std.agg_max_numeric">>)  -> {ok, mfa_triple(gdbsp_agg, agg_op_max)};
agg_impl(<<"std.agg_max_f64">>)      -> {ok, mfa_triple(gdbsp_agg, agg_op_max)};
agg_impl(<<"std.agg_xor_bytes">>)    -> {ok, mfa_triple(gdbsp_agg, agg_op_xor)};
agg_impl(_) -> {error, not_found}.

mfa_triple(Mod, Prefix) ->
    {{Mod, suffix_fn(Prefix, <<"_init">>), 2},
     {Mod, suffix_fn(Prefix, <<"_update">>), 3},
     {Mod, suffix_fn(Prefix, <<"_result">>), 1}}.

suffix_fn(Prefix, Suffix) ->
    erlang:binary_to_atom(
        <<(atom_to_binary(Prefix, utf8))/binary, Suffix/binary>>, utf8).
