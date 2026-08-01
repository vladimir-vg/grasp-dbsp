# Function Type Inference & stdlib.gdbsp — Implementation Plan

Date: 2026-08-01
Status: draft

Removes the overload-based `fn_overloads` table (~750 lines) from
`gdbsp_builtins.erl`. Replaces it with a stdlib.gdbsp file as the
single source of truth for all concrete function typespecs, three
compact hardcoded lookup tables, and type-variable unification at
operator call sites.

---

## 1. Design Summary

### 1.1 Principles

1. **stdlib.gdbsp is the source of truth.** Every concrete function
   flavour is declared there. Any function not found in stdlib (or
   defined inline) is a compile error.
2. **Operators use type variables.** A generic typespec like
   `+ :: function((T, T) -> T)` is resolved at each call site by
   unifying T with the concrete operand types, then mapping to a
   concrete stdlib function via hardcoded tables.
3. **Lowering keeps operator characters.** `x + y` lowers to
   `{call, <<"+">>, …}`, NOT `{call, <<"add">>, …}`. This avoids
   name collisions between operators and user-defined functions.
4. **Exact types only.** No implicit widening. `i64` stays `i64`,
   `integer` each concrete type gets its own `std.add_i64`, `std.add_integer`, etc.
5. **Implementation lookup is separate.** `fn_impl/1` maps a
   concrete name to an Erlang MFA. It is called only at codegen,
   never during type-checking.

### 1.2 Type Aliases

`string` is an alias for `string("UTF-8")`. `boolean` is an alias for
`enum("false","true")`. The parser must canonicalize these during
typespec parsing.

### 1.3 Deferred

- `std.struct` constructor — can't express `function((kwargs…) → struct(…))` with current typespec grammar.
- Fixed-size concat (`[i64;3] ++ [i64;5] → [i64;8]`). For now only varsize `++` is supported in stdlib.

---

## 2. `priv/stdlib.gdbsp`

Bundled as a priv file, loaded at application startup. The compiler
receives the parsed typespecs as

```erlang
-type stdlib_map() :: #{binary() => [#gdbsp_typespec{}]}.
```

Multiple entries per key represent overloads (e.g. `agg:sum` has entries
for `i64` and `numeric`).

### 2.1 File Contents

