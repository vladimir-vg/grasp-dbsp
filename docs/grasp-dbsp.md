# Grasp DBSP

A minimal, flat intermediate representation for Database Stream Processor (DBSP) circuits.
Designed as a compilation target — human-readable, LLM-friendly, with external function references.

## Companion documents

- [syntax.md](syntax.md) — complete lexical and syntactic specification
- [type-system.md](type-system.md) — complete type system: scalars, compounds, wrappers, assignability, temporal semantics
- [type-inference.md](type-inference.md) — how types flow through the circuit
- [compilation.md](compilation.md) — how `.gdbsp` source compiles to a deployable circuit
- [runtime-model.md](runtime-model.md) — Z-set model, epochs, deltas, barriers, operator state
- [stdlib.md](stdlib.md) — function and aggregate registry, expression JSON format, value encoding
- [circuits.md](circuits.md) — circuit definitions: named, parameterised subgraphs with macro expansion
- [fixpoint-circuits.md](fixpoint-circuits.md) — fixpoint instantiation: iterative convergence within a parent epoch
- [cli.md](cli.md) — the `gdbsp` command-line tool: subcommands, JSONL wire format, epoch ingress, HTTP API

## File structure

A `.gdbsp` file contains interleaved declarations in any order. A declaration may
repeat identically (no-op); a conflicting repeat is an error.

- Node definitions: `name := operator(args...)`
- Type annotations: `name :: stream(type)` (mandatory for all source nodes)
- Function declarations: `fn :: function((params) -> ret)`
- Function definitions: `fn := function((params) -> body_expr)`
- Aggregate function declarations: `fn :: aggregate_function((val) -> ret)`
- Circuit definitions: `circuit name(key: internal, ...): ...` (see [circuits.md](circuits.md))
- Fixpoint instantiation: `fp := fixpoint(name(key: expr, ...))` (see [fixpoint-circuits.md](fixpoint-circuits.md))
- Comments: `# text`

Column names in keyword arguments are quoted strings. Node names and function
names are bare identifiers.

There are no output nodes in source code. The runtime selects which nodes serve
as outputs externally — the same `.gdbsp` source can be used with different
output selections.

Forward references are allowed. The parser collects all declarations
before resolving names.

See [syntax.md](syntax.md) for the complete lexical and syntactic specification.

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
| 8 | `map` | `node, fn` | 1→1 row transform via a function. |
| 9 | `flat_map` | `node, fn` | 1→N row expansion. Function returns `array(row)`. |
| 10 | `join` | `left, right, on: ["f1", ...]` | Equi-join. Key fields must have the same name on both sides. Non-key fields are merged flat into the output. |
| 11 | `aggregate` | `node, fn, by: ["g1", ...]` | Group by `by` fields, fold each group via aggregate function `fn`, which returns a struct. `by` fields are added to the output. |

### Extended set

| # | Operator | Args | Notes |
|---|----------|------|-------|
| 12 | `filter` | `node, fn` | Reduces to `flat_map` with {0,1}-output function. Has dedicated runtime impl. |
| 13 | `project` | `node, ["f1", ...]` | Drops all fields except listed ones. Reduces to `map`. |
| 14 | `antijoin` | `left, right, on: ["f1", ...]` | Left rows with no right-side match. Same field-naming convention as `join`. Composite runtime impl. |
| 15 | `non_struct_join` | — | Underspecified. Reserved for future non-struct stream joins. |

### Conventions

**Join:** inputs must be structs. `on:` fields must exist on both sides with compatible types. Non-key fields are merged flat; duplicate non-key field names is an error. Key fields appear once in the output with the type from the left side. Disambiguate field names via `map` before the join.

**Aggregate:** input must be a struct. `fn` is an aggregate function (see below) that takes the whole row and returns a struct. `by:` fields are preserved from the input and prepended to the output struct. All other input fields are dropped. A `by:` field name must not appear in the returned struct (a name clash is a compile error).

**Incrementalization:** the compiler inserts `integrate` / `differentiate` pairs around non-linear operators (join, distinct, aggregate, antijoin). Linears (map, filter, flat_map, neg, plus, delay, project) pass through unchanged. See [compilation.md](compilation.md) §5 for details.

**Feedback:** cyclic graphs use `delay` to break cycles. The `delay` must appear on the feedback edge. See [runtime-model.md](runtime-model.md) §4 for delay semantics.

## Function declarations

Functions are declared at top level and referenced by bare identifier in
operator arguments.

### Typespec (required)

Every function must have a typespec declaring its parameter types and return
type:

```
fn_name :: function((pos_type, ..., "key": kw_type, ...) -> return_type)
```

Parameters may be positional (bare type names, order-sensitive) or keyword
(`"name": type`, order-insensitive). Positional params must come before keyword
params.

```
fn :: function((i64, "prefix": string) -> f64)
```

Zero-parameter functions use empty parentheses:

```
fn_name :: function(() -> return_type)
```

Type variables (uppercase identifiers like `T`, `V`, `K`) are allowed in
function and aggregate declarations and are resolved by unification at each
call site (see [type-system.md](type-system.md) §7).

### Body (optional)

A function body may be defined inline using the `:=` syntax:

```
fn_name := function((params) -> body_expr)
```

Params in the body definition are **untyped** — types come exclusively from
the typespec. Positional params precede keyword params:

```
add :: function((i64, i64) -> i64)
add := function((x, y) -> x + y)
```

Keyword params use the shorthand `name:` (key and variable have the same name)
or explicit `key: varname`:

```
set_flag :: function((i64, flag: boolean) -> i64)
set_flag := function((x, flag:) -> x + flag)
```

The body expression uses Grasp expression syntax — arithmetic, comparisons,
boolean logic, function calls, struct construction, array/map literals, dot
access, and subscripts. See [syntax.md](syntax.md) §6 for the full expression
grammar.

The typespec and definition may appear in any order. A typespec with no
matching `:= function(...)` definition is a signature-only declaration: it is
available for type inference of other function bodies but has no runtime body,
so it cannot be used as a `map` / `filter` / `flat_map` function.

Aggregate calls (`std.agg_*`, see below) are allowed only in aggregate-function
bodies, not in regular function bodies. Closure expressions (`closure(...)`)
are reserved for future work.

Inline function bodies currently require **exact (concrete) types** in the
typespec. Type-variable unification is implemented
(`gdbsp_builtins:unify_types/3`) and used for operator/overload resolution,
but it is not applied to inline function bodies.

### Usage

| Operator | Function signature | Description |
|----------|-------------------|-------------|
| `map` | `(row_type) -> new_row_type` | Transform one row |
| `filter` | `(row_type) -> enum("false", "true")` | Keep or discard |
| `flat_map` | `(row_type) -> array(new_row_type)` | Expand 0..N rows |

### Examples

Typespec-only (signature-only, no inline body):

```
passthrough :: function((struct("from": i64, "to": i64)) -> struct("from": i64, "to": i64))
salary_ge_150 :: function((struct("name": string("UTF-8"), "dept": i64, "sal": i64)) -> enum("false", "true"))
expand_items :: function((struct("id": i64, "items": array(string("UTF-8")))) -> array(struct("id": i64, "item": string("UTF-8"))))
```

With inline body:

```
rename_from_to :: function((struct("from": i64, "to": i64)) -> struct("from": i64, "z": i64))
rename_from_to := function((row) -> struct("from": row.from, "z": row.to))

is_positive :: function((i64) -> enum("false", "true"))
is_positive := function((x) -> x > 0)
```

### Aggregate function

```
fn_name :: aggregate_function((input_row_type) -> result_struct_type)
fn_name := function((row) -> result_struct_expr)
```

An aggregate function has an `aggregate_function` typespec and a
`:= function(...)` body, exactly like a regular function. The body takes the
whole input row and returns a **struct**. It is used with `aggregate`:

```
payroll :: aggregate_function((struct("dept": i64, "sal": i64)) -> struct("total": i64))
payroll := function((row) -> struct("total": std.agg_sum_i64(row.sal)))

total_by_dept := aggregate(emp, payroll, by: ["dept"])
```

The body may reference built-in aggregate primitives (`std.agg_*`, see
[stdlib.md](stdlib.md) §3.1). It must contain at least one aggregate call.
Aggregate calls cannot be nested, and the row parameter may only appear inside
an aggregate call's argument (`std.agg_sum_i64(row.sal)` is valid, but
`row.sal + std.agg_count()` is not).

The output struct type is the `by:` fields followed by the returned struct's
fields; a `by:` field name must not also appear in the returned struct.

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
sum_sal :: aggregate_function((struct("name": string("UTF-8"), "dept": i64, "year": i64, "sal": i64)) -> struct("total": i64))
sum_sal := function((row) -> struct("total": std.agg_sum_i64(row.sal)))

high_paid := filter(emp_src, salary_ge_150)
payroll := aggregate(high_paid, sum_sal, by: ["dept", "year"])
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

See [syntax.md](syntax.md) for the complete lexical and syntactic specification.

```
program    := declaration*

declaration := node_def | typespec | fn_def | circuit_def | comment

node_def   := NAME ":=" op_name "(" args? ")"
            | NAME ":=" circuit_name "(" kw_args ")"
            | NAME ":=" NAME "." NAME
            | NAME ":=" NAME

typespec   := NAME "::" "stream" "(" type ")"
            | NAME "::" "function" "(" "(" fn_type_params? ")" "->" type ")"
            | NAME "::" "aggregate_function" "(" "(" fn_type_params? ")" "->" type ")"

fn_def     := NAME ":=" "function" "(" fn_params "->" expr ")"

comment    := "#" .* NEWLINE
```

| Operator | Args | Semantics |
|----------|------|-----------|
| `source` | `"table"` | Circuit entry point. Mandatory `:: stream(...)` annotation. |
| `delay` | `node` | z⁻¹ — one-step delay. |
| `integrate` | `node` | Accumulate deltas into a Z-set. |
| `differentiate` | `node` | Compute delta of accumulated state. |
| `distinct` | `node` | Collapse opposite-weight pairs. |
| `plus` | `node, ...` | Merge N streams by summing weights. |
| `neg` | `node` | Invert weight sign. |
| `map` | `node, fn` | 1→1 row transform. |
| `flat_map` | `node, fn` | 1→N row expansion. |
| `join` | `left, right, on: ["f", ...]` | Equi-join. |
| `aggregate` | `node, fn, by: ["g", ...]` | Group-by and fold via aggregate function. |
| `filter` | `node, fn` | Keep or discard rows. |
| `project` | `node, ["f", ...]` | Drop unlisted fields. |
| `antijoin` | `left, right, on: ["f", ...]` | Left rows with no right match. |
| `fixpoint` | `circuit_name, kw_args` | Iterate circuit to convergence. |

## Naming conventions

- Node names, function names: `[a-zA-Z_][a-zA-Z0-9_]*`
- Column names (in keyword args): arbitrary double-quoted strings
- Operator names: as listed in the reference above
