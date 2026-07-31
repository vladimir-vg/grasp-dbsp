# Nested Circuit Instantiation

Date: 2026-07-31
Status: draft

---

## 1. Motivation

Currently circuits are only instantiatable via `fixpoint`. The docs describe macro
expansion (inlining) for non-fixpoint circuit calls, but it is not implemented.
This document describes the implementation of bare-name circuit instantiation,
along with the fixpoint-body restriction and circuit-definition cycle detection.

## 2. Syntax

```
name := CircuitName(kw1: expr1, kw2: expr2)
result := name.body_node
```

Bare circuit name, keyword arguments, dot-notation access to body nodes.

## 3. Parser Disambiguation

The parser distinguishes circuit calls from built-in operators by name. The
following are reserved built-in operators and cannot be used as circuit names:

`fixpoint`, `source`, `plus`, `map`, `filter`, `flat_map`, `join`,
`aggregate`, `distinct`, `neg`, `delay`, `integrate`, `differentiate`,
`project`, `non_struct_join`, `antijoin`

Any other identifier used as a call with keyword arguments is treated as a
circuit instantiation.

Reserved names used in `circuit Name(...)` definitions produce a parse error.

## 4. Macro Expansion

A circuit call `name(kw1: expr1, ...)` performs compile-time substitution:

1. Look up `#gdbsp_circuit_def{}` from the circuit map.
2. Validate: all declared keyword args supplied, no extra args.
3. For each parameter `key: internal`, substitute `internal` with the argument
   expression throughout the body.
4. Inline the body nodes into the caller's scope with prefixed names
   (`call_name.body_node`).
5. Register output tags in the lowered graph's tag map.

No runtime overhead — macro expansion is pure inlining.

## 5. Fixpoint Body Restriction

A fixpoint's body must not transitively contain another `fixpoint` call.

When the compiler expands a `fixpoint` instantiation's body, all nested circuit
calls are flattened. If the transitive expansion encounters another `fixpoint`
node, compilation fails with:

```
{fixpoint_error, {Line, "fixpoint inside fixpoint body: ~s", [Path]}}
```

Non-fixpoint circuit calls at the top level may contain fixpoints freely.

### Example

```
circuit A():
    fixpoint inner(x: src)
    out := inner.result

circuit B():
    c := A()

fixpoint B()   # ERROR: B → A → fixpoint inner
```

## 6. Recursive Circuit Definitions

Circuit definitions cannot be mutually recursive:

```
circuit A(x: v):
    b := B(y: v)    # B is not yet defined — forward ref
circuit B(y: w):
    a := A(x: w)    # would cycle
```

Detected during lowering by tracking which circuits have been entered during
expansion. If a circuit B is re-entered while its enclosing circuit A is still
being expanded, the cycle `A → ... → B → ... → A` is reported.

Error: `{compile_error, {recursive_circuit_definition, Path}}`

## 7. Circuit Bodies May Contain Fixpoints

A circuit body instantiated via macro expansion may contain `fixpoint` calls.
These expand into the calling scope as regular nodes. The resulting program may
have fixpoint nodes at the top level but not nested inside another fixpoint body.

## 8. Implementation Files

| File | Change |
|------|--------|
| `src/gdbsp_parse.erl` | `split_op_inner/1`: detect bare keyword-arg calls whose name is not in the builtin set → `{circuit_call, NameBin}`. Reserve-name check for circuit definitions. |
| `src/gdbsp_compile_lower.erl` | `expand_circuit_call/5` — inlines circuit body. Fixpoint body validation — reject nested fixpoints. Cycle detection. |
| `docs/circuits.md` | Add disambiguation paragraph to §2.2, add §5.4 |
| `docs/fixpoint-circuits.md` | Replace §7 (nested fixpoints → fixpoint body restriction) |
| `test/gdbsp_e2e_SUITE_data/` | 14 new YAML fixture files |

## 9. Test Plan

### Phase 1 — Parser

| Test | Scenario |
|------|----------|
| `e2e_circuit_call_basic` | `c1 := add(a: src, b: src)` with two positional-arg-style inputs |
| `e2e_circuit_call_dot_access` | `n := normalize(s: val)` then `out := n.deduped` |
| `e2e_circuit_name_collision` | `circuit plus(...)` — reserved name, parse error |

### Phase 2 — Macro Expansion

| Test | Scenario |
|------|----------|
| `e2e_circuit_macro_simple` | Single circuit, two inputs, output via dot access |
| `e2e_circuit_macro_selfref` | Circuit with self-ref parameter in macro mode — just inlined |
| `e2e_circuit_macro_nested` | A → B → C, 3-level transitive expansion |
| `e2e_circuit_macro_chain` | 2-link chain `c0 := step(...)`, `c1 := step(path: c0.path)` |
| `e2e_circuit_macro_func_param` | Circuit parameterised over a function reference |
| `e2e_circuit_macro_missing_kw` | Call missing required keyword — compile error |
| `e2e_circuit_macro_extra_kw` | Call with extra keyword — compile error |

### Phase 3 — Constraints

| Test | Scenario |
|------|----------|
| `e2e_circuit_fixpoint_body_calls_circuit` | Fixpoint body calls non-fixpoint circuit — OK |
| `e2e_circuit_plain_call_contains_fixpoint` | Top-level circuit call contains fixpoint — OK |
| `e2e_circuit_fixpoint_in_fixpoint_direct` | Direct `fixpoint outer → fixpoint inner` — ERROR |
| `e2e_circuit_fixpoint_in_fixpoint_transitive` | Transitive nesting through 3 circuit calls — ERROR |
| `e2e_circuit_recursive_def` | A calls B, B calls A — ERROR |

## 10. Implementation Order (TDD)

1. Write parser tests (P1, P2, F6) → implement parser changes → verify
2. Write macro expansion tests (M1-M7) → implement `expand_circuit_call` → verify
3. Write constraint tests (F1-F5) → implement validation + cycle detection → verify
4. Update docs → verify no regressions
