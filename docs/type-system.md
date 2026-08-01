# Grasp DBSP — Type System

Date: 2026-07-29
Status: draft

---

## 1. Type Catalog

Every node in a `.gdbsp` circuit carries a type annotation via
`name :: stream(type)`. Function and aggregate declarations also use
types in their signatures. This document defines every type in the
system.

### 1.1 Scalar Types

| Type | Meaning |
|------|---------|
| `i8`, `i16`, `i32`, `i64` | Signed integers |
| `u8`, `u16`, `u32`, `u64` | Unsigned integers |
| `integer` | Arbitrary-precision integer |
| `f32`, `f64` | IEEE 754 floating-point |
| `numeric` | Arbitrary-precision decimal |
| `numeric(p,s)` | Fixed-precision decimal (`p` total digits, `s` fractional digits) |
| `string("UTF-8")` | UTF-8 text |
| `string(encoding)` | Text with fixed encoding (e.g. `"CP1251"`) |
| `string_with_encoding` | Per-value encoding tag |
| `bytes` | Binary data, variable-length |
| `bytes(n)` | Fixed-size binary |
| `bits` | Bitstring, variable-length |
| `bits(n)` | Fixed-size bitstring |
| `enum("v1", "v2", ...)` | Enum with named members (see §1.3) |
| `date`, `time`, `timestamp`, `timestamp_with_timezone`, `interval` | Temporal types (see §3) |
| `json` | JSON-compatible value (see §1.4) |
| `dynamic` | Any value, type-tagged at runtime (see §1.4) |
| `absent` | **Internal only.** Type for the `ABSENT` literal — represents absence of a value. Assignable only to `optional(T)`. Erased after typechecking. Not expressible in `.gdbsp` source syntax. |

All temporal types use microsecond precision internally and follow
proleptic Gregorian calendar conventions.

### 1.2 Wrapper Types

Wrappers add a layer of semantics around an inner type.

| Type | Meaning |
|------|---------|
| `optional(T)` | `T` or absent. The `ABSENT` literal has type `absent` and is assignable to any `optional(T)`. Collapses: `optional(optional(T))` → `optional(T)`. |
| `closure(() -> T)` | Opaque reference to a deterministic deferred computation. Takes positional and named parameters, returns type `T`. Equality is byte-identity. |
| `result_equivalent_closure(() -> T)` | Opaque reference to a deferred computation that may produce semantically equivalent yet non-identical results on each evaluation. Same structure as `closure` but without the byte-identity guarantee. |

**`optional(T)` semantics:**
- `optional(dynamic)` does NOT collapse to `dynamic` — `dynamic` does not accept `absent`.
- `optional(enum(S))` retains the wrapper — absence differs from an enum value.
- The `ABSENT` literal is resolved at compile time to the expected `optional(T)` type.

**`closure(...)` and `result_equivalent_closure(...)` structure:**

Parameters use the syntax `(pos_type, ..., "key": kw_type, ...)` inside the closure
type. Positional params are bare types written first; named params use quoted-string
keys and follow the positional params. Order of positional params matters; order of
named params does not. A closure with no parameters uses `closure(() -> T)` /
`result_equivalent_closure(() -> T)`.

Syntax (in type annotations, canonical text, and `.gdbsp` source declarations):
- `closure(() -> T)` — no parameters
- `closure((i64) -> f64)` — one positional parameter
- `closure((i64, "key": string) -> f64)` — mixed positional and named

In the internal representation (`gdbsp_column_type()`), positional params carry
`undefined` as the name; named params carry a `binary()` name.

### 1.3 Compound Types

| Type | Meaning |
|------|---------|
| `struct("f1": T1, ..., "fn": Tn)` | Named fields with individual types. Field names may be quoted (accepts arbitrary strings) or bare identifiers. |
| `array(T)` | Array with element type `T`, variable size |
| `array(T, N)` | Fixed-size array with element type `T` |
| `array(T, D1, D2, ...)` | Multi-dimensional array with element type `T` |
| `map(K, V)` | Key-value map with key type `K` and value type `V` |

Struct fields accept two spacing styles: `"key": type` (quoted, colon touches field name, space before type) and `key: type` (bare identifier, same spacing). The forms `key:type`, `key : type`, and `key :type` are invalid.

