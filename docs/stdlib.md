# Grasp DBSP — Standard Library

Date: 2026-08-23
Status: current

---

## 1. Expression JSON Format

Function bodies for `map`, `filter`, and `flat_map` operators are defined
as JSON expression trees. Bodies are authored **inline** in `.gdbsp` source
using Grasp expression syntax (see [grasp-dbsp.md](grasp-dbsp.md) and
[syntax.md](syntax.md) §6). The compiler desugars and lowers inline expressions
to the JSON format described here, which is the runtime representation.

An expression tree is a recursive JSON structure. Each node is a JSON
object identified by a unique **discriminator key**.

### 1.1 Node Types

| Node | Discriminator | Meaning |
|------|-------------|---------|
| value | `"type"` | Typed literal constant |
| arg | `"arg"` | Function argument reference |
| call | `"call"` | Function call (post-desugaring) |
| aggregate | `"aggregate"` | Aggregate function call |

### 1.2 Value Node

A typed literal constant. The `"type"` key carries the type JSON
(see [type-system.md](type-system.md) §11), and `"value"` carries the
encoded value (see §2 of this document).

```json
{"type": "i64",     "value": "42"}
{"type": "string",  "value": "hello"}
{"type": "f64",     "value": "3.14"}
{"type": "f64",     "value": "inf"}
{"type": "numeric", "value": "123.45"}
{"type": "timestamp", "value": {"epoch_microseconds": "1718640000000000"}}
{"type": "date",    "value": {"days_since_2000": "9665"}}
{"type": "bytes",   "value": {"encoding": "base64", "value": "AQID"}}
{"type": "boolean", "value": "true"}
```

### 1.3 Arg Node

A reference to a function argument. Map and filter functions receive a single
argument conventionally named `"row"`, which is the entire input struct row.
Accessing `{"arg": "row"}` returns the complete row, enabling pass-through.

```json
{"arg": "row"}
```

Individual fields are accessed via `std.struct_get` (see §1.4):

```json
{"call": "std.struct_get",
 "args": [{"arg": "row"}],
 "kwargs": {"key": {"type": "string", "value": "age"}}}
```

### 1.4 Call Node

A function call. All operators are desugared to their operator-character
name (`+`, `>`, `and`, …) and then resolved to a concrete stdlib function
(e.g. `+` → `std.add_i64`, `>` → `std.gt_i64`). See §3 for the function catalog.

```json
{"call": "std.string_upper", "args": [
    {"call": "std.struct_get",
     "args": [{"arg": "row"}],
     "kwargs": {"key": {"type": "string", "value": "name"}}}
]}

{"call": "std.add_i64", "args": [
    {"call": "std.struct_get",
     "args": [{"arg": "row"}],
     "kwargs": {"key": {"type": "string", "value": "x"}}},
    {"type": "i64", "value": "1"}
]}

{"call": "std.string_substring",
 "args": [
    {"call": "std.struct_get",
     "args": [{"arg": "row"}],
     "kwargs": {"key": {"type": "string", "value": "text"}}}
 ],
 "kwargs": {
     "start":  {"type": "i64", "value": "0"},
     "length": {"type": "i64", "value": "10"}
 }}

{"call": "std.agg_count"}
```

- `"args"` — positional arguments. Omitted when empty.
- `"kwargs"` — keyword arguments. Omitted when empty.

### 1.5 Aggregate Node

An aggregate function call. Same structure as call but uses the
`"aggregate"` discriminator. Used for the internal representation of
aggregate references.

```json
{"aggregate": "std.agg_sum_i64",
 "args": [{"call": "std.struct_get",
           "args": [{"arg": "row"}],
           "kwargs": {"key": {"type": "string", "value": "amount"}}}]}
{"aggregate": "std.agg_count"}
```

### 1.6 Conventions

1. **Omit when empty.** `"args"` and `"kwargs"` are omitted from call and
   aggregate nodes when empty.
2. **Desugared operators.** All infix operators desugar to their
   operator-character name (`+` not `add`, `>` not `gt`, `and` not the `and`
   keyword). At type-check time the operator is resolved to a concrete
   `std.*` function (see §3).
