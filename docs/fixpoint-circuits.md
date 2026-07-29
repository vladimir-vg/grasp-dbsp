# Grasp DBSP — Fixpoint Circuits

Date: 2026-07-29
Status: draft

---

## 1. Overview

A fixpoint instantiation runs a circuit body iteratively within a single parent
epoch. Self-referential parameters feed back through an implicit **delay**.
Iteration continues until no new tuples are produced — the **fixpoint**.

The same circuit definition used for macro expansion can also be instantiated
with `fixpoint`. The circuit body must satisfy one constraint: every
self-referential node must be wrapped in `distinct(...)`.

This document extends [circuits.md](circuits.md). Concepts introduced there
(parameters, self-referential vs base, name resolution) are assumed.

---

## 2. Syntax

```
fp := fixpoint name(key1: expr1, key2: expr2)
result := plus(fp.node1, fp.node2)
```

The `fixpoint` keyword precedes the circuit name. Arguments are passed by
keyword, identical to macro-expansion syntax. Accessing internal nodes via
`fp.node` returns the convergent value after all iterations complete.

---

## 3. Fixpoint Iteration Model

### 3.1 Rounds

A fixpoint instance executes its body in **rounds** within a single parent
epoch. Rounds are numbered `0, 1, 2, ...`.

On each round:

1. **Input**. Self-referential parameters receive the previous round's output
   (via implicit delay). Base parameters receive the frozen argument value.
   On round 0, delay returns empty for all self-referential parameters.
2. **Execute**. The body is evaluated as a DAG from parameters to outputs.
3. **Compare**. Each self-referential node's value is compared against the
   previous round's value. If all are unchanged, fixpoint is reached.
4. **Next**. If any self-referential node has changed, its new value feeds the
   implicit delay for the next round.

### 3.2 Implicit Delay

For each self-referential parameter, the fixpoint runtime inserts an implicit
**delay** on the feedback edge. This delay operates at iteration granularity:

| Round | `delay(self_ref)` returns |
|---|---|
| 0 | Empty delta |
| K (K > 0) | Value of the self-referential node at round K−1 |

The delay is a scheduling mechanism, not a data transformation. It prevents the
output of round K from instantaneously feeding back into the input of the same
round, which would create an unresolved cycle. It does not alter the data.

### 3.3 Convergence Detection

After round K, for each self-referential node `N`:

- Let `V_prev` be the Z-set value of `N` at round K−1 (empty for K=0).
- Let `V_curr` be the Z-set value of `N` at round K (after body evaluation,
  including the mandatory `distinct`).

If `V_curr == V_prev` for **all** self-referential nodes, fixpoint is reached.
The convergent values are emitted to the parent epoch.

Equality means the same rows with the same weights. The implicit delay stores
the full Z-set from the previous round for this comparison.

---

## 4. Distinct Requirement

### 4.1 Rationale

Without `distinct`, a self-referential node could re-emit the same tuples
across rounds as fresh deltas. Example:

```
circuit bad(edge: e, path: p):
    path_ready := map(p, ...)
    edge_ready := map(e, ...)
    joined := join(edge_ready, path_ready, on: ...)
    path := plus(e, joined)       # self-ref, no distinct
```

Round 0 produces `{r1}`, round 1 produces `{r1, r2}` — but `r1` appears in
round 1's output as a new delta. The Z-set never stabilises, preventing
convergence detection.

With `distinct`:

```
path := distinct(plus(e, joined))
```

The `distinct` collapses duplicate weights for the same row within the round's
batch. Round 1's output is a well-formed Z-set whose membership can be compared
against round 0's output.

### 4.2 Enforcement

The compiler checks every circuit used with `fixpoint`: for each
self-referential parameter `key: internal`, the body node named `key` must have
`distinct` as its outermost operator.

Compilation fails with `{error, missing_distinct, NodeName}` if any
self-referential node is not wrapped in `distinct`.

This rule applies only when the circuit is used in a `fixpoint` call. The same
circuit used in a macro-expansion call has no such requirement.

---

## 5. Epoch Hierarchy

Fixpoint instances create a nested epoch hierarchy:

```
Parent epoch 0
    Fixpoint iter 0.0 (round 0)
    Fixpoint iter 0.1 (round 1)
    Fixpoint iter 0.2 (round 2)  ← convergence
Parent epoch 1
    Fixpoint iter 1.0 (round 0)
    ...
```

The fixpoint is opaque to the parent during iteration. Only when convergence is
reached do the output nodes emit records for the parent epoch. The parent sees
the convergent state as a single emission per output node per parent epoch.