```
# ===== Arithmetic =====

std.add_i64     :: function((i64, i64) -> i64)
std.add_i32     :: function((i32, i32) -> i32)
std.add_i16     :: function((i16, i16) -> i16)
std.add_i8      :: function((i8, i8) -> i8)
std.add_u64     :: function((u64, u64) -> u64)
std.add_u32     :: function((u32, u32) -> u32)
std.add_u16     :: function((u16, u16) -> u16)
std.add_u8      :: function((u8, u8) -> u8)
std.add_integer :: function((integer, integer) -> integer)
std.add_numeric :: function((numeric, numeric) -> numeric)
std.add_f64     :: function((f64, f64) -> f64)
std.add_interval :: function((interval, interval) -> interval)

std.sub_i64     :: function((i64, i64) -> i64)
std.sub_i32     :: function((i32, i32) -> i32)
std.sub_i16     :: function((i16, i16) -> i16)
std.sub_i8      :: function((i8, i8) -> i8)
std.sub_u64     :: function((u64, u64) -> u64)
std.sub_u32     :: function((u32, u32) -> u32)
std.sub_u16     :: function((u16, u16) -> u16)
std.sub_u8      :: function((u8, u8) -> u8)
std.sub_integer :: function((integer, integer) -> integer)
std.sub_numeric :: function((numeric, numeric) -> numeric)
std.sub_f64     :: function((f64, f64) -> f64)
std.sub_interval :: function((interval, interval) -> interval)

std.mul_i64     :: function((i64, i64) -> i64)
std.mul_i32     :: function((i32, i32) -> i32)
std.mul_i16     :: function((i16, i16) -> i16)
std.mul_i8      :: function((i8, i8) -> i8)
std.mul_u64     :: function((u64, u64) -> u64)
std.mul_u32     :: function((u32, u32) -> u32)
std.mul_u16     :: function((u16, u16) -> u16)
std.mul_u8      :: function((u8, u8) -> u8)
std.mul_integer :: function((integer, integer) -> integer)
std.mul_numeric :: function((numeric, numeric) -> numeric)
std.mul_f64     :: function((f64, f64) -> f64)

std.div_i64     :: function((i64, i64) -> i64)
std.div_i32     :: function((i32, i32) -> i32)
std.div_i16     :: function((i16, i16) -> i16)
std.div_i8      :: function((i8, i8) -> i8)
std.div_u64     :: function((u64, u64) -> u64)
std.div_u32     :: function((u32, u32) -> u32)
std.div_u16     :: function((u16, u16) -> u16)
std.div_u8      :: function((u8, u8) -> u8)
std.div_integer :: function((integer, integer) -> integer)
std.div_numeric :: function((numeric, numeric) -> numeric)
std.div_f64     :: function((f64, f64) -> f64)

std.mod_i64     :: function((i64, i64) -> i64)
std.mod_i32     :: function((i32, i32) -> i32)
std.mod_i16     :: function((i16, i16) -> i16)
std.mod_i8      :: function((i8, i8) -> i8)
std.mod_u64     :: function((u64, u64) -> u64)
std.mod_u32     :: function((u32, u32) -> u32)
std.mod_u16     :: function((u16, u16) -> u16)
std.mod_u8      :: function((u8, u8) -> u8)
std.mod_integer :: function((integer, integer) -> integer)

# ===== Unary arithmetic =====

std.neg_i64     :: function((i64) -> i64)
std.neg_i32     :: function((i32) -> i32)
std.neg_i16     :: function((i16) -> i16)
std.neg_i8      :: function((i8) -> i8)
std.neg_u64     :: function((u64) -> u64)
std.neg_u32     :: function((u32) -> u32)
std.neg_u16     :: function((u16) -> u16)
std.neg_u8      :: function((u8) -> u8)
std.neg_integer :: function((integer) -> integer)
std.neg_f64     :: function((f64) -> f64)
std.neg_numeric :: function((numeric) -> numeric)

# ===== Comparison =====

std.eq_i64      :: function((i64, i64) -> boolean)
std.eq_i32      :: function((i32, i32) -> boolean)
std.eq_i16      :: function((i16, i16) -> boolean)
std.eq_i8       :: function((i8, i8) -> boolean)
std.eq_u64      :: function((u64, u64) -> boolean)
std.eq_u32      :: function((u32, u32) -> boolean)
std.eq_u16      :: function((u16, u16) -> boolean)
std.eq_u8       :: function((u8, u8) -> boolean)
std.eq_integer  :: function((integer, integer) -> boolean)
std.eq_f64      :: function((f64, f64) -> boolean)
std.eq_string   :: function((string, string) -> boolean)
std.eq_numeric  :: function((numeric, numeric) -> boolean)
std.eq_boolean  :: function((boolean, boolean) -> boolean)
std.eq_bytes    :: function((bytes, bytes) -> boolean)
std.eq_bits     :: function((bits, bits) -> boolean)
std.eq_date     :: function((date, date) -> boolean)
std.eq_time     :: function((time, time) -> boolean)
std.eq_timestamp :: function((timestamp, timestamp) -> boolean)
std.eq_interval :: function((interval, interval) -> boolean)

std.neq_i64      :: function((i64, i64) -> boolean)
std.neq_i32      :: function((i32, i32) -> boolean)
std.neq_i16      :: function((i16, i16) -> boolean)
std.neq_i8       :: function((i8, i8) -> boolean)
std.neq_u64      :: function((u64, u64) -> boolean)
std.neq_u32      :: function((u32, u32) -> boolean)
std.neq_u16      :: function((u16, u16) -> boolean)
std.neq_u8       :: function((u8, u8) -> boolean)
std.neq_integer  :: function((integer, integer) -> boolean)
std.neq_f64      :: function((f64, f64) -> boolean)
std.neq_string   :: function((string, string) -> boolean)
std.neq_numeric  :: function((numeric, numeric) -> boolean)
std.neq_boolean  :: function((boolean, boolean) -> boolean)
std.neq_bytes    :: function((bytes, bytes) -> boolean)
std.neq_bits     :: function((bits, bits) -> boolean)
std.neq_date     :: function((date, date) -> boolean)
std.neq_time     :: function((time, time) -> boolean)
std.neq_timestamp :: function((timestamp, timestamp) -> boolean)
std.neq_interval :: function((interval, interval) -> boolean)

std.lt_i64      :: function((i64, i64) -> boolean)
std.lt_i32      :: function((i32, i32) -> boolean)
std.lt_i16      :: function((i16, i16) -> boolean)
std.lt_i8       :: function((i8, i8) -> boolean)
std.lt_u64      :: function((u64, u64) -> boolean)
std.lt_u32      :: function((u32, u32) -> boolean)
std.lt_u16      :: function((u16, u16) -> boolean)
std.lt_u8       :: function((u8, u8) -> boolean)
std.lt_integer  :: function((integer, integer) -> boolean)
std.lt_f64      :: function((f64, f64) -> boolean)
std.lt_string   :: function((string, string) -> boolean)
std.lt_numeric  :: function((numeric, numeric) -> boolean)
std.lt_boolean  :: function((boolean, boolean) -> boolean)
std.lt_bytes    :: function((bytes, bytes) -> boolean)
std.lt_bits     :: function((bits, bits) -> boolean)
std.lt_date     :: function((date, date) -> boolean)
std.lt_time     :: function((time, time) -> boolean)
std.lt_timestamp :: function((timestamp, timestamp) -> boolean)
std.lt_interval :: function((interval, interval) -> boolean)

std.gt_i64      :: function((i64, i64) -> boolean)
std.gt_i32      :: function((i32, i32) -> boolean)
std.gt_i16      :: function((i16, i16) -> boolean)
std.gt_i8       :: function((i8, i8) -> boolean)
std.gt_u64      :: function((u64, u64) -> boolean)
std.gt_u32      :: function((u32, u32) -> boolean)
std.gt_u16      :: function((u16, u16) -> boolean)
std.gt_u8       :: function((u8, u8) -> boolean)
std.gt_integer  :: function((integer, integer) -> boolean)
std.gt_f64      :: function((f64, f64) -> boolean)
std.gt_string   :: function((string, string) -> boolean)
std.gt_numeric  :: function((numeric, numeric) -> boolean)
std.gt_boolean  :: function((boolean, boolean) -> boolean)
std.gt_bytes    :: function((bytes, bytes) -> boolean)
std.gt_bits     :: function((bits, bits) -> boolean)
std.gt_date     :: function((date, date) -> boolean)
std.gt_time     :: function((time, time) -> boolean)
std.gt_timestamp :: function((timestamp, timestamp) -> boolean)
std.gt_interval :: function((interval, interval) -> boolean)

std.lte_i64      :: function((i64, i64) -> boolean)
std.lte_i32      :: function((i32, i32) -> boolean)
std.lte_i16      :: function((i16, i16) -> boolean)
std.lte_i8       :: function((i8, i8) -> boolean)
std.lte_u64      :: function((u64, u64) -> boolean)
std.lte_u32      :: function((u32, u32) -> boolean)
std.lte_u16      :: function((u16, u16) -> boolean)
std.lte_u8       :: function((u8, u8) -> boolean)
std.lte_integer  :: function((integer, integer) -> boolean)
std.lte_f64      :: function((f64, f64) -> boolean)
std.lte_string   :: function((string, string) -> boolean)
std.lte_numeric  :: function((numeric, numeric) -> boolean)
std.lte_boolean  :: function((boolean, boolean) -> boolean)
std.lte_bytes    :: function((bytes, bytes) -> boolean)
std.lte_bits     :: function((bits, bits) -> boolean)
std.lte_date     :: function((date, date) -> boolean)
std.lte_time     :: function((time, time) -> boolean)
std.lte_timestamp :: function((timestamp, timestamp) -> boolean)
std.lte_interval :: function((interval, interval) -> boolean)

std.gte_i64      :: function((i64, i64) -> boolean)
std.gte_i32      :: function((i32, i32) -> boolean)
std.gte_i16      :: function((i16, i16) -> boolean)
std.gte_i8       :: function((i8, i8) -> boolean)
std.gte_u64      :: function((u64, u64) -> boolean)
std.gte_u32      :: function((u32, u32) -> boolean)
std.gte_u16      :: function((u16, u16) -> boolean)
std.gte_u8       :: function((u8, u8) -> boolean)
std.gte_integer  :: function((integer, integer) -> boolean)
std.gte_f64      :: function((f64, f64) -> boolean)
std.gte_string   :: function((string, string) -> boolean)
std.gte_numeric  :: function((numeric, numeric) -> boolean)
std.gte_boolean  :: function((boolean, boolean) -> boolean)
std.gte_bytes    :: function((bytes, bytes) -> boolean)
std.gte_bits     :: function((bits, bits) -> boolean)
std.gte_date     :: function((date, date) -> boolean)
std.gte_time     :: function((time, time) -> boolean)
std.gte_timestamp :: function((timestamp, timestamp) -> boolean)
std.gte_interval :: function((interval, interval) -> boolean)

# ===== Logic =====

std.not         :: function((boolean) -> boolean)
std.and         :: function((boolean, boolean) -> boolean)
std.or          :: function((boolean, boolean) -> boolean)

# ===== String =====

std.string_length      :: function((string) -> integer)
std.string_upper       :: function((string) -> string)
std.string_lower       :: function((string) -> string)
std.string_trim        :: function((string) -> string)
std.string_ltrim       :: function((string) -> string)
std.string_rtrim       :: function((string) -> string)
std.string_starts_with :: function((string, prefix: string) -> boolean)
std.string_ends_with   :: function((string, suffix: string) -> boolean)
std.string_contains    :: function((string, sub: string) -> boolean)
std.string_substring   :: function((string, start: i64) -> string)
std.string_substring   :: function((string, start: i64, length: i64) -> string)
std.string_replace     :: function((string, from: string, to: string) -> string)
std.string_split       :: function((string, delimiter: string) -> array(string))
std.string_at          :: function((string, i64) -> string)
std.string_slice       :: function((string, start: i64, stop: i64, step: i64) -> string)
std.string_slice       :: function((string, start: i64, stop: i64) -> string)
std.string_slice       :: function((string, stop: i64) -> string)

std.string_eq  :: function((string, string) -> boolean)
std.string_neq :: function((string, string) -> boolean)
std.string_lt  :: function((string, string) -> boolean)
std.string_gt  :: function((string, string) -> boolean)
std.string_lte :: function((string, string) -> boolean)
std.string_gte :: function((string, string) -> boolean)

# ===== Concat =====

std.concat_string :: function((string, string) -> string)
std.concat_bytes  :: function((bytes, bytes) -> bytes)
std.concat_bits   :: function((bits, bits) -> bits)
std.concat_array  :: function((array(T), array(T)) -> array(T))

# ===== Bytes / Bits =====

std.bytes_size :: function((bytes) -> integer)
std.bytes_at   :: function((bytes, i64) -> i64)
std.bytes_slice :: function((bytes, start: i64, stop: i64, step: i64) -> bytes)
std.bytes_slice :: function((bytes, start: i64, stop: i64) -> bytes)
std.bytes_slice :: function((bytes, stop: i64) -> bytes)

std.bits_size   :: function((bits) -> integer)
std.bits_at     :: function((bits, i64) -> bits)
std.bits_slice  :: function((bits, start: i64, stop: i64, step: i64) -> bits)
std.bits_slice  :: function((bits, start: i64, stop: i64) -> bits)
std.bits_slice  :: function((bits, stop: i64) -> bits)

std.bits_and  :: function((bits, bits) -> bits)
std.bits_or   :: function((bits, bits) -> bits)
std.bits_xor  :: function((bits, bits) -> bits)
std.bits_not  :: function((bits) -> bits)
std.bits_shl  :: function((bits, integer) -> bits)
std.bits_shr  :: function((bits, integer) -> bits)
std.bits_rotl :: function((bits, integer) -> bits)
std.bits_rotr :: function((bits, integer) -> bits)

std.bytes_eq  :: function((bytes, bytes) -> boolean)
std.bytes_neq :: function((bytes, bytes) -> boolean)
std.bytes_lt  :: function((bytes, bytes) -> boolean)
std.bytes_gt  :: function((bytes, bytes) -> boolean)
std.bytes_lte :: function((bytes, bytes) -> boolean)
std.bytes_gte :: function((bytes, bytes) -> boolean)

std.bits_eq  :: function((bits, bits) -> boolean)
std.bits_neq :: function((bits, bits) -> boolean)
std.bits_lt  :: function((bits, bits) -> boolean)
std.bits_gt  :: function((bits, bits) -> boolean)
std.bits_lte :: function((bits, bits) -> boolean)
std.bits_gte :: function((bits, bits) -> boolean)

# ===== Map =====

std.map_size   :: function((map(K, V)) -> integer)
std.map_keys   :: function((map(K, V)) -> array(K))
std.map_values :: function((map(K, V)) -> array(V))
std.map_has    :: function((map(K, V), key: K) -> boolean)
std.map_get    :: function((map(K, V), key: K) -> V)
std.map_without :: function((map(K, V), keys: array(K)) -> map(K, V))
std.map_merge  :: function((map(K, V), map(K, V)) -> map(K, V))

# ===== Array =====

std.array_size    :: function((array(T)) -> integer)
std.array_append  :: function((array(T), T) -> array(T))
std.array_prepend :: function((T, array(T)) -> array(T))
std.array_contains :: function((array(T), T) -> boolean)
std.array_reverse :: function((array(T)) -> array(T))
std.array_sort    :: function((array(T)) -> array(T))
std.array_at      :: function((array(T), i64) -> T)
std.array_slice   :: function((array(T), start: i64, stop: i64, step: i64) -> array(T))
std.array_slice   :: function((array(T), start: i64, stop: i64) -> array(T))
std.array_slice   :: function((array(T), stop: i64) -> array(T))

# ===== Temporal =====

std.date     :: function((timestamp) -> date)
std.time     :: function((timestamp) -> time)
std.timestamp :: function((i64) -> timestamp)

# ===== Math helpers =====

std.abs_i64     :: function((i64) -> i64)
std.abs_f64     :: function((f64) -> f64)
std.abs_numeric :: function((numeric) -> numeric)

std.sign_i64     :: function((i64) -> i64)
std.sign_f64     :: function((f64) -> i64)
std.sign_numeric :: function((numeric) -> integer)

std.sqrt_f64   :: function((f64) -> f64)

std.pow_f64 :: function((f64, f64) -> f64)
std.ln_f64  :: function((f64) -> f64)
std.log_f64 :: function((f64, base: f64) -> f64)

std.ceil_f64      :: function((f64) -> i64)
std.floor_f64     :: function((f64) -> i64)
std.round_f64     :: function((f64) -> i64)
std.ceil_numeric  :: function((numeric) -> integer)
std.floor_numeric :: function((numeric) -> integer)
std.round_numeric :: function((numeric) -> integer)

std.is_nan      :: function((f64) -> boolean)
std.is_infinite :: function((f64) -> boolean)
std.is_finite   :: function((f64) -> boolean)

# ===== Struct =====

std.struct_get :: function((S, key: string) -> V)

# ===== Aggregates =====

agg:sum   :: aggregate_function((i64) -> i64)
agg:sum   :: aggregate_function((numeric) -> numeric)
agg:sum   :: aggregate_function((f64) -> f64)
agg:count :: aggregate_function(() -> i64)
agg:avg   :: aggregate_function((i64) -> f64)
agg:avg   :: aggregate_function((numeric) -> numeric)
agg:avg   :: aggregate_function((f64) -> f64)
agg:min   :: aggregate_function((i64) -> i64)
agg:min   :: aggregate_function((numeric) -> numeric)
agg:min   :: aggregate_function((f64) -> f64)
agg:max   :: aggregate_function((i64) -> i64)
agg:max   :: aggregate_function((numeric) -> numeric)
agg:max   :: aggregate_function((f64) -> f64)

# ===== Operator type-variable declarations =====
# (documentation only — concrete resolution uses hardcoded tables below)

"+"  :: function((T, T) -> T)
"-"  :: function((T, T) -> T)
"*"  :: function((T, T) -> T)
"/"  :: function((T, T) -> T)
"%"  :: function((T, T) -> T)
"="  :: function((T, T) -> boolean)
"!=" :: function((T, T) -> boolean)
"<"  :: function((T, T) -> boolean)
">"  :: function((T, T) -> boolean)
"<=" :: function((T, T) -> boolean)
">=" :: function((T, T) -> boolean)
"++" :: function((T, T) -> T)

"-"  :: function((T) -> T)       # unary negation
"~"  :: function((bits) -> bits)
"not" :: function((boolean) -> boolean)
"and" :: function((boolean, boolean) -> boolean)
"or"  :: function((boolean, boolean) -> boolean)
"<<"  :: function((bits, integer) -> bits)
">>"  :: function((bits, integer) -> bits)
"<<<" :: function((bits, integer) -> bits)
">>>" :: function((bits, integer) -> bits)
"|"   :: function((bits, bits) -> bits)
"^"   :: function((bits, bits) -> bits)
"&"   :: function((bits, bits) -> bits)
```