3. **Function arguments via `arg`.** `{"arg": "row"}` references the
   single function parameter (the input row). Individual fields are accessed
   via `std.struct_get(arg: row, "col")`.
4. **Value encoding.** Value leaf nodes use the encoding defined in §2:
   numbers as strings, temporal components as strings, etc.

### 1.7 Decoding

The decoder identifies node kind by discriminator key, checked in this
priority order:

1. `"arg"` → arg node
2. `"call"` → call node
3. `"aggregate"` → aggregate node
4. `"type"` → value node

Unrecognized nodes (no matching discriminator key) are an error.

All nodes are self-describing.

---

## 2. Value Encoding

This section defines the JSON wire encoding for each type. The encoding
follows [type-system.md](type-system.md) §11 for type representation and
the design principles below.

### 2.1 Design Principles

1. **Lossless round-trip.** `decode(type, encode(type, value)) = value`
   for every type and every valid value.
2. **Numbers as strings.** All typed numeric values (integers, floats,
   decimal, temporal components) are encoded as JSON strings to avoid
   IEEE 754 double-precision loss.
3. **Encoding in the type, not the value.** When the encoding scheme is
   fixed by the type (e.g. `string` is always UTF-8), the wire value
   carries only the payload. Per-value encoding tags are used only when
   the type allows multiple encodings (`string_with_encoding`, `bytes`, `bits`).
4. **Uniform enum encoding.** All enum values are encoded as JSON strings.
5. **JSON passthrough.** Values of type `json` use native JSON representation.
   Numbers inside JSON values stay as JSON numbers (not stringified).
6. **Optional clarity.** ABSENT (absence) and JSON null (a value) are
   always distinguishable on the wire.

### 2.2 Integers

All integer values are encoded as JSON strings.

| Type | Wire |
|------|------|
| `i8` | `"42"` |
| `i16` | `"-1000"` |
| `i32` | `"2000000000"` |
| `i64` | `"9223372036854775807"` |
| `u8` | `"255"` |
| `u16` | `"65535"` |
| `u32` | `"4294967295"` |
| `u64` | `"0"` |
| `integer` | `"100"` |

### 2.3 Floats

Float values are encoded as JSON strings. Special values use short mnemonics.

| Type | Wire |
|------|------|
| `f64`, value `3.14` | `"3.14"` |
| `f64`, value `infinity` | `"inf"` |
| `f64`, value `-infinity` | `"-inf"` |
| `f64`, value `NaN` | `"nan"` |
| `f32`, value `1.5` | `"1.5"` |

Float string representation must preserve the exact IEEE 754 value
(sufficient decimal digits for lossless round-trip).

### 2.4 Decimal

Decimal values are encoded as JSON strings in standard decimal notation.

| Type | Internal | Wire |
|------|----------|------|
| `numeric` | `{12345, -2}` | `"123.45"` |
| `numeric(5,0)` | `{100, 0}` | `"100"` |
| `numeric` | `{1, -4}` | `"0.0001"` |

Internal representation is `{Coefficient, Exponent}` where the decimal
value is `Coefficient * 10^Exponent`.

### 2.5 Strings

For `string` and `string(Encoding)`, the encoding is fixed by the type.
The wire value is a plain JSON string.

For `string_with_encoding`, each value carries its own encoding tag.

| Type | Wire |
|------|------|
| `string` | `"hello"` |
| `string("CP1251")` | `"data"` |
| `string_with_encoding` | `{"encoding": "CP1251", "value": "data"}` |

### 2.6 Binary

Binary types carry the encoding tag in the wire value.

| Type | Wire |
|------|------|
| `bytes` | `{"encoding": "base64", "value": "AQID"}` |
| `bytes(32)` | `{"encoding": "base64", "value": "..."}` |
| `bits` | `{"encoding": "base64", "value": "gA=="}` |
| `bits(64)` | `{"encoding": "base64", "value": "..."}` |

### 2.7 Enum

All enum values are encoded as JSON strings. This provides uniform encoding
across the enum type family. The JSON `null` literal is reserved for absence
in optional columns and for JSON null inside `json`-typed values — it is
never used for `enum("null")` values.

| Type | Wire |
|------|------|
| `enum("false","true")`, value true | `"true"` |
| `enum("false","true")`, value false | `"false"` |
| `enum("green","red")`, value red | `"red"` |
| `enum("null")` | `"null"` (JSON string, NOT JSON null literal) |

