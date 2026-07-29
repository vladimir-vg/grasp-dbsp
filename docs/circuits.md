# Grasp DBSP — Circuit Definitions

Date: 2026-07-29
Status: draft

---

## 1. Overview

Circuit definitions introduce named, parameterised subgraphs. A circuit body is a
sequence of operator definitions, just like top-level `.gdbsp` source. Parameters
are bound by keyword at the call site and substituted into the body.

Circuits serve two purposes:

- **Reuse** — avoid repeating identical operator chains across a `.gdbsp` file.
- **Fixpoint** — define a recursive computation body that can be iterated to
  convergence (see [fixpoint-circuits.md](fixpoint-circuits.md)).

A circuit can be instantiated in two modes:

- **Macro expansion** — the body is inlined at the call site. No runtime
  overhead, no iteration. Equivalent to writing the body nodes directly.
- **Fixpoint** — described in [fixpoint-circuits.md](fixpoint-circuits.md).

This document covers circuit definition, parameter semantics, name resolution,
macro expansion, and chaining.

---

## 2. Syntax

### 2.1 Definition

```
circuit name(key1: internal1, key2: internal2, ...):
    node1 := op1(...)
    node2 := op2(...)
    ...
```

- `name` — the circuit name, used at call sites.
- `key` — a keyword label. Used at the call site to pass an argument. Defines
  the external interface of the circuit.
- `internal` — an identifier used inside the body to reference the bound
  argument value.

### 2.2 Instantiation

```
c1 := name(key1: expr1, key2: expr2)
result := plus(c1.node1, c1.node2)
```

Arguments are passed by keyword. Every declared keyword must be supplied. The
instantiation variable (`c1`) provides access to all body-defined nodes via
dot notation.

Keyword arguments are expressions — they can be existing node names, source
references, literals, or other circuit instantiations.

---

## 3. Parameters

### 3.1 Binding

Each parameter `key: internal` maps an external keyword to an internal name. At
expansion time, the internal name is substituted with the argument expression.

```
circuit normalize(src: s):
    mapped := map(s, normalise_fn)
    filtered := filter(mapped, is_valid)
    deduped := distinct(filtered)

n1 := normalize(src: source_a)
n2 := normalize(src: source_b)
```

`normalize(src: source_a)` substitutes `s` → `source_a` throughout the body.
The resulting nodes are accessible as `n1.mapped`, `n1.filtered`, `n1.deduped`.

### 3.2 Self-Referential Parameters

A parameter `key: internal` is **self-referential** if the body defines a node
whose name matches `key`.

```
circuit tc_body(edge: e, path: p):
    ...
    path := distinct(plus(base, joined_proj))
```

Here `path` is self-referential — the keyword `path` appears both as a
parameter and as a body-defined node.

Self-referential parameters have no special semantics in macro-expansion mode.
Their role becomes significant in fixpoint mode (see
[fixpoint-circuits.md](fixpoint-circuits.md) §3).

### 3.3 Base Parameters

A parameter is a **base** if no body node shares its keyword name. In the
example above, `edge` is a base parameter — there is no body node named `edge`.

---

## 4. Body Scoping and Name Resolution

Names in the body resolve in order of definition:

1. **Parameters** are in scope from the top. The `internal` name (e.g., `s`,
   `e`, `p`) is used, not the keyword.
2. **Body-defined nodes** shadow parameters with the same `internal` name. Once
   `mapped := map(s, ...)` is defined, `mapped` shadows any parameter also
   named `mapped`.
3. **Right-hand side references** resolve to the most recent definition of that
   name — either a parameter or a preceding body node. Forward references are
   not allowed.

```
circuit ex(a: x, b: y):
    m := x         # reads parameter x (via keyword a)
    x := plus(m, y) # defines node x; shadows parameter x
                     # self-referential by keyword a
```

Keyword `a` is self-referential (body has node `a` matching). Keyword `b` is
base (no body node named `b`). The internal name `x` is both a parameter and a
defined node — the definition shadows the parameter after its occurrence.