---

## 3. Hardcoded Tables (in `gdbsp_builtins.erl`)

Three tables replace `fn_overloads`:

### 3.1 Operator → Method Mapping

```erlang
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
binop_fn_name('^')   -> <<"^">>;

-spec unop_fn_name(atom()) -> binary().
unop_fn_name('-')   -> <<"-">>;
unop_fn_name('~')   -> <<"~">>;
unop_fn_name('not') -> <<"not">>.
```

### 3.2 Operator Validity

```erlang
-type operand_type_set() :: [gdbsp_column_type() | all_except | same_width_ints].

-spec operand_types(binary()) -> operand_type_set().
operand_types(<<"+">>)   -> same_width_ints ++ [integer, numeric, f64, interval];
operand_types(<<"-">>)   -> same_width_ints ++ [integer, numeric, f64, interval];
operand_types(<<"*">>)   -> same_width_ints ++ [integer, numeric, f64];
operand_types(<<"/">>)   -> same_width_ints ++ [integer, numeric, f64];
operand_types(<<"%">>)   -> same_width_ints ++ [integer];
operand_types(<<"=">>)   -> all_except;
operand_types(<<"!=">>)  -> all_except;
operand_types(<<"<">>)   -> all_except;
operand_types(<<">">>)   -> all_except;
operand_types(<<"<=">>)  -> all_except;
operand_types(<<">=">>)  -> all_except;
operand_types(<<"++">>)  -> [string, bytes, bits, array];
operand_types(<<"<<">>)  -> [bits];
operand_types(<<">>">>)  -> [bits];
operand_types(<<"<<<">>) -> [bits];
operand_types(<<">>>">>) -> [bits];
operand_types(<<"|">>)   -> [bits];
operand_types(<<"^">>)   -> [bits];
operand_types(<<"&">>)   -> [bits];
operand_types(<<"not">>) -> [boolean];
operand_types(<<"and">>) -> [boolean];
operand_types(<<"or">>)  -> [boolean];
operand_types(<<"~">>)   -> [bits].
```

