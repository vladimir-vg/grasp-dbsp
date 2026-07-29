# Grasp DBSP

A minimal, flat intermediate representation for Database Stream Processor (DBSP) circuits.
Designed as a compilation target — human-readable, LLM-friendly, with external function references.

## Companion documents

- [type-system.md](type-system.md) — complete type system: scalars, compounds, wrappers, assignability, temporal semantics
- [type-inference.md](type-inference.md) — how types flow through the circuit
- [compilation.md](compilation.md) — how `.gdbsp` source compiles to a deployable circuit
- [runtime-model.md](runtime-model.md) — Z-set model, epochs, deltas, barriers, operator state
- [stdlib.md](stdlib.md) — function and aggregate registry, expression JSON format, value encoding

## File structure

A `.gdbsp` file contains interleaved declarations in any order. A declaration may
repeat identically (no-op); a conflicting repeat is an error.

- Node definitions: `name := operator(args...)`
- Type annotations: `name :: stream(type)` (mandatory for all source nodes)
- Function declarations: `fn :: function((params) -> ret)`
- Aggregate function declarations: `fn :: aggregate_function((val) -> ret)`
- Comments: `# text`

Column names in keyword arguments are quoted strings. Node names and function
names are bare identifiers.

There are no output nodes in source code. The runtime selects which nodes serve
as outputs externally — the same `.gdbsp` source can be used with different
output selections.

Forward references are allowed. The parser resolves all node names after reading
the entire file.

### Multiline node definitions

Nodes may span multiple lines. The opening `(` may be followed by a newline,
with arguments on subsequent lines, and the closing `)` on the same line as the
last argument or on its own line:

```
merged := plus(
  a,
  b,
  c
)
```

Continuation lines must not start with `#`, must not contain `::` or `:=`,
must not be empty, and must not be a bare `)`. Trailing commas on the last
argument line are optional.

## Types

Types are used in `stream(...)` annotations, function signatures, and
aggregate signatures. The [type-system.md](type-system.md) document defines
every type in full detail.

### Quick reference