### 1.4 `json` and `dynamic`

**`json`** — A JSON-compatible value. Internally carries a concrete inner type tag (one of `string`, `f64`, `enum("false","true")`, `enum("null")`, `array(json)`, or `map(string,json)`). Not assignable from `absent` or `optional(T)` — use `optional(json)` for absence.

**`dynamic`** — Any value, carrying its concrete inner type at runtime. Not assignable from `absent` — use `optional(dynamic)` for absence. Widening: `T` → `dynamic` for any `T`.

---

## 2. Enum Type

Enums are structural types defined by a fixed set of symbol values. Symbols are interned, globally-unique named values.

### 2.1 Canonical Form

Enum values are alphabetically sorted, double-quoted, and escaped:

```
enum("blue", "green", "red")
```

Order does not matter in source — `enum("red","green")` and `enum("green","red")` denote the same type.

### 2.2 Subtyping

```
enum(S) is assignable to enum(T)  ⇔  S ⊆ T
```

Examples:
- `enum("true")` → `enum("false", "true")` ✓
- `enum("false", "true")` → `enum("true")` ✗

### 2.3 Widening

```
widen(enum(S), enum(T)) = enum(S ∪ T)
```

### 2.4 Comparison

Enum values support equality (`=`) and inequality (`!=`) only. No ordering. Identity comparison — two enum values are equal if they are the same symbol. Comparing values from disjoint enum value sets at compile time is an error.

### 2.5 Canonical Alias

`enum("null")` is NOT an alias for JSON null. It is a standalone symbol that happens to be named `"null"`. The JSON `null` literal is treated separately (see §6.1).

---

## 3. Temporal Types

### 3.1 Internal Representation

All temporal types use microsecond precision internally with `i64` storage:

| Type | Internal repr | Range |
|------|--------------|-------|
| `date` | `{year, month, day}` | year: any `i64`, month: 1–12, day: 1–31 |
| `time` | `{hour, minute, second, microsecond}` | hour: 0–23, minute: 0–59, second: 0–59, microsecond: 0–999999 |
| `timestamp` | microseconds since 2000-01-01 00:00:00 UTC | any `i64` |
| `timestamp_with_timezone` | `{epoch_microseconds, offset_seconds, zone?}` | `epoch_microseconds`: any `i64`, `offset_seconds`: -43200..50400, `zone`: optional IANA name |
| `interval` | `{months, days, microseconds}` | each component: any `i64` |

### 3.2 Special Values

`timestamp`, `timestamp_with_timezone`, and `date` support:
- `infinity` — later than all finite values
- `-infinity` — earlier than all finite values
- `epoch` — 1970-01-01 00:00:00 UTC

### 3.3 Construction

Positions are **not inferred** — all temporal constructors use named parameters:

```
date(year: i64, month: i64, day: i64)           → date
time(hour: i64, minute: i64, second: i64,
     microsecond: i64)                            → time
timestamp(microseconds_since_2000: i64)           → timestamp
timestamp(date: date, time: time)                 → timestamp (combined)
timestamp_with_timezone(microseconds_since_2000: i64,
                        offset_seconds: i64,
                        zone: optional(string))   → timestamp_with_timezone
timestamp_with_timezone(date: date, time: time,
                        zone: optional(string))   → timestamp_with_timezone
interval(months: i64, days: i64,
         microseconds: i64)                       → interval
```

Progressive component construction is supported: if `microsecond` is omitted, it defaults to 0.

### 3.4 Interval Arithmetic

The interval type uses three independent components: `months`, `days`, and `microseconds`. Each component is a signed `i64`. Operations fold components after computation using per-target consumption rules:

| Target | Months | Days | Microseconds |
|--------|--------|------|-------------|
| `timestamp` | Convert to days (30 days/month) | Add directly | Add directly |
| `date` | Add directly | Add directly | Ignored |
| `time` | Ignored | Ignored | Add directly |

### 3.5 Subtraction

| LHS | RHS | Result |
|-----|-----|--------|
| `date` | `date` | `interval` (days only) |
| `timestamp` | `timestamp` | `interval` (microseconds only) |
| `timestamp_with_timezone` | `timestamp_with_timezone` | `interval` (microseconds only) |
| `date` | `interval` | `date` |
| `timestamp` | `interval` | `timestamp` |
| `time` | `interval` | `time` |