### 2.8 Temporal

Temporal values are encoded as JSON objects. All numeric components
within temporal values are encoded as strings.

| Type | Wire |
|------|------|
| `timestamp` | `{"epoch_microseconds": "1718640000000000"}` |
| `date` | `{"days_since_2000": "9665"}` |
| `time` | `{"hour": "14", "minute": "30", "second": "0", "microsecond": "500000"}` |
| `timestamp_with_timezone` (with zone) | `{"epoch_microseconds": "100", "offset_seconds": "3600", "zone": "Europe/Berlin"}` |
| `timestamp_with_timezone` (no zone) | `{"epoch_microseconds": "100", "offset_seconds": "0"}` |
| `interval` | `{"months": "1", "days": "5", "microseconds": "3600000000"}` |

When `timestamp_with_timezone` has no IANA zone, the `"zone"` key is omitted.

### 2.9 JSON

A `json` value uses native JSON representation. Each value carries its
concrete inner type tag internally.

| JSON value | Wire |
|------------|------|
| number | `42.0` |
| string | `"hi"` |
| true | `true` |
| false | `false` |
| null | `null` |
| array | `[...]` |
| object | `{...}` |

Numbers inside JSON values stay as JSON numbers (not stringified).
All JSON numbers decode to `f64`.

### 2.10 Dynamic

The `dynamic` type wraps values with their concrete type tag:

```json
{"type": <type_json>, "value": <encoded_value>}
```

Examples:

| Value | Wire |
|-------|------|
| `dynamic` wrapping `i64` 42 | `{"type": "i64", "value": "42"}` |
| `dynamic` wrapping `string` "hi" | `{"type": "string", "value": "hi"}` |
| `dynamic` wrapping `timestamp` | `{"type": "timestamp", "value": {"epoch_microseconds": "100"}}` |

### 2.11 Optional and ABSENT

See [type-system.md](type-system.md) §10 for the full semantics of ABSENT
vs JSON null. In summary:

- **Non-optional column** — wire `null` is unambiguous: it can only mean JSON null (for `json` columns) or is rejected (for other types, where absence is not valid).
- **`optional(json)` column** — the `"value"` wrapper distinguishes absence from JSON null:
  - `null` (wire) → ABSENT (absence)
  - `{"value": null}` → JSON null (the value)
  - `{"value": ...}` → JSON value
- **`optional(T)` where T ≠ json** — only two states: `null` for ABSENT, or the encoded value for present.

---

## 3. Built-in Function Catalog

Functions are namespaced. Every function lives under a namespace prefix.
No new names are added to the global scope.

### 3.1 Aggregate Primitives

Aggregate primitives fold a group of rows into a single scalar value. They
are referenced in the `"aggregate"` discriminator inside aggregate-function
bodies (see §4.2) and declared in `.gdbsp` source via
`:: aggregate_function(...)`. Each concrete aggregate is a `std.agg_*` entry
in `priv/stdlib.gdbsp`.

| Function | Signature | Return Type Rule |
|----------|-----------|-----------------|
| `std.agg_sum_i64` | `(i64) → i64` | Sum over i64 |
| `std.agg_sum_integer` | `(integer) → integer` | Sum over integer |
| `std.agg_sum_numeric` | `(numeric) → numeric` | Sum over numeric |
| `std.agg_sum_f64` | `(f64) → f64` | Sum over f64 |
| `std.agg_count` | `() → integer` | Always `integer` |
| `std.agg_avg_integer` | `(integer) → integer` | `floor(sum / count)`; empty group dropped |
| `std.agg_min_i64` | `(i64) → i64` | Minimum |
| `std.agg_min_integer` | `(integer) → integer` | Minimum |
| `std.agg_min_numeric` | `(numeric) → numeric` | Minimum |
| `std.agg_min_f64` | `(f64) → f64` | Minimum |
| `std.agg_max_i64` | `(i64) → i64` | Maximum |
| `std.agg_max_integer` | `(integer) → integer` | Maximum |
| `std.agg_max_numeric` | `(numeric) → numeric` | Maximum |
| `std.agg_max_f64` | `(f64) → f64` | Maximum |
| `std.agg_xor_bytes` | `(bytes) → bytes` | Bitwise XOR fold over bytes |