When the parent epoch advances (new data arrives on a base parameter), the
fixpoint resets: round counter goes to 0, all self-referential delay state is
cleared, and a new fixpoint computation begins.

### 5.1 Base Parameter Freezing

Base parameters (keyword has no matching body node) are **frozen** at fixpoint
start. Their value is held constant across all rounds within the fixpoint epoch.
On round 0, the delay for all self-referential parameters is empty; the base
parameters provide the initial data seed. On all subsequent rounds, base
parameters deliver the same frozen value.

---

## 6. Chain-Fixpoint Equivalence

### 6.1 Statement

Let `circuit f(k1: x1, ..., kn: xn): body` be a circuit where each
self-referential parameter is wrapped in `distinct`. Then for any arguments
`A1, ..., An`:

```
fixpoint f(k1: A1, ..., kn: An).N
```

produces the same Z-set value as:

```
c0 := f(k1: A1, ..., kn: An)
c1 := f(k1: A1, ..., kn: c0.N)
...
cM := f(k1: A1, ..., kn: c_{M-1}.N)
```

for sufficiently large M (M ≥ the fixpoint depth), when comparing `cM.N` —
where `N` is any self-referential node.

### 6.2 Proof Sketch

By induction on rounds:

- **Base (round 0)**. Fixpoint round 0 receives the same parameters as chain
  link `c0`. Both evaluate the body once on identical inputs. Both produce the
  same outputs. Therefore `fixpoint_round_0.N == c0.N`.
- **Step (round K)**. Assume `fixpoint_round_{K-1}.N == c_{K-1}.N` for all
  self-referential `N`. Fixpoint round K receives delay values equal to round
  K−1 outputs. Chain link `cK` receives `c_{K-1}.N` as its self-referential
  parameter. By the induction hypothesis, these inputs are identical. The body
  is deterministic (all operators are pure functions of inputs and internal
  state initialized identically). Both produce the same outputs. Therefore
  `fixpoint_round_K.N == cK.N`.

At convergence (round D), `V_D == V_{D-1}` for all self-referential nodes,
where D is the fixpoint depth. The chain link `cD`'s output equals this
convergent value.

### 6.3 Practical Use

The equivalence allows:

- **Testing**: Verify fixpoint correctness by comparing against a manually
  constructed chain of known depth.
- **Reasoning**: Analyse fixpoint behaviour in terms of stateless function
  application steps.
- **Bounded computation**: Replace `fixpoint` with an explicit N-link chain
  when the maximum iteration depth is known statically.

---

## 7. Nested Fixpoints

A circuit instantiated with `fixpoint` may itself contain nested `fixpoint`
calls in its body:

```
circuit inner(x: v):
    y := distinct(plus(v, processing))

circuit outer(a: w):
    fp := fixpoint inner(x: w)
    a := distinct(map(fp.y, fn))

result := fixpoint outer(a: src)
```

The outer fixpoint iterates. Each outer iteration runs the inner fixpoint to
convergence before the outer body can complete. Nesting depth is arbitrary.

The epoch hierarchy extends accordingly:

```
Outer 0.0 → Inner 0.0.0 → Inner 0.0.1 → ... → Inner fixpoint → Outer 0.0 done
Outer 0.1 → Inner 0.1.0 → Inner 0.1.1 → ... → Inner fixpoint → Outer 0.1 done
```

Each nested fixpoint is an independent convergence loop. The inner fixpoint
resets when its parent (the outer body) advances to the next round.

---

## 8. Runtime Operator Model

### 8.1 Fixpoint Operator

The fixpoint instantiation introduces a **fixpoint operator** wrapping the body
subgraph. Its runtime state:

- **Round counter** — current round number within the parent epoch.
- **Previous Z-sets** — for each self-referential node, the full Z-set from the
  previous round. Used for delay inputs and convergence comparison.
- **Base parameter values** — the frozen argument values for all base
  parameters.
- **Body subgraph** — the compiled body operators, executed once per round.

On each round: feed delay outputs and base values as body inputs → run body
subgraph → collect body outputs → apply `distinct` on self-referential outputs
→ compare against previous round → if equal, emit to parent; otherwise, store
for next round.

### 8.2 Barrier Integration

The existing barrier model uses `{iter, Epoch, Round}` tags (see
[runtime-model.md](runtime-model.md) §3). The fixpoint operator extends this
with nested iteration tracking. Body operators receive barrier tags reflecting
the nested epoch: `{iter, ParentEpoch, {fixpoint, FixpointId, Round}}`.

