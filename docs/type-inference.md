# Grasp DBSP — Type Inference

Date: 2026-08-23
Status: current

---

## 1. Overview

Type inference determines the output type of every node in a `.gdbsp`
circuit. It runs **after lowering** (content-addressed deduplication
and fixpoint expansion), before circuit-graph construction. The result
is stored in each lowered node and carried forward to the circuit graph,
used by the compiler to allocate operators and by the runtime to
validate input data.

Function-level type checking for inline function bodies runs as a pre-pass
before lowering — it verifies that each function body's return type matches
its declared typespec. After this pre-pass, all function bodies are available
as JSON expression trees in the merged function registry, and stream-level
inference proceeds as described below.

Type inference uses **exact type equality** via canonical text
comparison. Assignability and widening (see
[type-system.md](type-system.md) §6) are applied only at runtime during
function expression resolution, not during inference.

---

## 2. Source Node Typing

Every `source` node must have a corresponding type annotation:

```
src := source("table_name")
src :: stream(struct("col1": T1, "col2": T2))
```

The `stream(struct(...))` declaration is **mandatory** for all source
nodes. A source node without a type annotation is an error:
`missing_typespec`.

The inner type of the `stream(...)` wrapper becomes the stream element
type. For sources, this must be a `struct` — the struct's fields define
the output schema of the source node.

---

## 3. Schema Propagation

Each operator computes its output schema (column names and types) from
its input schemas. The propagation rules:

### 3.1 Propagation Table

| Operator | Output Schema |
|----------|-------------|
| `source` | Struct fields from the `stream(struct(...))` declaration |
| `map` | Output type of the function (inferred from the function registry). `{"arg": "row"}` passes through the input struct type. |
| `filter` | Same as input schema (filter does not change columns) |
| `flat_map` | Element type of the `array(new_row_type)` returned by the function |
| `project` | Subset of input schema: only the listed field names |
| `plus` | Same as inputs (exact type match required across all inputs) |
| `neg` | Same as input schema |
| `delay` | Same as input schema |
| `integrate` | Same as input schema |
| `differentiate` | Same as input schema |
| `distinct` | Same as input schema |
| `join` | `on_fields ++ left_extra_fields ++ right_extra_fields` — key fields from left side, non-key fields merged from both sides |
| `aggregate` | `by_fields ++ [result_field_name]` — group-by fields preserved, value field replaced by aggregate result |
| `antijoin` | Same as left input schema |

### 3.2 Join Schema Details

For `join(left, right, on: ["k1", "k2"])`:
- Key fields (`on:`) must exist on both left and right sides with exactly equal types
- Key fields appear once in the output, with the type from the left side
- All non-key fields from both sides are merged flat into the output
- Duplicate non-key field names across sides is an error

### 3.3 Aggregate Schema Details

For `aggregate(input, fn, by: ["g1", "g2"], value: "v", as: "result")`:
- `by:` fields are preserved in the output with their input types
- The `value:` field is consumed by the aggregate function and does NOT appear in the output
- The `as:` field replaces `value:` in the output schema, with the aggregate's return type
- All other input fields are dropped

### 3.4 Project Schema Details

For `project(input, ["f1", "f2"])`:
- Output contains only the listed fields, in the order listed
- Fields must exist in the input schema

---

## 4. Type Variable Unification

Function and aggregate declarations may use type variables (uppercase
identifiers). See [type-system.md](type-system.md) §7 for the definition
of type variables.

### 4.1 Resolution

At each call site, type variables are resolved by unification with the
concrete types from the operator's input schema:

- **Concrete type + type variable** → variable is substituted with the concrete type
- **Type variable + type variable** → both are unified into a single variable class
- After inference, all type variables must be resolved to concrete types
- An unresolved type variable after inference is an error

### 4.2 Example

```
count :: aggregate_function((T) -> i64)
```

When `count` is used as the aggregate function for an input with value
type `i64`:

1. The call supplies `T = i64` (the type of the `value:` field)
2. The system unifies `T` with `i64`
3. The aggregate's argument type is resolved to `i64`
4. The return type is `i64`

The type variable `T` allows the same `count` declaration to work with
any value type — it doesn't depend on the concrete type of the value
being counted.

### 4.3 Constraints

- A type variable appearing multiple times in a single declaration constrains all occurrences to unify to the same concrete type
- Type variables cannot appear in source node type annotations (`:: stream(...)`) — only in function and aggregate declarations

---

## 5. Aggregate Return Type Inference