### 3.2 Scalar Functions

The following scalar functions are available for use in `"call"` nodes
within expression trees. They are declared as `std.*` typespecs in
`priv/stdlib.gdbsp`. Here `string` is shorthand for `string("UTF-8")` and
`boolean` for `enum("false", "true")`.

Operators desugar to their operator-character name and are resolved to
concrete `std.*` functions at type-check time:

| Operator | Concrete stdlib function |
|----------|--------------------------|
| `+` | `std.add_i8` … `std.add_u64`, `std.add_integer`, `std.add_numeric`, `std.add_f64`, `std.add_interval` |
| `-` (binary) | `std.sub_*` (same set as `+`) |
| `-` (unary) | `std.neg_i8` … `std.neg_u64`, `std.neg_integer`, `std.neg_f64`, `std.neg_numeric` |
| `*` | `std.mul_i8` … `std.mul_u64`, `std.mul_integer`, `std.mul_numeric`, `std.mul_f64` |
| `/` | `std.div_*` (same set as `*`) |
| `%` | `std.mod_i8` … `std.mod_u64`, `std.mod_integer` |
| `=` | `std.eq_i8` … `std.eq_u64`, `std.eq_integer`, `std.eq_f64`, `std.eq_string`, `std.eq_numeric`, `std.eq_boolean`, `std.eq_bytes`, `std.eq_bits`, `std.eq_date`, `std.eq_time`, `std.eq_timestamp`, `std.eq_interval` |
| `!=` | `std.neq_*` (same set as `=`) |
| `<`, `<=`, `>`, `>=` | `std.lt_*` / `std.lte_*` / `std.gt_*` / `std.gte_*` (same set as `=`) |
| `and` | `std.and` |
| `or` | `std.or` |
| `not` | `std.not` |
| `++` | `std.concat_string`, `std.concat_bytes`, `std.concat_bits`, `std.concat_array` |
| `\|` | `std.bits_or` |
| `^` | `std.bits_xor` |
| `&` | `std.bits_and` |
| `<<` | `std.bits_shl` |
| `>>` | `std.bits_shr` |
| `<<<` | `std.bits_rotl` |
| `>>>` | `std.bits_rotr` |
| `~` | `std.bits_not` |

The `*` suffix denotes a family of per-type entries. Each is resolved by
`gdbsp_builtins:concrete_fn/3` from the operand types, then matched against
the corresponding typespec in stdlib.

#### Logic

| Function | Signature |
|----------|-----------|
| `std.not` | `(boolean) → boolean` |
| `std.and` | `(boolean, boolean) → boolean` |
| `std.or` | `(boolean, boolean) → boolean` |

#### Strings

Inspection:

| Function | Signature |
|----------|-----------|
| `std.string_length` | `(string) → integer` |
| `std.string_starts_with` | `(string, prefix: string) → boolean` |
| `std.string_ends_with` | `(string, suffix: string) → boolean` |
| `std.string_contains` | `(string, sub: string) → boolean` |

Case:

| Function | Signature |
|----------|-----------|
| `std.string_upper` | `(string) → string` |
| `std.string_lower` | `(string) → string` |

Trimming:

| Function | Signature |
|----------|-----------|
| `std.string_trim` | `(string) → string` |
| `std.string_ltrim` | `(string) → string` |
| `std.string_rtrim` | `(string) → string` |

Manipulation:

| Function | Signature |
|----------|-----------|
| `std.string_substring` | `(string, start: i64) → string` |
| `std.string_substring` | `(string, start: i64, length: i64) → string` |
| `std.string_replace` | `(string, from: string, to: string) → string` |
| `std.string_split` | `(string, delimiter: string) → array(string)` |
| `std.string_at` | `(string, i64) → string` |
| `std.string_slice` | `(string, start: i64, stop: i64, step: i64) → string` |

Comparison:

| Function | Signature |
|----------|-----------|
| `std.string_eq` | `(string, string) → boolean` |
| `std.string_neq` | `(string, string) → boolean` |
| `std.string_lt` | `(string, string) → boolean` |
| `std.string_gt` | `(string, string) → boolean` |
| `std.string_lte` | `(string, string) → boolean` |
| `std.string_gte` | `(string, string) → boolean` |

