# Grasp DBSP — Type Inference

Date: 2026-07-29
Status: draft

---

## 1. Overview

Type inference determines the output type of every node in a `.gdbsp`
circuit. It runs after parsing, before compilation. The result is a
mapping from each node name to its concrete type, used by the compiler
to allocate operators and by the runtime to validate input data.

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
| `map` | Output type of the function (inferred from the function registry) |
| `filter` | Same as input schema (filter does not change columns) |
| `flat_map` | Input columns plus any new columns produced by the flat-mapped expansion |
| `project` | Subset of input schema: only the listed field names |
| `plus` | Same as first input (with assignability check across all inputs) |
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
- Key fields (`on:`) must exist on both left and right sides with compatible types
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
| `agg:sum` | `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `integer` | `i64` | Integer sum narrows to `i64` |
| `agg:sum` | `f32`, `f64` | `f64` | Float sum widens to `f64` |
| `agg:sum` | `numeric` | `numeric` | Numeric sum preserves type |
| `agg:count` | any | `i64` | Always `i64` |
| `agg:avg` | `integer`, `f32`, `f64` | `f64` | Integer/float average → `f64` |
| `agg:avg` | `numeric` | `numeric` | Numeric average preserves type |
| `agg:min` | `T` | `T` | Preserves input type exactly |
| `agg:max` | `T` | `T` | Preserves input type exactly |
| `agg:first` | `T` | `T` | Preserves input type exactly |
| `agg:last` | `T` | `T` | Preserves input type exactly |

---

## 6. Function Return Type Inference

For `map` and `filter` operators, the return type is inferred from the
function definition in the function registry:

- **Struct construction** (`{"call": "struct", "kwargs": {...}}`): output type is a struct with fields matching the kwargs, each typed by its expression
- **Field reference** (`{"field": "col"}`): output type is the column's type from the input schema
- **Comparison functions** (`gte`, `lt`, `eq`, etc.): output type is `enum("false", "true")`
- **Scalar functions** (`string:upper`, `integer:add`, etc.): output type follows the function's declared return type

---

## 7. Error Conditions

### 7.1 Missing Typespec

A `source` node without a corresponding `stream(...)` annotation:

```
Error: missing_typespec on node <name>
```

### 7.2 Type Mismatch

When a node's input type is not assignable to what an operator expects:

```
Error: type mismatch at node <name>
```

### 7.3 Unresolved Type Variable

When a function or aggregate uses a type variable that cannot be resolved
to a concrete type from the call-site context:

```
Error: unresolved type variable <Var> in node <name>
```