Where:

- `same_width_ints` = `[i8, i16, i32, i64, u8, u16, u32, u64]`
- `all_except` = all concrete scalar/container types EXCEPT `closure` and `dynamic`
- `array` and `bits` here refer to the unparameterized type atom in the validity check
- `boolean` is canonicalized to `{enum, [<<"false">>, <<"true">>]}` during parsing

### 3.3 Concrete Function Name Resolution

```erlang
-spec concrete_fn(binary(), [gdbsp_column_type()], [{binary(), gdbsp_column_type()}]) ->
    binary() | {error, term()}.
concrete_fn(<<"+">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.add_", (type_suffix(T))/binary>>;
concrete_fn(<<"+">>, [integer, integer], #{}) -> <<"std.add_integer">>;
concrete_fn(<<"+">>, [numeric, numeric], #{}) -> <<"std.add_numeric">>;
concrete_fn(<<"+">>, [f64, f64], #{})         -> <<"std.add_f64">>;
concrete_fn(<<"+">>, [interval, interval], #{}) -> <<"std.add_interval">>;

concrete_fn(<<"-">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.sub_", (type_suffix(T))/binary>>;
concrete_fn(<<"-">>, [integer, integer], #{}) -> <<"std.sub_integer">>;
concrete_fn(<<"-">>, [numeric, numeric], #{}) -> <<"std.sub_numeric">>;
concrete_fn(<<"-">>, [f64, f64], #{})         -> <<"std.sub_f64">>;
concrete_fn(<<"-">>, [interval, interval], #{}) -> <<"std.sub_interval">>;

concrete_fn(<<"*">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.mul_", (type_suffix(T))/binary>>;
concrete_fn(<<"*">>, [integer, integer], #{}) -> <<"std.mul_integer">>;
concrete_fn(<<"*">>, [numeric, numeric], #{}) -> <<"std.mul_numeric">>;
concrete_fn(<<"*">>, [f64, f64], #{})         -> <<"std.mul_f64">>;

concrete_fn(<<"/">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.div_", (type_suffix(T))/binary>>;
concrete_fn(<<"/">>, [integer, integer], #{}) -> <<"std.div_integer">>;
concrete_fn(<<"/">>, [numeric, numeric], #{}) -> <<"std.div_numeric">>;
concrete_fn(<<"/">>, [f64, f64], #{})         -> <<"std.div_f64">>;

concrete_fn(<<"%">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.mod_", (type_suffix(T))/binary>>;
concrete_fn(<<"%">>, [integer, integer], #{}) -> <<"std.mod_integer">>;

concrete_fn(<<"=">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.eq_", (type_suffix(T))/binary>>;
concrete_fn(<<"=">>, [integer, integer], #{}) -> <<"std.eq_integer">>;
concrete_fn(<<"=">>, [f64, f64], #{})         -> <<"std.eq_f64">>;
concrete_fn(<<"=">>, [numeric, numeric], #{}) -> <<"std.eq_numeric">>;
concrete_fn(<<"=">>, [string, string], #{})   -> <<"std.eq_string">>;
concrete_fn(<<"=">>, [{enum, _}, {enum, _}], #{}) -> <<"std.eq_boolean">>;
concrete_fn(<<"=">>, [bytes, bytes], #{})     -> <<"std.eq_bytes">>;
concrete_fn(<<"=">>, [bits, bits], #{})       -> <<"std.eq_bits">>;
concrete_fn(<<"=">>, [date, date], #{})       -> <<"std.eq_date">>;
concrete_fn(<<"=">>, [time, time], #{})       -> <<"std.eq_time">>;
concrete_fn(<<"=">>, [timestamp, timestamp], #{}) -> <<"std.eq_timestamp">>;
concrete_fn(<<"=">>, [timestamp_with_timezone, timestamp_with_timezone], #{}) ->
    <<"std.eq_timestamp_tz">>;
concrete_fn(<<"=">>, [interval, interval], #{}) -> <<"std.eq_interval">>;

concrete_fn(<<"!=">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.neq_", (type_suffix(T))/binary>>;
concrete_fn(<<"!=">>, [integer, integer], #{}) -> <<"std.neq_integer">>;
concrete_fn(<<"!=">>, [f64, f64], #{})         -> <<"std.neq_f64">>;
concrete_fn(<<"!=">>, [numeric, numeric], #{}) -> <<"std.neq_numeric">>;
concrete_fn(<<"!=">>, [string, string], #{})   -> <<"std.neq_string">>;
concrete_fn(<<"!=">>, [{enum, _}, {enum, _}], #{}) -> <<"std.neq_boolean">>;
concrete_fn(<<"!=">>, [bytes, bytes], #{})     -> <<"std.neq_bytes">>;
concrete_fn(<<"!=">>, [bits, bits], #{})       -> <<"std.neq_bits">>;
concrete_fn(<<"!=">>, [date, date], #{})       -> <<"std.neq_date">>;
concrete_fn(<<"!=">>, [time, time], #{})       -> <<"std.neq_time">>;
concrete_fn(<<"!=">>, [timestamp, timestamp], #{}) -> <<"std.neq_timestamp">>;
concrete_fn(<<"!=">>, [timestamp_with_timezone, timestamp_with_timezone], #{}) ->
    <<"std.neq_timestamp_tz">>;
concrete_fn(<<"!=">>, [interval, interval], #{}) -> <<"std.neq_interval">>;

concrete_fn(<<"<">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.lt_", (type_suffix(T))/binary>>;
concrete_fn(<<"<">>, [integer, integer], #{}) -> <<"std.lt_integer">>;
concrete_fn(<<"<">>, [f64, f64], #{})         -> <<"std.lt_f64">>;
concrete_fn(<<"<">>, [numeric, numeric], #{}) -> <<"std.lt_numeric">>;
concrete_fn(<<"<">>, [string, string], #{})   -> <<"std.lt_string">>;
concrete_fn(<<"<">>, [{enum, _}, {enum, _}], #{}) -> <<"std.lt_boolean">>;
concrete_fn(<<"<">>, [bytes, bytes], #{})     -> <<"std.lt_bytes">>;
concrete_fn(<<"<">>, [bits, bits], #{})       -> <<"std.lt_bits">>;
concrete_fn(<<"<">>, [date, date], #{})       -> <<"std.lt_date">>;
concrete_fn(<<"<">>, [time, time], #{})       -> <<"std.lt_time">>;
concrete_fn(<<"<">>, [timestamp, timestamp], #{}) -> <<"std.lt_timestamp">>;
concrete_fn(<<"<">>, [timestamp_with_timezone, timestamp_with_timezone], #{}) ->
    <<"std.lt_timestamp_tz">>;
concrete_fn(<<"<">>, [interval, interval], #{}) -> <<"std.lt_interval">>;

concrete_fn(<<">">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.gt_", (type_suffix(T))/binary>>;
concrete_fn(<<">">>, [integer, integer], #{}) -> <<"std.gt_integer">>;
concrete_fn(<<">">>, [f64, f64], #{})         -> <<"std.gt_f64">>;
concrete_fn(<<">">>, [numeric, numeric], #{}) -> <<"std.gt_numeric">>;
concrete_fn(<<">">>, [string, string], #{})   -> <<"std.gt_string">>;
concrete_fn(<<">">>, [{enum, _}, {enum, _}], #{}) -> <<"std.gt_boolean">>;
concrete_fn(<<">">>, [bytes, bytes], #{})     -> <<"std.gt_bytes">>;
concrete_fn(<<">">>, [bits, bits], #{})       -> <<"std.gt_bits">>;
concrete_fn(<<">">>, [date, date], #{})       -> <<"std.gt_date">>;
concrete_fn(<<">">>, [time, time], #{})       -> <<"std.gt_time">>;
concrete_fn(<<">">>, [timestamp, timestamp], #{}) -> <<"std.gt_timestamp">>;
concrete_fn(<<">">>, [timestamp_with_timezone, timestamp_with_timezone], #{}) ->
    <<"std.gt_timestamp_tz">>;
concrete_fn(<<">">>, [interval, interval], #{}) -> <<"std.gt_interval">>;

concrete_fn(<<"<=">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.lte_", (type_suffix(T))/binary>>;
concrete_fn(<<"<=">>, [integer, integer], #{}) -> <<"std.lte_integer">>;
concrete_fn(<<"<=">>, [f64, f64], #{})         -> <<"std.lte_f64">>;
concrete_fn(<<"<=">>, [numeric, numeric], #{}) -> <<"std.lte_numeric">>;
concrete_fn(<<"<=">>, [string, string], #{})   -> <<"std.lte_string">>;
concrete_fn(<<"<=">>, [{enum, _}, {enum, _}], #{}) -> <<"std.lte_boolean">>;
concrete_fn(<<"<=">>, [bytes, bytes], #{})     -> <<"std.lte_bytes">>;
concrete_fn(<<"<=">>, [bits, bits], #{})       -> <<"std.lte_bits">>;
concrete_fn(<<"<=">>, [date, date], #{})       -> <<"std.lte_date">>;
concrete_fn(<<"<=">>, [time, time], #{})       -> <<"std.lte_time">>;
concrete_fn(<<"<=">>, [timestamp, timestamp], #{}) -> <<"std.lte_timestamp">>;
concrete_fn(<<"<=">>, [timestamp_with_timezone, timestamp_with_timezone], #{}) ->
    <<"std.lte_timestamp_tz">>;
concrete_fn(<<"<=">>, [interval, interval], #{}) -> <<"std.lte_interval">>;

concrete_fn(<<">=">>, [T, T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.gte_", (type_suffix(T))/binary>>;
concrete_fn(<<">=">>, [integer, integer], #{}) -> <<"std.gte_integer">>;
concrete_fn(<<">=">>, [f64, f64], #{})         -> <<"std.gte_f64">>;
concrete_fn(<<">=">>, [numeric, numeric], #{}) -> <<"std.gte_numeric">>;
concrete_fn(<<">=">>, [string, string], #{})   -> <<"std.gte_string">>;
concrete_fn(<<">=">>, [{enum, _}, {enum, _}], #{}) -> <<"std.gte_boolean">>;
concrete_fn(<<">=">>, [bytes, bytes], #{})     -> <<"std.gte_bytes">>;
concrete_fn(<<">=">>, [bits, bits], #{})       -> <<"std.gte_bits">>;
concrete_fn(<<">=">>, [date, date], #{})       -> <<"std.gte_date">>;
concrete_fn(<<">=">>, [time, time], #{})       -> <<"std.gte_time">>;
concrete_fn(<<">=">>, [timestamp, timestamp], #{}) -> <<"std.gte_timestamp">>;
concrete_fn(<<">=">>, [timestamp_with_timezone, timestamp_with_timezone], #{}) ->
    <<"std.gte_timestamp_tz">>;
concrete_fn(<<">=">>, [interval, interval], #{}) -> <<"std.gte_interval">>;

concrete_fn(<<"-">>, [T], #{}) when ?IS_FIXED_INT(T) ->
    <<"std.neg_", (type_suffix(T))/binary>>;
concrete_fn(<<"-">>, [integer], #{}) -> <<"std.neg_integer">>;
concrete_fn(<<"-">>, [f64], #{})     -> <<"std.neg_f64">>;
concrete_fn(<<"-">>, [numeric], #{}) -> <<"std.neg_numeric">>;

concrete_fn(<<"not">>, [{enum, _}], #{}) -> <<"std.not">>;
concrete_fn(<<"and">>, [{enum, _}, {enum, _}], #{}) -> <<"std.and">>;
concrete_fn(<<"or">>,  [{enum, _}, {enum, _}], #{}) -> <<"std.or">>;

concrete_fn(<<"++">>, [string, string], #{}) -> <<"std.concat_string">>;
concrete_fn(<<"++">>, [bytes, bytes], #{}) -> <<"std.concat_bytes">>;
concrete_fn(<<"++">>, [bits, bits], #{}) -> <<"std.concat_bits">>;
concrete_fn(<<"++">>, [{array, T, _}, {array, T, _}], #{}) ->
    <<"std.concat_array">>;

concrete_fn(<<"&">>, [bits, bits], #{}) -> <<"std.bits_and">>;
concrete_fn(<<"|">>, [bits, bits], #{}) -> <<"std.bits_or">>;
concrete_fn(<<"^">>, [bits, bits], #{}) -> <<"std.bits_xor">>;
concrete_fn(<<"~">>, [bits], #{})       -> <<"std.bits_not">>;
concrete_fn(<<"<<">>, [bits, integer], #{})  -> <<"std.bits_shl">>;
concrete_fn(<<">>">>, [bits, integer], #{})  -> <<"std.bits_shr">>;
concrete_fn(<<"<<<">>, [bits, integer], #{}) -> <<"std.bits_rotl">>;
concrete_fn(<<">>>">>, [bits, integer], #{}) -> <<"std.bits_rotr">>;

concrete_fn(_, _, _) -> {error, not_an_operator}.
```