### 3.6 Conversions

Temporal types allow implicit conversions following physical meaning:

| Source | Target | Rule |
|--------|--------|------|
| `timestamp` | `date` | Extract date component |
| `timestamp` | `time` | Extract time-of-day component |
| `timestamp` | `timestamp_with_timezone` | Treat as UTC (offset=0) |
| `date` | `timestamp` | Midnight of that date (UTC) |

### 3.7 Comparison

- `timestamp_with_timezone` comparisons are made at UTC instant
- Comparison across different temporal types is NOT allowed (use explicit constructors)
- Special values follow PostgreSQL conventions: `-infinity < finite values < infinity`

---

## 4. Numeric Widening

### 4.1 Integer Widening

Signed chain (widening is transitive):

```
i8 → i16 → i32 → i64 → integer → numeric
```

Unsigned chain:

```
u8 → u16 → u32 → u64 → integer → numeric
```

### 4.2 Cross-Signed/Unsigned Assignability

| Source | Target | Assignable? |
|--------|--------|-------------|
| `i8` | `u8` | No — requires explicit conversion |
| `i16` | `u8` | No |
| `u8` | `i16` | Yes — `u8` range is a subset of `i16` |
| `u16` | `i32` | Yes |
| `u32` | `i64` | Yes |
| `i64` | `u64` | No |
| `u64` | `i64` | No |
| `i8` | `integer` | Yes |
| `u8` | `integer` | Yes |

### 4.3 Integer → Float → Numeric

```
integer → f64 (may lose precision)
f32   → f64
integer → numeric
numeric(p,s) → numeric
f64 → numeric is NOT allowed
```

### 4.4 Untyped Literals

Untyped integer literals resolve to the smallest type that fits the value from `{i8, i16, i32, i64, u8, u16, u32, u64, integer}`. Untyped float literals resolve to `f64`. These are resolved at compile time based on the expected type from context (column type, operator signature, function parameter).

---

## 5. Type Collapsing

Redundant nesting is eliminated at type construction time:

```
optional(optional(T))                  →  optional(T)
string("UTF-8")                        →  string
optional(closure(P1, closure(P2, T)))  →  optional(closure(P1 ++ P2, T))
closure(P1, closure(P2, T))            →  closure(P1 ++ P2, T)
```

Positional params are concatenated in order. Named params are merged by name;
if the same name appears with different types the collapse is an error.

`optional(dynamic)` does NOT collapse to `dynamic`.

---

## 6. Assignability

A value of source type `S` is assignable to a position expecting target type `T`
(notation: `S → T`) if one of the rules below applies. These rules govern
what values can flow into operator inputs, function parameters, and stream
type positions.

### 6.1 Identity and Top

| Source | Target | Rule |
|--------|--------|------|
| `T` | `T` | Identity — every type is assignable to itself |
| any `T` | `dynamic` | Top type — any value can be treated as dynamic |

### 6.2 Scalar Widening

Follows the chains and cross-signed tables in §4.

### 6.3 `optional(T)`

| Source | Target | Assignable? |
|--------|--------|-------------|
| `T` | `optional(T)` | Yes — concrete value into optional (wrapping) |
| `S` | `optional(U)` if `S → U` | Yes — wider optional destination |
| `absent` | `optional(T)` | Yes — ABSENT is always a valid optional value |
| `optional(T)` | `T` | No — needs explicit unwrap (drops rows where value is absent) |

### 6.4 `closure`

| Source | Target | Assignable? |
|--------|--------|-------------|
| `closure(P, T)` | `closure(P, T)` | Yes — exact match (positional params in order, named params by name, return type exact) |
| `closure(P, T)` | `closure(Q, T)` if params match exactly | Yes — param-invariant, return type must be identical |
| `closure(P, T)` | `result_equivalent_closure(P, T)` | Yes — deterministic is a subset of possibly-non-deterministic |
| `result_equivalent_closure(P, T)` | `closure(P, T)` | No |
| `closure` / `rec_closure` | `dynamic` | Yes |
| `closure` / `rec_closure` | `json` | No |