Scalar types: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`,
`integer`, `f32`, `f64`, `numeric`, `numeric(p,s)`, `string("enc")`,
`string_with_encoding`, `bytes`, `bytes(n)`, `bits`, `bits(n)`,
`enum("v1", "v2", ...)`, `date`, `time`, `timestamp`,
`timestamp_with_timezone`, `interval`, `json`, `dynamic`.

Wrapper types: `optional(T)`, `closure(P, T)`, `result_equivalent_closure(P, T)`.

Compound types: `struct("f1": T1, ...)`, `array(T)`, `array(T, n)`,
`array(T, d1, d2, ...)`, `map(K, V)`.

Type variables: uppercase identifiers (`T`, `K`, `V`, `A1`) in function and
aggregate signatures, resolved by unification at the call site (see
[type-system.md](type-system.md) §7).

### Stream wrapper

All source nodes require a `stream(...)` wrapper:

```
src :: stream(struct("col1": i64, "col2": string("UTF-8")))
```

The inner type of the wrapper is the stream element type. For sources,
this must be a `struct`.

See [type-inference.md](type-inference.md) for how types propagate
through the circuit.

## Operator reference

### Minimal set (11 primitives)

| # | Operator | Args | Semantics |
|---|----------|------|-----------|
| 1 | `source` | `"table"` | Circuit entry point. Mandatory type annotation with `stream(...)` wrapper. |
| 2 | `delay` | `node` | z⁻¹ — one-step delay. Breaks feedback cycles. |
| 3 | `integrate` | `node` | **I** — accumulate deltas into a Z-set. Stateful. |
| 4 | `differentiate` | `node` | **D** — compute delta of accumulated state. |
| 5 | `distinct` | `node` | Collapse opposite-weight pairs within a batch. |
| 6 | `plus` | `node, node, ...` | Merge N streams by summing weights of identical rows. |
| 7 | `neg` | `node` | Invert weight sign (+1 ↔ −1). |
| 8 | `map` | `node, fn` | 1→1 row transform via external function. |
| 9 | `flat_map` | `node, fn` | 1→N row expansion. Function returns `array(row)`. |
| 10 | `join` | `left, right, on: ["f1", ...]` | Equi-join. Key fields must have the same name on both sides. Non-key fields are merged flat into the output. |
| 11 | `aggregate` | `node, fn, by: ["g1", ...], value: "v", as: "r"` | Group by `by` fields, fold `value` field via `fn`, name result `as` in output. |

### Extended set

| # | Operator | Args | Notes |
|---|----------|------|-------|
| 12 | `filter` | `node, fn` | Reduces to `flat_map` with {0,1}-output function. Has dedicated runtime impl. |
| 13 | `project` | `node, ["f1", ...]` | Drops all fields except listed ones. Reduces to `map`. |
| 14 | `antijoin` | `left, right, on: ["f1", ...]` | Left rows with no right-side match. Same field-naming convention as `join`. Composite runtime impl. |
| 15 | `non_struct_join` | — | Underspecified. Reserved for future non-struct stream joins. |

### Conventions

**Join:** inputs must be structs. `on:` fields must exist on both sides with compatible types. Non-key fields are merged flat; duplicate non-key field names is an error. Key fields appear once in the output with the type from the left side. Disambiguate field names via `map` before the join.

**Aggregate:** input must be a struct. `by:` fields are preserved in the output. `value:` is consumed by the aggregate and replaced by `as:` in the output schema. All other input fields are dropped.

**Incrementalization:** the compiler inserts `integrate` / `differentiate` pairs around non-linear operators (join, distinct, aggregate, antijoin). Linears (map, filter, flat_map, neg, plus, delay, project) pass through unchanged. See [compilation.md](compilation.md) §5 for details.

**Feedback:** cyclic graphs use `delay` to break cycles. The `delay` must appear on the feedback edge. See [runtime-model.md](runtime-model.md) §4 for delay semantics.

## Function declarations

Functions are declared at top level and referenced by bare identifier in
operator arguments. Function bodies are provided externally as JSON expression
trees (see [stdlib.md](stdlib.md) §1).

### Function

```
fn_name :: function((param_types...) -> return_type)
```

Used with `map`, `filter`, `flat_map`. The function operates on a single row
element (without weight). The operator handles weight propagation automatically.

Zero-parameter functions use empty parentheses:

```
fn_name :: function(() -> return_type)
```

| Operator | Function signature | Description |
|----------|-------------------|-------------|
| `map` | `(row_type) -> new_row_type` | Transform one row |
| `filter` | `(row_type) -> enum("false", "true")` | Keep or discard |
| `flat_map` | `(row_type) -> array(new_row_type)` | Expand 0..N rows |

Type variables are allowed in place of concrete types; they are resolved by
unification at each call site (see [type-system.md](type-system.md) §7).

Examples:

```
passthrough :: function((struct("from": i64, "to": i64)) -> struct("from": i64, "to": i64))
salary_ge_150 :: function((struct("name": string("UTF-8"), "dept": i64, "sal": i64)) -> enum("false", "true"))
expand_items :: function((struct("id": i64, "items": array(string("UTF-8")))) -> array(struct("id": i64, "item": string("UTF-8"))))
```

### Aggregate function

```
fn_name :: aggregate_function((value_type) -> result_type)
```

Used with `aggregate`. The `value_type` is the type of the `value:` field in the
aggregate input struct. The runtime resolves the declared name to a built-in
aggregate via the function registry (see [stdlib.md](stdlib.md) §4.2).

Examples:

```
sum_sal :: aggregate_function((i64) -> i64)
count :: aggregate_function((T) -> i64)
```

## Examples

### Transitive closure

Rules: `path(x,z) :- edge(x,z)` and `path(x,z) :- edge(x,y), path(y,z)`.

```
edge_src := source("edge")
edge_src :: stream(struct("from": i64, "to": i64))

rename_from_to :: function((struct("from": i64, "to": i64)) -> struct("from": i64, "z": i64))
rename_edge_for_join :: function((struct("from": i64, "to": i64)) -> struct("joinkey": i64, "from": i64))
rename_path_for_join :: function((struct("from": i64, "z": i64)) -> struct("joinkey": i64, "z": i64))

# Rule 1: path(x,z) :- edge(x,z)
path_base := map(edge_src, rename_from_to)

# Rule 2: path(x,z) :- edge(x,y), path(y,z)
path_delayed := delay(path_merged)
edge_ready := map(edge_src, rename_edge_for_join)
path_ready := map(path_delayed, rename_path_for_join)
joined := join(edge_ready, path_ready, on: ["joinkey"])
joined_proj := project(joined, ["from", "z"])

