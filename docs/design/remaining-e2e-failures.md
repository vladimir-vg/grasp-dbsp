# Remaining e2e Failures — Investigation Plan

**Commit:** `21ecc43` (after lowering-stage fixes)
**Date:** 2026-07-30
**Status:** 49/53 e2e pass, 4 e2e fail (plus all other suites at 100%)

---

## 1. Incrementalizer Cycle in Self-Ref Fixpoints (3 tests)

**Tests:** `e2e_fixpoint_multi_iter`, `e2e_fixpoint_selfref`, `e2e_fixpoint_multi_epoch`

**Error:** `{badmatch,{error,cycle}}` in `gdbsp_compile_incremental:run/1`
**Call site:** `gdbsp_e2e_SUITE:compile_to_plan/3` line 270, inside `run_positive/5`

**Observed behavior:** Compilation (parse → type-infer → lower → compile-graph)
succeeds. The circuit graph is correctly built with Rec/RecOutput nodes for
self-referential circuits. The failure is in
`gdbsp_compile_incremental:topological_sort/1` which detects a cycle that its
`ExcludeDelayEdges` logic cannot break.

**Evidence from debug (multi_iter, ExcludeDelayEdges=true):**

```
processed=7/10, 3 nodes stuck:
  node 8  op={plus}            inputs=[9] indeg=1
  node 9  op={rec_output,...}  inputs=[9] indeg=1  ← SELF-LOOP
  node 10 op={output,...}      inputs=[8] indeg=1
```

RecOutput (node 9) has `inputs=[9]` — referencing itself. This should not happen.
RecOutput.inputs should be `[BodyOutCId]` where `BodyOutCId` is the body output
circuit node ID, not RecOutput's own ID.

### Hypothesis

The LnIdMap entry for `BodyOutLId` (the body output lowered ID) maps to a
circuit ID that collides with `GA#circuit_graph.next_id` at RecOutput creation
time. Possible causes:

1. **fixpoint_output pass-through collision:** In `construct_from_lowered` at
   `gdbsp_compile_graph.erl:246`, the fixpoint_output node is a pass-through
   that maps `fixpoint_output_lowered_id → CId` where `CId` is the body output
   circuit ID. If `CId` happens to equal the `next_id` that will later become
   RecOutId, the RecOutput gets a self-loop.

2. **Body node ID assignment:** With the `Tags=[BN]` fix (commit `21ecc43`),
   body nodes are now registered in the tag_map, which may change their
   processing order in `construct_from_lowered`, shifting `next_id` assignments.

### Investigation Plan

1. Add targeted printf at RecOutput creation in `construct_one_fixpoint/7`
   (`gdbsp_compile_graph.erl:464-468`):
   - Dump `BodyOutLId`, `BodyOutCId = maps:get(BodyOutLId, LnIdMap)`,
     `RecOutId = GA#circuit_graph.next_id`, and the full `LnIdMap` contents
   - Print the node assigned to `BodyOutCId` to confirm its op and inputs
2. Run `e2e_fixpoint_selfref` (simplest case — single body node, no cross-refs)
   with the debug and capture output
3. If `BodyOutCId = RecOutId`, trace back to find which LnIdMap entry creates
   the collision (likely the fixpoint_output pass-through mapping)
4. Also verify that the ExcludeDelayEdges logic in the incrementalizer correctly
   handles the Rec→body→RecOutput→Rec cycle assuming correct wiring

---

## 2. Join Type Mismatch (1 test)

**Test:** `e2e_fixpoint_join`

**Error:** `{badmatch,{error,{type_mismatch,dynamic,<<"100">>}}}`
**Call site:** `gdbsp_e2e_SUITE:parse_expected_deltas/2` line 494

**Observed behavior:** Compilation and execution succeed. The join fixpoint is
trivial (no self-ref), body inlined by `expand_trivial`. The runtime produces
correct output rows, but the **expected values** can't be decoded because the
output type resolves to `dynamic` instead of
`struct("via": i64, "la": i64, "lb": i64)`.

### Root Cause

**Source:**

```
circuit join_two(a: left, b: right):
    result := join(left, right, on: ["via"])

src_a :: stream(struct("via": i64, "la": i64))
src_b :: stream(struct("via": i64, "lb": i64))
fp := fixpoint join_two(a: src_a, b: src_b)
out := fp.result
```

The join produces output schema `["via", "la", "lb"]` (from
`compute_schema_lowered`). This is just a column name list, not a typed struct.

`output_types_from_graph` calls `build_struct_type` at
`gdbsp_e2e_SUITE.erl:292` which resolves types by tracing the graph's input
chain. It follows **only the first input** path (left input), which has types
for `via` and `la` but not `lb` (from the right input). Result:

```
{struct, #{"via" => i64, "la" => i64, "lb" => dynamic}, exact}
```

### Investigation Plan

1. Examine how the OLD (non-lowered) `build` path at
   `gdbsp_compile_graph:build/4` handles join type propagation — specifically
   `build_join_graph` which computes `Merged = build_merged_fields(...)`
   returning a full `{struct, ...}` type
2. Check whether `build_join_graph_lowered` at line 288 already computes the
   merged type via `build_merged_fields(Shared, LeftVal, RightVal, LType, RType)`
   but doesn't store it in the circuit graph's schemas
3. **Fix approach A (preferred):** Modify `compute_schema_lowered` for the
   `join` case to store a typed struct rather than bare column names. The full
   type is available from the join construction — pass it through or recompute it
4. **Fix approach B:** Modify `build_struct_type` (or
   `output_types_from_graph`) to traverse ALL inputs for join/aggregate nodes,
   merging field types from each input source schema

---

## Summary

| Issue | Tests | Layer | Status |
|-------|-------|-------|--------|
| RecOutput self-loop | 3 self-ref | Incrementalizer | Needs 1 round debug |
| Join type propagation | 1 join | Type system | Needs schema storage fix |

Both issues are in code that was added or modified in the lowering-stage commit
(`c620e1e`). They affect only the **lowered** code path; the original
non-lowered path (used before the lowering stage was introduced) handles
these correctly via separate implementations.