When a self-referential node's implicit delay stores its value for the next
round, the delay buffer is keyed by the fixpoint's nested barrier context,
ensuring correct isolation between concurrent fixpoint instances.

---

## 9. Compile-Time Validation

| Rule | Error |
|---|---|
| Circuit used in `fixpoint` must have all self-referential nodes wrapped in `distinct` | `{error, missing_distinct, NodeName}` |
| Circuit with no self-referential parameters used in `fixpoint` | Warning: trivially converges at round 0 |
| Circuit body contains `source` nodes (external data sources) | `{error, source_in_fixpoint_body}` |
| Same validation rules as macro expansion for argument binding | See [circuits.md](circuits.md) §7 |

### 9.1 Source Nodes Prohibition

A circuit instantiated with `fixpoint` must not reference `source` nodes
(external data sources) in its body — directly or transitively through its
parameters. Fixpoint sub-circuits have their own epoch frequency higher than the
parent. External sources cannot be bound to this higher frequency.

All data entering a fixpoint must arrive through circuit parameters, which are
frozen (base) or feedback-driven (self-referential) within the fixpoint epoch.

---

## 10. Examples

### 10.1 Transitive Closure

```
circuit tc_body(edge: e, path: p):
    path_ready := map(p, rename_path_for_join)
    edge_ready := map(e, rename_edge_for_join)
    joined := join(edge_ready, path_ready, on: ["joinkey"])
    joined_proj := project(joined, ["from", "z"])
    base := map(e, rename_from_to)
    path := distinct(plus(base, joined_proj))

edge_src := source("edge")
edge_src :: stream(struct("from": i64, "to": i64))

fp := fixpoint tc_body(edge: edge_src, path: empty)
path_state := integrate(fp.path)
path_deltas := differentiate(path_state)
```

**Trace** (edges: 1→2, 2→3):

```
Round 0.0: delay(path)=Ø, edge=edges
  base = {(1,2), (2,3)}, joined=Ø, path = distinct(base) = {(1,2), (2,3)}
  path ≠ previous → continue

Round 0.1: delay(path)={(1,2),(2,3)}, edge=edges
  joined = {(1,3)}, path = distinct(base ∪ joined) = {(1,2),(2,3),(1,3)}
  path ≠ previous → continue

Round 0.2: delay(path)={(1,2),(2,3),(1,3)}, edge=edges
  joined = {(1,3)} (already in path), path = {(1,2),(2,3),(1,3)}
  path == previous → fixpoint reached
```

### 10.2 Mutual Recursion

```
circuit mutual_body(init: prev_init, r1: prev_r1, r2: prev_r2):
    r1 := distinct(plus(prev_init, prev_r2))
    r2 := prev_r1

init_src := source("init")

fp := fixpoint mutual_body(init: init_src, r1: init_src, r2: empty)
r1_state := integrate(fp.r1)
r2_state := integrate(fp.r2)
```

**Trace** (init delivers {x: 1}):

```
Round 0.0: prev_init={1}, prev_r1=Ø, prev_r2=Ø
  r1 = distinct({1} ∪ Ø) = {1}
  r2 = Ø

Round 0.1: prev_init={1}, prev_r1={1}, prev_r2=Ø
  r1 = distinct({1} ∪ Ø) = {1}   ← unchanged
  r2 = {1}                       ← changed

Round 0.2: prev_init={1}, prev_r1={1}, prev_r2={1}
  r1 = distinct({1} ∪ {1}) = {1} ← unchanged after distinct
  r2 = {1}                       ← unchanged

Fixpoint reached.
```

### 10.3 Nested Fixpoint

```
circuit inner(x: v):
    y := distinct(plus(v, shift))

circuit outer(a: w):
    fp := fixpoint inner(x: w)
    a := distinct(plus(w, fp.y))

result := fixpoint outer(a: src)
```

Each outer iteration runs the inner fixpoint to convergence before computing
`a`. The inner fixpoint receives the outer round's current `w` value as its
base parameter.

### 10.4 Equivalent Chain

The transitive closure circuit instantiated as a chain with known depth 3:

```
c0 := tc_body(edge: edge_src, path: empty)
c1 := tc_body(edge: edge_src, path: c0.path)
c2 := tc_body(edge: edge_src, path: c1.path)
path_state := integrate(c2.path)
path_deltas := differentiate(path_state)
```

For a graph with diameter ≤ 3, `c2.path` contains the full transitive closure
and equals the fixpoint output.
