# Grasp DBSP — Standard Library

Date: 2026-07-29
Status: draft

---

## 1. Expression JSON Format

Function bodies for `map`, `filter`, and `flat_map` operators are defined
externally as JSON expression trees. The `.gdbsp` source references them by
name only — the actual computation is provided via the function registry.

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
{"type": "date",    "value": {"year": "2026", "month": "6", "day": "18"}}
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

Individual fields are accessed via `struct:get` (see §1.4):

```json
{"call": "struct:get",
 "args": [{"arg": "row"}],
 "kwargs": {"key": {"type": "string", "value": "age"}}}
```

### 1.4 Call Node

A function call. All operators are desugared to their stdlib equivalents
(e.g. `+` → `integer:add`, `>` → `integer:gt`). See §3 for the function catalog.

```json
{"call": "string:upper", "args": [
    {"call": "struct:get",
     "args": [{"arg": "row"}],
     "kwargs": {"key": {"type": "string", "value": "name"}}}
]}

{"call": "integer:add", "args": [
    {"call": "struct:get",
     "args": [{"arg": "row"}],
     "kwargs": {"key": {"type": "string", "value": "x"}}},
    {"type": "i64", "value": "1"}
]}

{"call": "string:substring",
 "args": [
    {"call": "struct:get",
     "args": [{"arg": "row"}],
     "kwargs": {"key": {"type": "string", "value": "text"}}}
 ],
 "kwargs": {
     "start":  {"type": "i64", "value": "0"},
     "length": {"type": "i64", "value": "10"}
 }}

{"call": "agg:count"}
```

- `"args"` — positional arguments. Omitted when empty.
- `"kwargs"` — keyword arguments. Omitted when empty.

### 1.5 Aggregate Node

An aggregate function call. Same structure as call but uses the
`"aggregate"` discriminator. Used when registering aggregate functions
in the function registry.

```json
{"aggregate": "agg:sum", "args": [{"field": "amount"}]}
{"aggregate": "agg:count"}
```

### 1.6 Conventions

1. **Omit when empty.** `"args"` and `"kwargs"` are omitted from call and
   aggregate nodes when empty.
2. **Desugared operators.** All infix operators use their stdlib function
   names: `"integer:add"` (not `"+"`), `"integer:gt"` (not `">"`),
   `"boolean:and"` (not `"and"`).
3. **Function arguments via `arg`.** `{"arg": "row"}` references the
   single function parameter (the input row). Individual fields are accessed
   via `struct:get(arg: row, "col")`.
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
| `date` | `{"year": "2026", "month": "6", "day": "18"}` |
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

### 3.1 `agg:` — Aggregate Functions

Aggregate functions reduce a set of rows to a single value. They are
referenced in the `"aggregate"` discriminator in expression trees and
declared in `.gdbsp` source via `:: aggregate_function(...)`.

| Function | Signatures | Return Type Rule |
|----------|-----------|-----------------|
| `agg:sum` | `(i8)→i64`, `(i16)→i64`, `(i32)→i64`, `(i64)→i64`, `(u8)→i64`, `(u16)→i64`, `(u32)→i64`, `(u64)→i64`, `(integer)→i64`, `(f32)→f64`, `(f64)→f64`, `(numeric)→numeric` | Integer inputs narrow to `i64`, float inputs widen to `f64`, numeric preserved |
| `agg:count` | `() → i64` | Always `i64` |
| `agg:avg` | `(integer)→f64`, `(f64)→f64`, `(numeric)→numeric` | Float/integer inputs → `f64`, numeric preserved |
| `agg:min` | `(T) → T` (where T is integer/f64/numeric) | Preserves input type |
| `agg:max` | `(T) → T` (where T is integer/f64/numeric) | Preserves input type |
| `agg:first` | `(T) → T` | Preserves input type |
| `agg:last` | `(T) → T` | Preserves input type |

### 3.2 Scalar Functions

The following scalar functions are available for use in `"call"` nodes
within expression trees. Only functions relevant to Grasp DBSP's current
operator set (`map`, `filter`, `flat_map`) are documented. Additional
functions may be added over time.

Operators that desugar to scalar functions:

| Operator | Function |
|----------|----------|
| `+` | `integer:add` / `float:add` / `numeric:add` |
| `-` | `integer:sub` / `float:sub` / `numeric:sub` |
| `*` | `integer:mul` / `float:mul` / `numeric:mul` |
| `/` | `integer:div` / `float:div` / `numeric:div` |
| `>` | `integer:gt` / `float:gt` / `numeric:gt` |
| `<` | `integer:lt` / `float:lt` / `numeric:lt` |
| `>=` | `integer:gte` / `float:gte` / `numeric:gte` |
| `<=` | `integer:lte` / `float:lte` / `numeric:lte` |
| `==` | `integer:eq` / `float:eq` / `string:eq` / ... |
| `!=` | `integer:neq` / `float:neq` / `string:neq` / ... |

#### `boolean:` — Logic

| Function | Signature |
|----------|-----------|
| `boolean:not` | `(boolean) → boolean` |
| `boolean:and` | `(boolean, boolean) → boolean` |
| `boolean:or` | `(boolean, boolean) → boolean` |