Aggregate functions have specific return type rules. When an aggregate
is used, the return type is inferred from the input value type.

### 5.1 Built-in Aggregate Return Types

| Aggregate | Input Type | Return Type | Rule |
|-----------|-----------|-------------|------|
| `std.agg_sum_i64` | `i64` | `i64` | Sum over i64 |
| `std.agg_sum_numeric` | `numeric` | `numeric` | Sum over numeric |
| `std.agg_sum_f64` | `f64` | `f64` | Sum over f64 |
| `std.agg_count` | any | `i64` | Always `i64` |
| `std.agg_avg_i64` | `i64` | `f64` | Integer average → `f64` |
| `std.agg_avg_numeric` | `numeric` | `numeric` | Numeric average preserved |
| `std.agg_avg_f64` | `f64` | `f64` | Float average → `f64` |
| `std.agg_min_i64` / `std.agg_min_numeric` / `std.agg_min_f64` | `i64` / `numeric` / `f64` | same as input | Minimum |
| `std.agg_max_i64` / `std.agg_max_numeric` / `std.agg_max_f64` | `i64` / `numeric` / `f64` | same as input | Maximum |

---

## 6. Expression Type Inference

A single expression-type engine (`gdbsp_type_infer_expr`) infers the
type of a function body for `map`, `filter`, and `flat_map`. It operates
on the internal `gdbsp_column_type()` representation (never JSON) and is
used both by inline function body checking (before lowering) and by
stream-level node output typing (after decoding the function registry's
JSON bodies via `gdbsp_expr:json_to_expr/1`).

- **Arg reference** (`{arg, N}`): the declared parameter type from the
  function's typespec.
- **Value literal** (`{value, T, _}`): the literal's type `T`.
- **Struct construction** (`{call, struct, _, KwArgs}`): a struct with one
  field per keyword argument, each typed by its expression.
- **`std.struct_get`** (`{call, std.struct_get, [S], #{key := K}}`): the
  key must be a compile-time string literal; the result is the field's
  type. A non-literal key is a `non_literal_key` error and a missing field
  is a `missing_field` error. Accessing a `dynamic` value yields `dynamic`.
- **`std.struct_set`** (`{call, std.struct_set, [S], #{key := K, value := V}}`):
  the key must be a string literal naming an existing field, and `V`'s
  type must exactly match that field's type. The result type is `S`
  unchanged (update-only). A non-literal key, a missing field, and a
  value-type mismatch are errors.
- **Subscript** (`{get, Obj, [Key]}`): on a struct the key must be a
  string literal (as `std.struct_get`). On an array the index need only be
  an integer type (result is the element type). On a map the key need only
  have the map's key type (result is the value type). Subscripting a
  `dynamic` value yields `dynamic`.
- **Slice** (`{slice, Obj, ...}`): `array(T)` → `array(T)`, `string` →
  `string`, `bytes` → `bytes`, `dynamic` → `dynamic`.
- **Comparison / arithmetic / other operators**: resolved through
  `gdbsp_builtins:resolve_call/4` against the stdlib typespecs; the output
  type is the resolved function's declared return type. An unresolvable
  call is an error (`fn_lookup_error`), never `dynamic`.
- **Unknown expression shapes** are errors, never a silent fallback to
  `dynamic` or to the input type.

`dynamic` is produced only by a declared `dynamic` type or by access into
an already-`dynamic` container.

---

## 7. Error Conditions

### 7.1 Missing Typespec

A `source` node without a corresponding `stream(...)` annotation, or an
operator referencing an undeclared function/aggregate:

```
Error: missing_typespec on node <name>
```

### 7.2 Type Conflict

When operator inputs have incompatible types that must be exactly equal:

- `plus` with input schemas that differ in field names or types
- `join` with key fields that have different types on left and right sides

```
Error: type_conflict: plus input type mismatch
Error: type_conflict: join key type mismatch on <key>
```

### 7.3 Unresolved Type Variable

When a function or aggregate uses a type variable that cannot be resolved
to a concrete type from the call-site context:

```
Error: unresolved type variable <Var> in node <name>
```

### 7.4 Non-literal / missing access keys

Struct field access (`std.struct_get`, `std.struct_set`, and struct
subscript) requires a compile-time string-literal key, because the result
type depends on which field is selected:

```
Error: non_literal_key — struct key must be a string literal
Error: missing_field  — field <name> not present in struct
```

Map and array access are different: they only require the key/index *type*
to match, not a literal value.
