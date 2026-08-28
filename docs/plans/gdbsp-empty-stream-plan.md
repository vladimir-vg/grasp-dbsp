# gdbsp Empty Stream Plan

Date: 2026-08-28
Status: accepted

---

## 1. Context

Many fixpoint circuits use an accumulator stream: a self-referential
parameter whose base value is "nothing" — an empty stream that produces zero
rows but still participates in barrier/epoch propagation. Today there is no way
to express that constant directly, so authors pass a dummy `source(...)` and
feed it a synthetic row (or nothing) to seed the accumulator.

This plan introduces an `empty()` constant into the language: a **nullary
stream** that emits zero rows and repeats every barrier it receives. It is the
identity element for the "union of streams" monoid and the natural base case
for accumulator-style fixpoints, and is usable anywhere a stream is valid
(general-purpose).

---

## 2. Findings

### 2.1 Barriers originate only from the clock (or the coordinator)

`empty` is nullary: it has no upstream, so it can only emit when driven by an
epoch clock. The clocks are:

- `gdbsp_ingress` (CLI/http) and the test harnesses
  (`gdbsp_e2e_SUITE:send_epoch_done`, `gdbsp_cross_runner:send_epoch_done`),
  which push `epoch_done` to every source;
- the fixpoint rec coordinator, which drives iteration barriers
  (`{iter, E, N}`, `state_reset`) to the body.

So `empty` must be a **barrier-repeating feeder** driven by one of these,
depending on where it appears.

### 2.2 Two driver cases, distinguished by `scc_id` meta

- **Top-level / fixpoint-base `empty`** (no `scc_id`): wired as a source and
  driven by the ingress/harness with `epoch_done`. As a fixpoint base it
  becomes the rec's `source` (`gdbsp_circuit_proc:wire_rec_source`), exactly
  like a `source("…")` node.
- **Body-internal `empty`** (has `scc_id`, i.e. `empty()` written inside a
  `circuit` body): must emit in sync with the iteration, so it is driven by
  the coordinator via the rec's `body_input_pids`, like any body operator.

### 2.3 `empty` has no rows, so it must be polymorphic

Its schema cannot be inferred from data. It must unify with whatever stream it
is combined with. The type catalog already supports `{type_var, Name}` (names
starting with an uppercase letter, `gdbsp_parse.erl:527-537`) and
`gdbsp_builtins` already ships `unify/3` and `exact_match/2` with the wildcard
rules `exact_match({type_var,_}, _) -> true` / `exact_match(_, {type_var,_}) ->
true` (`gdbsp_builtins.erl:330-331, 588-641`).

What is missing is that `gdbsp_type_infer` uses strict `canonical_text`
equality (not wildcard unification) for multi-input nodes — `plus`
(`gdbsp_type_infer.erl:273-287`) and the join key check (`:425-442`).

---

## 3. Design

### 3.1 `empty()` syntax and typing

- `empty()` parses as a nullary node `#gdbsp_node_def{op = empty, args = []}`
  (add `empty` to `known_op`).
- `empty()` carries **no mandatory type annotation**; its type is a fresh
  `{type_var, Unique}` per occurrence, which unifies with the concrete stream
  it is combined with. An explicit `:: stream(...)` annotation is permitted and
  constrains the type.
- Type inference treats `{type_var, _}` as a wildcard:
  - `plus`: wildcard equality; result type = the concrete operand's type (or
    `dynamic` when every operand is a type var).
  - `join` key check: skip/matching when either side is a type var.
  - `merge_join_type`/`struct_fields`/`field_type` already tolerate non-structs
    (`struct_fields(_) -> #{}`), so the empty side contributes no fields.
  - `project`/`order`/`aggregate` on a bare type var: naturally error or yield
    an empty schema (degenerate — `empty` has no rows).
- An unresolved type var reaching the compile-graph phase maps to an empty
  schema `[]`.

### 3.2 `gdbsp_op_empty` process

A dedicated gen_server (not a `gdbsp_op_proc`-wrapped behavior module, which
resolves senders via an upstream pidmap a nullary op lacks):

