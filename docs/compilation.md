# Grasp DBSP — Compilation

Date: 2026-07-29
Status: draft

---

## 1. Overview

Compilation transforms a parsed `.gdbsp` program into a deployable DBSP
circuit. The pipeline has five stages:

```
parse → type infer → compile to circuit → incrementalize → deploy
```

Each stage consumes the output of the previous stage and produces a
progressively lower-level representation.

---

## 2. Stage 1 — Parse

A `.gdbsp` source file is parsed into a program representation containing:

- **Nodes** — operator definitions: `name := operator(args...)`
- **Type annotations** — stream types: `name :: stream(type)`
- **Function declarations** — signatures: `fn :: function((params) → ret)`
- **Aggregate declarations** — signatures: `fn :: aggregate_function((val) → ret)`

Forward references are allowed. The parser resolves all node names after
reading the entire file. See [grasp-dbsp.md](grasp-dbsp.md) for the
full language specification.

---

## 3. Stage 2 — Type Inference

The type inference pass assigns a concrete type to every node in the
program. It produces a map from node name to type.

See [type-inference.md](type-inference.md) for the complete semantics.

---

## 4. Stage 3 — Compile to Circuit Graph

Each source-level node is lowered to one or more circuit-level nodes.
The result is a directed graph of operators — the **circuit graph**.

### 4.1 Direct Mapping

| Source operator | Circuit nodes |
|----------------|-------------|
| `source("table")` | 1 node: `{source, "table"}` with schema from type annotation |
| `delay(node)` | 1 node: `delay` |
| `integrate(node)` | 1 node: `integrate` |
| `differentiate(node)` | 1 node: `differentiate` |
| `distinct(node)` | 1 node: `distinct` |
| `plus(a, b, ...)` | 1 node: `plus` with all inputs |
| `neg(node)` | 1 node: `neg` |
| `map(node, fn)` | 1 node: `map` with expression tree from function registry |
| `filter(node, fn)` | 1 node: `filter` with expression tree from function registry |
| `flat_map(node, fn)` | 1 node: `flat_map` with expression tree from function registry |
| `project(node, [...])` | 1 node: `project` with keep-field list |

### 4.2 Join Decomposition

`join(left, right, on: [...])` expands to a chain of **three** nodes:

1. `map_index` — extracts key fields + non-key fields from the left input
2. `map_index` — extracts key fields + non-key fields from the right input
3. `join` — consumes both `map_index` outputs, produces the merged output

The `map_index` operators partition the struct fields into key and value
groups, which the `join` operator uses for indexing and lookup.

### 4.3 Aggregate Decomposition

`aggregate(input, fn, by: [...], value: "v", as: "r")` expands to a chain
of **three** nodes:

1. `map_index` — partitions the input struct into key fields (`by:`) + the value field
2. `aggregate` — performs the group-by-and-fold using the aggregate function from the registry
3. `map(unwrap)` — reconstructs a flat struct from the aggregate's internal representation: `by_fields ++ [result_field]`

### 4.4 Antijoin Expansion

`antijoin(left, right, on: [...])` expands to a composite operator chain
that:

1. Tags rows from both sides with unique indices
2. Performs the join
3. Filters rows that have no right-side match
4. Negates and merges with the original left input

This expansion is transparent at the source level.

### 4.5 Name Resolution

Node names in operator arguments are resolved to internal circuit node
IDs after all nodes are placed. References to nodes not yet defined
(forward references) are resolved once the target node is compiled.

### 4.6 Function Resolution

Operators that reference functions (`map`, `filter`, `flat_map`,
`aggregate`) look up the function name in the **function registry**
(see [stdlib.md](stdlib.md) §4). A missing function is a compile error:
`missing_function`.

---

## 5. Stage 4 — Incrementalization

DBSP circuits operate on **deltas** (insertions and retractions), but
certain operators require the full accumulated state (**Z-sets**) as input.
Incrementalization inserts `integrate` / `differentiate` pairs to convert
between the two modes.

### 5.1 Operator Classification

| Operator | Linear | Needs Full Input | Produces Full Output |
|----------|--------|-----------------|---------------------|
| `source` | — (entry point) | — | — (delta mode by default) |
| `map`, `filter`, `flat_map` | yes | no | no |
| `plus`, `neg` | yes | no | no |
| `delay` | yes | no | no |
| `project` | yes | no | no |
| `map_index` | yes | no | no |
| `join` | no | yes | yes |
| `distinct` | no | yes | yes |
| `aggregate` | no | yes | yes |
| `antijoin` | no | yes | yes |
| `integrate` | no | no | yes |
| `differentiate` | no | no | no |

### 5.2 I/D Insertion Rules

For each non-linear operator:

1. **Integrate** is inserted on each input — converts incoming deltas to Z-sets
2. **Differentiate** is inserted on the output — converts the result Z-set back to deltas

```
Before:                     After:

  A ─┬─ join ── C            A ─ integrate ─┬─ join ─ differentiate ── C
  B ─┘                       B ─ integrate ─┘
```

### 5.3 Simplification

Adjacent `integrate` / `differentiate` pairs cancel out and are removed.
This eliminates unnecessary state management when two non-linear operators
are chained.

```
integrate → differentiate   →   (removed)
differentiate → integrate   →   (removed)
```

### 5.4 Output Wrapping

Output nodes (designated externally by the runtime) are automatically
wrapped with `differentiate` if their upstream is in full mode. This
ensures that externally observable output is always in delta mode.

---

## 6. Stage 5 — Deploy Plan

The final compilation stage produces a **deploy plan** — a deployable
specification that the runtime uses to instantiate the circuit.

### 6.1 Plan Structure

| Component | Content |
|-----------|---------|
| `wiring` | Routing tuples: `{FromRef, FromLabel, ToRef, ToLabel}` — specifies which operator output feeds which operator input |
| `configs` | Per-operator configuration: `#{Ref => #{mod => Module, args => Args, labels => Labels}}` |

### 6.2 Ref Assignment

Each circuit node gets a ref used in wiring and configs:

| Node type | Ref |
|-----------|-----|
| Source node | `{source, TableName, Ref}` |
| Output node | `{output, OutputName, Ref}` |
| Internal operator | `{op, Ref}` |

### 6.3 External Management

Source and output nodes are not assigned runtime operators in the configs.
They are managed externally by the runtime:
- Source nodes receive data from external input processes
- Output nodes emit data to external collectors or subscribers

### 6.4 Value Module

The deploy plan allows overriding the value encoding/decoding module.
This controls how values are serialized on the wire (JSON, protobuf, etc.)
and is specified per-deployment.