#### Concat

| Function | Signature |
|----------|-----------|
| `std.concat_string` | `(string, string) → string` |
| `std.concat_bytes` | `(bytes, bytes) → bytes` |
| `std.concat_bits` | `(bits, bits) → bits` |
| `std.concat_array` | `(array(T), array(T)) → array(T)` |

#### Arithmetic helpers

| Function | Signature |
|----------|-----------|
| `std.mod_integer` | `(integer, integer) → integer` |
| `std.abs_i64` | `(i64) → i64` |
| `std.abs_f64` | `(f64) → f64` |
| `std.abs_numeric` | `(numeric) → numeric` |

#### Struct access

| Function | Signature |
|----------|-----------|
| `std.struct_get` | `(S, key: string("UTF-8")) → V` — field access; `key` must be a string literal |
| `std.struct_set` | `(S, key: string("UTF-8"), value: V) → S` — update-only; `key` must be a string literal naming an existing field; `value`'s type must exactly match the field's type |

Non-literal keys in `std.struct_get` / `std.struct_set` are compile errors,
because the result type depends on which field the key selects.

#### Struct construction

Struct construction uses the bare `"struct"` call node (special-cased, not a
stdlib entry):

| Function | Signature |
|----------|-----------|
| `struct` | Builds a struct from kwargs: `{"call": "struct", "kwargs": {"col1": ..., "col2": ...}}` |

Each keyword argument becomes a field in the output struct. The output type is
inferred from the field types.

---

## 4. Function Registry

Functions are authored inline in `.gdbsp` source (`fn := function(...)`) and
referenced by bare identifier in `map` / `filter` / `flat_map` operators. The
registry is a map from function name to the compiled (JSON-encoded) expression
body, produced by the compiler from inline definitions.

### 4.1 Regular Functions

Regular functions used by `map`, `filter`, and `flat_map` are authored inline
in `.gdbsp` source using Grasp expression syntax (see
[grasp-dbsp.md](grasp-dbsp.md)). The compiler lowers the inline expression to
the JSON expression format below, which is also the runtime representation.

Example — lowered JSON body:

```json
{
    "salary_ge_150": {
        "call": ">=",
        "args": [
            {"call": "std.struct_get",
             "args": [{"arg": "row"}],
             "kwargs": {"key": {"type": "string", "value": "sal"}}},
            {"type": "i64", "value": "50000"}
        ]
    }
}
```

The expression tree follows the format in §1. When a function name is
referenced in a `map`, `filter`, or `flat_map` operator, the compiler looks
up the name in the inline function registry, falling back to a stdlib scalar
function for `std.*` names.

Struct constructor functions use the `call` node with `"struct"`:

```json
{
    "rename_fn": {
        "call": "struct",
        "kwargs": {
            "x": {"call": "std.struct_get",
                  "args": [{"arg": "row"}],
                  "kwargs": {"key": {"type": "string", "value": "a"}}},
            "y": {"call": "std.struct_get",
                  "args": [{"arg": "row"}],
                  "kwargs": {"key": {"type": "string", "value": "b"}}}
        }
    }
}
```

A `flat_map` function must return `array(new_row_type)`; each array element
is emitted as a complete output row. A common pattern is to return an
array-valued field directly:

```json
{
    "unnest_vals": {
        "call": "std.struct_get",
        "args": [{"arg": "row"}],
        "kwargs": {"key": {"type": "string", "value": "vals"}}
    }
}
```

Here the input row's `vals` field is `array(struct(...))`, so the output
stream's element type is that `struct(...)`.

### 4.2 Aggregate Functions

Aggregate functions are user-defined: an `aggregate_function` typespec plus a
`:= function(...)` body that takes the input row and returns a struct. The body
references built-in aggregate primitives (`std.agg_*`, see §3.1):

```
payroll :: aggregate_function((struct("dept": i64, "sal": i64)) -> struct("total": i64))
payroll := function((row) -> struct("total": std.agg_sum_i64(row.sal)))

agg := aggregate(src, payroll, by: ["dept"])
```

The output struct is the `by:` fields followed by the returned struct's fields.