`type_suffix/1` maps narrow integer atoms to the type name:

```erlang
-define(IS_FIXED_INT(T),
    (T =:= i8 orelse T =:= i16 orelse T =:= i32 orelse T =:= i64 orelse
     T =:= u8 orelse T =:= u16 orelse T =:= u32 orelse T =:= u64)).

type_suffix(i8)  -> <<"i8">>;
type_suffix(i16) -> <<"i16">>;
type_suffix(i32) -> <<"i32">>;
type_suffix(i64) -> <<"i64">>;
type_suffix(u8)  -> <<"u8">>;
type_suffix(u16) -> <<"u16">>;
type_suffix(u32) -> <<"u32">>;
type_suffix(u64) -> <<"u64">>.
```

### 3.4 Implementation Lookup

```erlang
-spec fn_impl(binary()) -> {module(), atom(), non_neg_integer()} | agg_impl().

fn_impl(<<"std.add_i64">>)      -> {gdbsp_math, math_add_i64_i64, 2};
fn_impl(<<"std.add_numeric">>)  -> {gdbsp_math, math_add_numeric_numeric, 2};
fn_impl(<<"std.eq_i64">>)       -> {gdbsp_math, math_eq_i64_i64, 2};
fn_impl(<<"std.not">>)          -> {gdbsp_std, std_not_boolean, 1};
fn_impl(<<"std.string_upper">>) -> {gdbsp_string, string_upper, 1};
fn_impl(<<"std.struct_get">>)   -> {gdbsp_struct, struct_get, 2};
fn_impl(<<"std.concat_array">>) -> {gdbsp_array, array_concat, 2};
%% … one clause per concrete function

%% Aggregates return a triple: {Init, Feed, Result}
fn_impl(<<"agg:sum">>) -> {{gdbsp_agg, agg_sum_init, 0},
                            {gdbsp_agg, agg_sum_feed, 2},
                            {gdbsp_agg, agg_sum_result, 1}};
fn_impl(<<"agg:count">>) -> {{gdbsp_agg, agg_count_init, 0},
                              {gdbsp_agg, agg_count_feed, 2},
                              {gdbsp_agg, agg_count_result, 1}};
%% …
```