### 6.5 Enum

| Source | Target | Assignable? |
|--------|--------|-------------|
| `enum(S)` | `enum(T)` | `S ⊆ T` |
| `enum(S)` | `json` | `S ⊆ {"false","true","null"}` |
| `enum("null")` | `json` | No — `null` is not the JSON null literal |
| `optional(enum(S))` | `json` | No — optional wrapper is not a JSON value |

### 6.6 `json`

| Source | Target | Assignable? |
|--------|--------|-------------|
| `string` | `json` | Yes |
| `f64` | `json` | Yes |
| `enum("false","true")` | `json` | Yes |
| `enum("null")` | `json` | Yes |
| `array(json)` | `json` | Yes |
| `map(string,json)` | `json` | Yes |
| `absent` | `json` | No — use `optional(json)` for absence |
| `optional(T)` (where `T → json`) | `json` | No — optional wrapper is not a JSON value |

### 6.7 Compound Types

**Array (covariant):**
- `array(A)` → `array(B)` if `A → B`
- `array(A, N)` → `array(B)` if `A → B` (dropping size constraint)
- `array(A, D1, D2, ...)` → `array(B)` if `A → B`

**Map (covariant in both params):**
- `map(K1, V1)` → `map(K2, V2)` if `K1 → K2` and `V1 → V2`

**Struct (covariant, field-name-exact):**
- `struct(F1...)` → `struct(F2...)` if same field names, each field individually assignable. Order-irrelevant. No extra or missing fields.

### 6.8 Temporal

No cross-type assignability between different temporal types. Use explicit constructors (see §3.3) for conversions.

### 6.9 String Isolation

The three string types are fully isolated — no cross-family assignability:

- `string` / `string("X")` — not assignable to `string_with_encoding`
- `string_with_encoding` — not assignable to `string` or `string("X")`
- `string("A")` → `string("B")` only if `A = B`

Explicit conversion functions are required to move between string type families.

### 6.10 Map-Key Restrictions

Map key types must not contain types that lack equality semantics. At type construction time, the following are rejected as map keys (including transitively through compound types):

- `dynamic` — no fixed equality
- `json` — map key semantics are implementation-defined
- `closure` / `result_equivalent_closure` — opaque references without value equality
- `optional(T)` — ABSENT in a key would break map semantics
- `f32` / `f64` — IEEE 754 NaN breaks equality

---

## 7. Type Variables

Function and aggregate function declarations may use uppercase identifiers
as type variables (e.g. `T`, `K`, `V`, `A1`). A type variable is a bare
uppercase-letter identifier optionally followed by digits:

```
count :: aggregate_function((T) -> i64)
```

### 7.1 Scoping

Type variables are scoped per declaration. Each function or aggregate
declaration introduces fresh type variables. The same name `T` in two
different declarations refers to unrelated variables.

### 7.2 Unification

Type variables are resolved by unification at each call site:

- **Concrete + type variable** → variable substituted with the concrete type
- **Type variable + type variable** → both unified (one variable class)
- After inference, all type variables must be resolved to concrete types
- Unresolved type variables are an error

### 7.3 Restrictions

- Type variables cannot appear in source node type annotations — only in function and aggregate declarations
- A type variable can appear multiple times in a single declaration — this constrains all occurrences to unify to the same concrete type

---

## 8. Canonical Text Form

Every type has a deterministic single-line text representation. This form is used for type identity, comparison, and hashing. The canonical form follows these rules:

| Type node | Canonical text |
|-----------|---------------|
| scalar | bare name: `i64`, `f32`, `string`, `json`, `dynamic`, `date`, ... |
| `numeric(p,s)` | `numeric(10,2)` |
| `bytes(n)` | `bytes(32)` |
| `bits(n)` | `bits(64)` |
| `string(e)` | `string("CP1251")` |
| `enum("v1",...)` | `enum("v1","v2")` — values sorted alphabetically |
| `optional(T)` | `optional(<T>)` |
| `closure((...) -> T)` | `closure((i64,"k":string)->f64)` — positional params bare, named as `"key":type` |
| `result_equivalent_closure(P, T)` | `result_equivalent_closure((<params>) -> <T>)` |
| `struct("f1": T1, ...)` | `struct("f1":<T1>,"f2":<T2>)` — fields sorted alphabetically |
| `array(T)` | `array(<T>)` |
| `array(T, N)` | `array(<T>,10)` |
| `array(T, D1, D2)` | `array(<T>,10,10)` |
| `map(K, V)` | `map(<K>,<V>)` |