# Merge rules, deduplicate
path_merged := plus(path_base, joined_proj)
path_deduped := distinct(path_merged)

# Incrementalization
path_state := integrate(path_deduped)
path_deltas := differentiate(path_state)
```

### Aggregate

```
emp_src := source("emp")
emp_src :: stream(struct("name": string("UTF-8"), "dept": i64, "year": i64, "sal": i64))

salary_ge_150 :: function((struct("name": string("UTF-8"), "dept": i64, "year": i64, "sal": i64)) -> enum("false", "true"))
sum_sal :: aggregate_function((i64) -> i64)

high_paid := filter(emp_src, salary_ge_150)
payroll_agg := aggregate(high_paid, sum_sal, by: ["dept", "year"], value: "sal", as: "total")
payroll := project(payroll_agg, ["dept", "year", "total"])
```

### Antijoin (stratified negation)

```
term_src := source("terminated")
term_src :: stream(struct("name": string("UTF-8")))

live_emps := antijoin(high_paid, term_src, on: ["name"])
```

### Feedback with multiple recursion levels

```
a_src := source("a")
a_src :: stream(struct("id": i64, "parent": i64))

key_child :: function((struct("id": i64, "parent": i64)) -> struct("key": i64, "child": struct("id": i64)))
key_parent :: function((struct("anc": i64, "desc": i64)) -> struct("key": i64, "desc": struct("desc": i64)))
unwrap :: function((struct("key": i64, "child": struct("id": i64), "desc": struct("desc": i64))) -> struct("anc": i64, "desc": i64))

anc_base := map(a_src, rename_to_anc_desc)

anc_delayed := delay(anc_merged)
child_side := map(a_src, key_child)
parent_side := map(anc_delayed, key_parent)
joined := join(child_side, parent_side, on: ["key"])
joined_proj := map(joined, unwrap)

anc_merged := plus(anc_base, joined_proj)
anc_deduped := distinct(anc_merged)
anc_state := integrate(anc_deduped)
anc_deltas := differentiate(anc_state)
```

## Grammar

```
file       := (node_def | type_ann | fn_decl | agg_decl | comment)*

node_def   := NAME ":=" OPERATOR "(" args? ")" NEWLINE
            | NAME ":=" OPERATOR "(" NEWLINE arg ("," arg)* ","? NEWLINE ")"

type_ann   := NAME "::" "stream" "(" type ")" NEWLINE

fn_decl    := NAME "::" "function" "(" "(" params? ")" "->" type ")" NEWLINE

agg_decl   := NAME "::" "aggregate_function" "(" "(" param ")" "->" type ")" NEWLINE

args       := arg ("," arg)*
arg        := NAME | STRING | kw_arg
kw_arg     := NAME ":" "[" STRING ("," STRING)* "]"
            | NAME ":" STRING

params     := type ("," type)*
param      := type

type       := scalar
            | "stream" "(" type ")"
            | "struct" "(" field_types ")"
            | "array" "(" type ")"
            | "array" "(" type "," INTEGER ("," INTEGER)* ")"
            | "map" "(" type "," type ")"
            | "optional" "(" type ")"
            | "closure" "(" "(" params? ")" "->" type ")"
            | "result_equivalent_closure" "(" "(" params? ")" "->" type ")"
            | NAME            -- type variable (uppercase first letter)

scalar     := "i8" | "i16" | "i32" | "i64" | "u8" | "u16" | "u32" | "u64"
            | "integer" | "f32" | "f64" | "numeric" | "numeric" "(" INTEGER "," INTEGER ")"
            | "string" "(" STRING ")" | "string_with_encoding"
            | "bytes" | "bytes" "(" INTEGER ")" | "bits" | "bits" "(" INTEGER ")"
            | "enum" "(" STRING ("," STRING)* ")"
            | "date" | "time" | "timestamp" | "timestamp_with_timezone" | "interval"
            | "json" | "dynamic"

field_types := field_type ("," field_type)*
field_type  := (NAME | STRING) ":" type

comment    := "#" .* NEWLINE
```

## Naming conventions

- Node names, function names: `[a-zA-Z_][a-zA-Z0-9_]*`
- Column names (in keyword args): arbitrary double-quoted strings
- Operator names: as listed in the reference above