- `{wiring_update, …}` → learn downstream pids.
- `{delta, Meta, _Deltas, _From}` → forward `{delta, Meta, [], self()}`
  (empty deltas, preserving the barrier tag — `epoch_done`, `{iter, E, N}`,
  `state_reset`, …).

### 3.3 Wiring / clocking

- Top-level `empty` nodes are **external feeders**:
  - `gdbsp_loader:compile/3` returns a new `empty_types :: #{Name => Type}`
    field (kept out of `source_types`, so the HTTP `/inputs` API is unaffected).
  - The runtime and both harnesses spawn `gdbsp_op_empty` procs and pass them
    via a new `Empties` argument to `circuit_update`
    (`resolve_pid({empty, Name})` looks them up), and the ingress/harness drives
    them with `epoch_done`.
- Body-internal `empty` nodes (with `scc_id`) are spawned by `gdbsp_circuit_proc`
  and attached to **one** rec's `body_input_pids` per SCC (deterministically the
  first rec), so the rec feeds them the same translated barriers as body
  operators. They never touch the ingress.

### 3.4 Compile pipeline

- `gdbsp_compile_lower`: `empty` passes through `lower_regular_node` (nullary).
- `gdbsp_compile_graph`: `make_operator_lowered empty -> {{empty}, []}`;
  `compute_schema_lowered empty` → schema from the (substituted) type;
  `mark_scc_body_nodes` marks body-internal empties.
- `gdbsp_compile_incremental`: `{empty}` → `delta` (like `source`), never
  wrapped.

---

## 4. File-by-file changes

- `include/gdbsp_circuit.hrl` — add `{empty}` to `operator()`.
- `src/gdbsp_parse.erl` — `known_op(<<"empty">>)`.
- `src/gdbsp_type_infer.erl` — `empty` clause (fresh type var) + wildcard
  handling in `plus`/`check_join_key_types`.
- `src/gdbsp_compile_graph.erl` — `empty` cases in `make_operator_lowered` /
  `compute_schema_lowered`; SCC body marking.
- `src/gdbsp_compile_incremental.erl` — `{empty}` → `delta`.
- `src/gdbsp_circuit.erl` — `op_atom`/`op_args`/`labels_for` for `{empty}`.
- `src/gdbsp_operator_spec.erl` — `is_linear({empty}) -> true` (or explicit
  handling), registry entry as needed.
- `src/gdbsp_deploy.erl` — ref + config for `empty`.
- `src/gdbsp_op_empty.erl` (new) — barrier-echo process.
- `src/gdbsp_circuit_proc.erl` — spawn body empties, attach to rec
  `body_input_pids`, resolve top-level empties via `Empties`.
- `src/gdbsp_loader.erl` — expose `empty_types`.
- `src/gdbsp_runtime.erl` + `src/gdbsp_ingress.erl` — spawn + drive top-level
  empties.
- `test/gdbsp_e2e_SUITE.erl`, `test/gdbsp_cross_runner.erl` — spawn + drive
  top-level empties.
- `docs/syntax.md`, `docs/grasp-dbsp.md`, `docs/compilation.md` — document
  `empty()`.

---

## 5. Verification gates

- `rebar3 ct` stays green (currently 640/640).
- New `gdbsp_op_empty_SUITE`: echoes any barrier with empty deltas; wiring relay.
- New `gdbsp_type_infer_SUITE` cases: `empty` unifies with `plus`/`join`
  operands; a lone `empty()` is a fresh type var.
- Fixtures: replace dummy accumulator-base sources with `empty()` (e.g.
  `e2e_fixpoint_wiring.yaml` "unused_base"); add a body-internal `empty()`
  fixture; add `join(x, empty())` and `plus(x, empty())` cases.

---

## 6. Decisions / defaults

- `empty()` needs no `:: stream(...)`; explicit annotation is optional.
- Body empties attach to the first rec of their SCC (not all recs).
- Unresolved type var at compile-graph → empty schema `[]`.

## 7. Out of scope

- Full bidirectional type unification beyond the `empty` wildcard case.
- Removing the incrementalization pass (already decided to keep for performance).