A body node cannot reference itself directly. The body is a DAG within a single
evaluation step.

---

## 5. Macro Expansion

A call `name(key1: expr1, key2: expr2)` performs **compile-time substitution**.

### 5.1 Substitution Rules

1. For each parameter `key: internal`, every RHS occurrence of `internal` in
   the body is replaced with the argument expression.
2. The substituted body is flattened into the calling scope — as if the body
   nodes had been written directly at the call site.
3. No new operators or processes are created. Macro expansion is pure inlining
   with zero runtime cost.

Substitution is **syntactic**, not semantic. The argument expression is
substituted as-is into the body text, preserving its own scoping.

### 5.2 Node Access

All body-defined nodes are exported. Given:

```
circuit ex(a: x, b: y):
    m := plus(x, y)
    n := map(m, fn)

c := ex(a: src1, b: src2)
```

Both `c.m` and `c.n` are accessible in the calling scope. The dot notation
resolves to the expanded node name after substitution.

---

## 6. Chaining

Because macro expansion is stateless, multiple calls can be chained. Each link
is an independent circuit instance whose outputs feed the next link's
parameters:

```
c0 := step(edge: e_src, path: empty)
c1 := step(edge: e_src, path: c0.path)
c2 := step(edge: e_src, path: c1.path)
```

`c0` evaluates once, `c1` receives `c0.path` as its `path` parameter and
evaluates once, and so on. N links produce the result of N applications of the
body function.

Chaining is the spatial analogue of fixpoint iteration. The equivalence between
N-step chains and N-round fixpoints is proved in
[fixpoint-circuits.md](fixpoint-circuits.md) §6.

---

## 7. Compile-Time Validation

| Rule | Error |
|---|---|
| All declared keyword arguments must be supplied | `{error, missing_argument, Keyword}` |
| No extra keyword arguments beyond declared parameters | `{error, unknown_argument, Keyword}` |
| Body references an undefined name (not a parameter, not a preceding body node) | `{error, undefined, Name}` |
| Forward reference to a body node defined later | `{error, undefined, Name}` |
| Recursive circuit definition (circuit A references circuit B in its body, B references A, forming a cycle at definition level) | `{error, recursive_circuit_definition, Path}` |

### 7.1 Recursive Definitions

Circuit definitions cannot be mutually recursive at the definition level. The
body of circuit A may reference circuit B, but if B (transitively) references
A, the compiler rejects the program. Definition-level recursion would cause
infinite expansion. Fixpoint provides the only recursion mechanism (see
[fixpoint-circuits.md](fixpoint-circuits.md)).

---

## 8. Examples

### 8.1 Simple Reuse

Reusing a normalisation pipeline on two independent sources:

```
circuit normalize(src: s):
    mapped := map(s, normalise_fn)
    filtered := filter(mapped, is_valid)
    deduped := distinct(filtered)

n1 := normalize(src: source_a)
n2 := normalize(src: source_b)
merged := plus(n1.deduped, n2.deduped)
```

### 8.2 Parameterised Operator

A circuit parameterised over a function reference:

```
circuit transform(input: i, fn: f):
    mapped := map(i, f)
    filtered := filter(mapped, is_positive)

t1 := transform(input: src_a, fn: double_value)
t2 := transform(input: src_b, fn: triple_value)
```

### 8.3 Bounded Iteration via Chaining

Simulating 3 rounds of a recursive computation without fixpoint:

```
circuit step(edge: e, path: p):
    path_ready := map(p, rename_path)
    edge_ready := map(e, rename_edge)
    joined := join(edge_ready, path_ready, on: ["key"])
    base := map(e, rename_base)
    path := distinct(plus(base, joined))

c0 := step(edge: edge_src, path: empty)
c1 := step(edge: edge_src, path: c0.path)
c2 := step(edge: edge_src, path: c1.path)
# c2.path contains paths up to 3 hops
```