#### `string:` — Strings

Inspection:

| Function | Signature |
|----------|-----------|
| `string:length` | `(string) → integer` |
| `string:starts_with` | `(string, prefix: string) → boolean` |
| `string:ends_with` | `(string, suffix: string) → boolean` |
| `string:contains` | `(string, sub: string) → boolean` |

Case:

| Function | Signature |
|----------|-----------|
| `string:upper` | `(string) → string` |
| `string:lower` | `(string) → string` |

Trimming:

| Function | Signature |
|----------|-----------|
| `string:trim` | `(string) → string` |
| `string:ltrim` | `(string) → string` |
| `string:rtrim` | `(string) → string` |

Manipulation:

| Function | Signature |
|----------|-----------|
| `string:substring` | `(string, start: i64) → string` |
| `string:substring` | `(string, start: i64, length: i64) → string` |
| `string:replace` | `(string, from: string, to: string) → string` |
| `string:split` | `(string, delimiter: string) → array(string)` |
| `string:concat` | `(string, string) → string` |

Comparison:

| Function | Signature |
|----------|-----------|
| `string:eq` | `(string, string) → boolean` |
| `string:neq` | `(string, string) → boolean` |
| `string:lt` | `(string, string) → boolean` |
| `string:gt` | `(string, string) → boolean` |
| `string:lte` | `(string, string) → boolean` |
| `string:gte` | `(string, string) → boolean` |

#### Comparison (generic)

Comparison operators use namespace-specific functions:

| Function | Signature |
|----------|-----------|
| `integer:eq`, `integer:neq`, `integer:lt`, `integer:gt`, `integer:lte`, `integer:gte` | `(i64, i64) → boolean` |
| `float:eq`, `float:neq`, `float:lt`, `float:gt`, `float:lte`, `float:gte` | `(f64, f64) → boolean` |
| `numeric:eq`, `numeric:neq`, `numeric:lt`, `numeric:gt`, `numeric:lte`, `numeric:gte` | `(numeric, numeric) → boolean` |
| `integer:add`, `integer:sub`, `integer:mul`, `integer:div` | `(i64, i64) → i64` |
| `float:add`, `float:sub`, `float:mul`, `float:div` | `(f64, f64) → f64` |
| `numeric:add`, `numeric:sub`, `numeric:mul`, `numeric:div` | `(numeric, numeric) → numeric` |

#### Arithmetic helpers

| Function | Signature |
|----------|-----------|
| `integer:mod` | `(i64, i64) → i64` |
| `integer:abs` | `(i64) → i64` |
| `float:abs` | `(f64) → f64` |
| `numeric:abs` | `(numeric) → numeric` |

#### `struct:` — Struct Construction

| Function | Signature |
|----------|-----------|
| `struct` | Builds a struct from kwargs: `{"call": "struct", "kwargs": {"col1": ..., "col2": ...}}` |

Struct construction via `call` uses `"struct"` without a namespace prefix
(the bare name resolves to the struct constructor). Each keyword argument
becomes a field in the output struct. The output type is inferred from the
field types.

---

## 4. Function Registry

Functions and aggregates are registered externally and referenced by
bare identifier in `.gdbsp` source. The registry is a map from function
name to definition.

### 4.1 Regular Functions

Regular functions used by `map`, `filter`, and `flat_map` are registered
with expression trees:

```json
{
    "salary_ge_150": {
        "call": "gte",
        "args": [
            {"call": "struct:get",
             "args": [{"arg": "row"}],
             "kwargs": {"key": {"type": "string", "value": "sal"}}},
            {"type": "i64", "value": "50000"}
        ]
    }
}
```

The expression tree follows the format in §1. When a function name is
referenced in a `map`, `filter`, or `flat_map` operator, the runtime
looks it up in the registry.

Struct constructor functions use the `call` node with `"struct"`:

```json
{
    "rename_fn": {
        "call": "struct",
        "kwargs": {
            "x": {"call": "struct:get",
                  "args": [{"arg": "row"}],
                  "kwargs": {"key": {"type": "string", "value": "a"}}},
            "y": {"call": "struct:get",
                  "args": [{"arg": "row"}],
                  "kwargs": {"key": {"type": "string", "value": "b"}}}
        }
    }
}
```

Flat-map expansion functions use `"call": "struct:get"` to reference the column to unnest:

```json
{
    "unnest_vals": {
        "call": "struct:get",
        "args": [{"arg": "row"}],
        "kwargs": {"key": {"type": "string", "value": "vals"}}
    }
}
```

### 4.2 Aggregate Functions

Aggregate functions are registered with the `"aggregate"` discriminator
pointing to a built-in aggregate name:

```json
{
    "sum_sal": {
        "aggregate": "agg:sum"
    }
}
```

```json
{
    "cnt": {
        "aggregate": "agg:count"
    }
}
```

The `"aggregate"` key maps the declared name (used in `.gdbsp` source) to
the internal aggregate implementation. Built-in aggregate names are listed
in §3.1.