---

## 4. Resolution Algorithm

### 4.1 Operator Call

Given `{call, <<"+">>, [{arg, <<"x">>}, {arg, <<"y">>}], #{}}`
where `x: i64`, `y: i64`:

```
1.  Infer arg types → [i64, i64]

2.  Look up <<"+">> in stdlib_map
    → [<<"+">>] is a generic type-variable entry.
    Find the matching generic typespec:
      "+" :: function((T, T) -> T)

3.  Unify type variables with concrete arg types:
      T = i64

4.  Validate: i64 in operand_types(<<"+">>) ✓

5.  Construct concrete name:
      concrete_fn(<<"+">>, [i64, i64], #{}) → <<"std.add_i64">>

6.  Verify concrete name exists in stdlib_map:
      std.add_i64 :: function((i64, i64) -> i64) ✓

7.  Return type = i64 (from stdlib typespec)
```

### 4.2 Regular Builtin Call (no operator)

Given `{call, <<"std.string_upper">>, [{arg, <<"s">>}], #{}}`:

```
1.  Infer arg types → [string]

2.  Look up <<"std.string_upper">> directly in stdlib_map
      std.string_upper :: function((string) -> string) ✓

3.  Return type = string
```

### 4.3 User-Defined Function Call

Given `{call, <<"my_func">>, Args, KwArgs}`:

```
1.  Infer arg types
2.  Look up <<"my_func">> in stdlib_map → not found
3.  Check: is <<"my_func">> a known operator? → No
4.  Check: does #gdbsp_program.fn_defs have "my_func"? → Yes/No
5.  If not found at all → compile error: {unknown_function, <<"my_func">>}
```

### 4.4 `std.struct_get`

Given `{call, <<"struct:get">>, [Obj], #{<<"key">> => KeyExpr}}`:

```
1.  Infer Obj type → {struct, #{<<"x">> => i64, <<"y">> => string}, exact}
2.  Check KeyExpr is a string literal:
      {value, {string, _}, <<"x">>} ✓
      (if not literal → compile error)
3.  Extract field type: maps:get(<<"x">>, Fields) → i64
4.  Return type = i64
```

This logic is special-cased in the type checker for `std.struct_get`.
It does NOT go through `concrete_fn`.

---

## 5. Type Variable Unification

Type variables appear in operator typespecs loaded from stdlib:

```
"+" :: function((T, T) -> T)
"=" :: function((T, T) -> boolean)
"++" :: function((T, T) -> T)
std.concat_array :: function((array(T), array(T)) -> array(T))
std.map_merge :: function((map(K, V), map(K, V)) -> map(K, V))
```

### 5.1 Unification Rules

