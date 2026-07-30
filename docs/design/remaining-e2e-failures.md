# Remaining e2e Failures — Status Update

**Commit:** `8fe16b0` (after RecOutput fix + type inference after lowering)
**Date:** 2026-07-30
**Status:** 58/60 e2e pass, 2 e2e fail; all other suites 100% (288/290 total)

---

## Resolved

### 1. RecOutput Self-Loop in Self-Ref Fixpoints (2 of 3 fixed)

**Tests:** `e2e_fixpoint_selfref`, `e2e_fixpoint_multi_epoch` — PASSING
**Test:** `e2e_fixpoint_multi_iter` — still FAILING (barrier mismatch, see below)

**Root cause:** The `BodyToRecOut` fixup in `construct_one_fixpoint/7` rewrote
RecOutput's input from `[BodyOutCId]` to `[RecOutId]`, creating a self-loop.
RecOutput lacked `scc_body` meta, so the fixup treated it as an external node.

**Fixes (commit `4918810`):**
1. `gdbsp_compile_graph.erl`: RecOutput `meta = #{scc_body => true}`
2. `gdbsp_compile_incremental.erl`: `wrap_nonlinear` skips `scc_body` nodes
   in its differentiate replacement
3. `gdbsp_circuit_proc.erl`: `rec_output_to_rec` matches RecOutput→Rec
   by `SccId` instead of wiring-tuple sender analysis
4. `gdbsp_compile_graph.erl`: `fixpoint_input` integrates get schema from input

### 2. Join Type Mismatch

**Test:** `e2e_fixpoint_join` — PASSING

**Root cause:** `build_struct_type` traced only the first input's chain to
resolve output types, missing right-side fields. Additionally, type inference
ran before lowering/deduplication and was disconnected from the compilation
pipeline.

**Fix (commit `d37acef`):**
- New `infer_lowered/3` runs type inference after lowering on the deduplicated
  graph with proper topological sort
- Types stored in `#circuit_graph.types` during `construct_from_lowered`
- `output_types_from_graph` reads from circuit graph types, not `build_struct_type`
- `compute_schema_lowered(join)` uses inferred type when available

---

## Remaining Failures

### 3. Barrier Mismatch in Multi-Input Body Operators

**Tests:** `e2e_fixpoint_multi_iter`, `e2e_fixpoint_types_4` (B3: join in self-ref)

**Error:** `{tag_mismatch,[epoch_done,{iter,0,0}]}` in `gdbsp_barrier:try_flush_multi`

**Root cause:** When a multi-input operator inside a self-ref fixpoint body
combines a base input (carrying `epoch_done` barrier from external source) with
a self-ref input (carrying `{iter,0,0}` barrier from Rec coordinator), the
barrier synchronization detects mismatched tags.

`e2e_fixpoint_selfref` and `e2e_fixpoint_multi_epoch` avoid this because
their bodies have only single-input operators (`distinct` only).

`e2e_fixpoint_multi_iter` has `combined := plus(input, next)` where `input`
is base and `next` is from the feedback path.

**Not introduced by recent changes** — this barrier mismatch was always
present in the lowered path but masked by the cycle bug (the circuit never
reached runtime). The non-lowered path may handle this differently.

---

## Test Coverage Added (commit `8fe16b0`)

`e2e_fixpoint_types.yaml` — 7 new tests for type inference under lowering:

| # | Test | Description | Status |
|---|------|-------------|--------|
| A1 | Same circuit x2, different primitives | `i64` / `string("UTF-8")` | PASS |
| A2 | Join circuit x2, different field types | `i64` / `string("UTF-8")`+`f64` | PASS |
| A3 | Multi-key join, mixed types | `on: ["k1","k2"]`, `f64`/`i32` | PASS |
| B3 | Join in self-ref feedback loop | Base + self-ref inputs in join | BLOCKED by barrier |
| B4 | Map adds literal field in self-ref | `struct` constructor with `{type:"string"}` | PASS |
| B5 | Project narrows type in self-ref | Projects away `extra` field through feedback | PASS |
| C2 | Map renames fields in trivial circuit | Rename via struct constructor | PASS |