Conventions:
- Single-line, no extraneous spaces except those required by grammar tokens
- Field names always double-quoted in canonical form
- All temporal types use their bare names (`date`, not `temporal:date`)

---

## 9. Type Hashing

A type hash is derived from the canonical text form:

```
hash(type) = MD5(canonical_text(type))
```

The pipeline is: parse → validate → collapse → canonical text → hash.

This enables content-addressed type identity — two structurally equivalent types produce the same hash regardless of syntactic origin.

---

## 10. ABSENT vs JSON `null`

Three distinct concepts coexist in the type system:

| Concept | Type | Meaning |
|---------|------|---------|
| ABSENT (absence) | `absent` (internal) → `optional(T)` | No value present |
| JSON null | `enum("null")` | A value that is the JSON null literal |
| JSON value | `json` (with concrete inner type) | An actual JSON value |

Key distinctions:

1. **Non-optional `json` column** — wire `null` can only mean JSON null (absence is not assignable to `json`).

2. **`optional(json)` column** — distinguishes three states:
   - `absent` = ABSENT (no value)
   - `{value, null}` = JSON null (the value null)
   - `{value, {"key": ...}}` = JSON object (an actual value)

3. **`optional(T)` where T ≠ json** — only two states:
   - `absent` = ABSENT
   - `T` value = present

4. **Wire encoding for `optional(json)`** — the `"value"` wrapper distinguishes absence from JSON null:
   - `null` (wire) → ABSENT (absence)
   - `{"value": null}` → JSON null (the value)
   - `{"value": ...}` → JSON value

---

## 11. JSON Type Representation

When types appear in JSON (e.g., in schema storage, function registries, or value tags), they follow a single rule: either a **short string** for parameterless types, or an **object with a single key** for parameterized types.

### 11.1 Short Strings

```
"i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "integer"
"f32", "f64", "numeric"
"string", "string_with_encoding"
"bytes", "bits"
"date", "time", "timestamp", "timestamp_with_timezone", "interval"
"json", "dynamic"
```

### 11.2 Parameterized Types

```json
{"numeric": {"precision": 10, "scale": 2}}
{"bytes": {"size": 32}}
{"bits": {"size": 64}}
{"string": {"encoding": "CP1251"}}
```

### 11.3 Wrappers

```json
{"optional": "i64"}
{"optional": {"array": "f64"}}
{"closure": {"return": "bytes"}}
{"closure": {"params": {"p1": "i64"}, "return": "string"}}
{"closure": {"positional": ["i64"], "params": {"k": "string"}, "return": "f64"}}
{"result_equivalent_closure": {"params": {"k": "i64"}, "return": "f64"}}
```

### 11.4 Compounds

```json
{"array": "i64"}
{"array": {"element": "i64", "size": 10}}
{"array": {"element": "i64", "shape": [10, 10]}}
{"map": {"key": "string", "value": "i64"}}
{"struct": {"name": "string", "age": "i64"}}
```

### 11.5 Enum

```json
{"enum": ["red", "green", "blue"]}
{"enum": ["false", "true"]}
{"enum": ["null"]}
```

---

## 12. Type Validation

When constructing types from JSON or other non-source representations, the following are rejected:

- Unknown type name (not in the scalar catalog)
- Unknown keys in a type object (e.g. `{"numeric": {"precision": 10, "foo": 1}}`)
- Missing required parameters (`{"numeric": {}}` — missing both `precision` and `scale`)
- Conflicting parameter forms (`{"array": {"element": "i64", "size": 10, "shape": [2]}}`)
- Duplicate struct field names
- `scale > precision` in `numeric(p,s)`
- Negative size parameters (`bytes(-1)`)
- Non-integer numeric parameters (e.g. `bytes("10")`)
- Non-string keys in struct fields
- Empty enum value list
- Non-string enum values