Given an operator typespec with type variable `T` and concrete argument
types `[A1, A2, …]`:

1. Walk through the signature, position by position.
2. Where a type variable appears, substitute it with the corresponding
   concrete argument type at that position.
3. If the SAME type variable appears in multiple positions, ALL
   positions must unify to the SAME concrete type.
4. Keyword argument positions also participate — a type var in a
   keyword position unifies with the concrete keyword arg type.

### 5.2 Example

```
Typespec:  std.map_merge :: function((map(K, V), map(K, V)) -> map(K, V))
Arguments: map(string, i64), map(string, i64)

Position 1: map(K, V) unifies with map(string, i64) → K=string, V=i64
Position 2: map(K, V) unifies with map(string, i64) → K=string, V=i64 ✓
Return:     map(string, i64)
```

```
Typespec:  "+" :: function((T, T) -> T)
Arguments: i64, i64

Position 1: T = i64
Position 2: T = i64 ✓
Return:     i64
```

```
Typespec:  "+" :: function((T, T) -> T)
Arguments: i64, f64

Position 1: T = i64
Position 2: T = f64 — CONFLICT → type mismatch error
```

### 5.3 Implementation

A simple substitution map `#{{type_var, Name} => concrete_type}` suffices:

```erlang
-spec unify_types([gdbsp_column_type()], [gdbsp_column_type()], Substitutions) ->
    {ok, Substitutions} | {error, term()}.

unify_types([], [], Subs) -> {ok, Subs};
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
```

---

## 6. stdlib Loading

### 6.1 Startup

`grasp_dbsp.app.src` already depends on `stdlib`. At application start:

```erlang
-spec load_stdlib() -> #{binary() => [#gdbsp_typespec{}]}.
load_stdlib() ->
    PrivDir = code:priv_dir(grasp_dbsp),
    Path = filename:join(PrivDir, "stdlib.gdbsp"),
    {ok, Bin} = file:read_file(Path),
    {ok, Prog} = gdbsp_parse:parse_string(Bin, #{}),
    build_stdlib_map(Prog#gdbsp_program.typespecs).
```

The result is cached in persistent term and passed to
`gdbsp_compile:compile/2`.

### 6.2 Compiler Integration

```erlang
lookup_in_stdlib_or_inline(Name, StdlibMap, InlineFnDefs) ->
    case maps:find(Name, StdlibMap) of
        {ok, _TS} -> {stdlib, Name};    % found concrete entry
        error ->
            % Check if it's an operator → resolve via tables
            % Check if it's defined inline → return inline body
            % Otherwise → compile error
            error
    end.
```

---

## 7. Files Changed

| Action   | File                                      | Scope |
|----------|--------------------------------------------|-------|
| CREATE   | `priv/stdlib.gdbsp`                        | Full stdlib with concrete typespecs |
| REMOVE   | `src/gdbsp_builtins.erl:fn_overloads/1`    | ~750 lines deleted |
| ADD      | `src/gdbsp_builtins.erl` tables            | `operand_types/1`, `concrete_fn/3`, `fn_impl/1`, `unify_types/3` |
| MODIFY   | `src/gdbsp_builtins.erl:binop_fn_name/1`   | Return operator char, not method name |
| MODIFY   | `src/gdbsp_compile_expr.erl`               | Lowering uses operator chars. `infer_expr_type` uses new resolution. Add `std.struct_get` special case |
| MODIFY   | `src/gdbsp_type_infer.erl`                 | Replace `lookup_fn` with new resolution. `struct:get` → `std.struct_get` |
| MODIFY   | `src/gdbsp_compile.erl`                    | Load stdlib at startup, pass through pipeline |
| MODIFY   | `src/gdbsp_parse.erl`                      | Parse `"+"` etc. as identifiers in typespec position. Canonicalize `string`/`boolean` aliases |
| MODIFY   | `include/gdbsp_type.hrl`                   | Add type-variable substitution tracking |
| CREATE   | `test/gdbsp_builtins_SUITE.erl`            | Unit tests for tables + unification |
| MODIFY   | `test/gdbsp_compile_expr_SUITE.erl`        | Update for operator chars |
| MODIFY   | `test/gdbsp_compile_SUITE.erl`             | Update lowered-expr expectations |
| MODIFY   | `test/gdbsp_type_infer_SUITE.erl`          | Update for new resolution |
| MODIFY   | `test/parse_fixtures/parse.yaml`           | Add type-var typespec cases |
| MODIFY   | `rebar.config`                             | Add `priv/` to release |

---

## 8. Implementation Phases

| Phase | Description                          | Risk  | Tests changed |
|-------|--------------------------------------|-------|---------------|
| **A** | Create `priv/stdlib.gdbsp`, wire loading in `gdbsp_compile.erl` | Low | New loading tests |
| **B** | Rewrite `gdbsp_builtins.erl` — remove `fn_overloads`, add 3 tables + `unify_types` | Medium | New `gdbsp_builtins_SUITE` |
| **C** | Modify lowering (`gdbsp_compile_expr.erl`) — use operator chars, `std.struct_get` special case, new resolution in `infer_expr_type` | Medium | Update `gdbsp_compile_expr_SUITE` |
| **D** | Modify `gdbsp_type_infer.erl` — switch to new resolution, remove old `lookup_fn`/`match_overloads` calls | Medium | Update `gdbsp_type_infer_SUITE` |
| **E** | Parser: support `"+"` tokens in typespec name position, canonicalize aliases | Low | Update parse.yaml |
| **F** | Update remaining tests, full regression | Low | All other suites |

---

## 9. References

- [syntax.md](../syntax.md) §5 — Function definition and typespec grammar
- [stdlib.md](../stdlib.md) — Current stdlib documentation (will be updated post-implementation)
- [type-inference.md](../type-inference.md) — Type inference overview
- [type-system.md](../type-system.md) — Type system specification
