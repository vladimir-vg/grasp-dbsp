# gdbsp Incrementalization Mode Refactor Plan

Date: 2026-08-28
Status: accepted

---

## 1. Context

The incrementalization pass (`src/gdbsp_compile_incremental.erl`) tracks a
per-node `full` / `delta` "mode" while inserting `integrate` / `differentiate`
pairs around non-linear operators. The `e2e_fixpoint_downstream` fixture fails
with `{mode_mismatch,[full,delta]}` because a `rec` node is forced to `full`
while a `join`-derived stream is `delta`, and the two meet at a `plus`.

Investigation shows the `full` / `delta` framing is a compile-time structural
annotation for I/D placement — **not** a data-flow contract — and that it
conflates two orthogonal properties. This plan corrects the model.

---

## 2. Findings

### 2.1 Operators are already delta-native

Every operator receives `{delta, Meta, Deltas}` and emits deltas, maintaining
its own internal state:

- `distinct` / `join` / `aggregate` / `order` / `antijoin` buffer deltas and
  emit ±1 diffs on barrier.
- `integrate` is a barrier-aligned delta passthrough — its accumulated `state`
  is updated but never emitted (`src/gdbsp_op_integrate.erl`).
- `differentiate` is accumulate-then-diff, i.e. identity on an already-delta
  stream (modulo first-epoch "emit full").
- `scc_internal` on `{integrate, #{scc_internal => true}}` is dead —
  `gdbsp_op_integrate:init(_Args)` ignores it.

Three independent pieces of evidence confirm the I/D wrapping is optional for
correctness (it is retained for performance):

1. The cross suite compiles all CTE/recursive queries with
   `incrementalize => false` (`test/gdbsp_cross_runner.erl:318`) and passes.
2. `ensure_matches_incremental: true` fixtures (`e2e_fixpoint_wiring.yaml`)
   assert `incr=false` ≡ `incr=true`.
3. The original `gg_c_dbsp_graph.erl:433-448` has a `simplify` pass to cancel
   adjacent I/D pairs — disabled, acknowledging redundancy.

### 2.2 Two orthogonal axes are conflated

- **Linear vs non-linear** (compile-time) — drives I/D wrapping.
- **Blocking vs pass-through** (runtime) — `aggregate`/`order`/`join`/`distinct`/
  `plus`/`integrate`/`differentiate`/`delay` buffer until barrier;
  `map`/`filter`/`neg`/`map_index`/`flat_map`/`rec` emit immediately.

The mode map tracks a third thing — "occupies the integrate role" — under the
misleading `full`/`delta` name.

### 2.3 The failure mechanics

Topo order for `e2e_fixpoint_downstream`:
`[1,4,5,2,6,7,8,9,10,11,15,3,12,13,14,16]`. `rec_p` (3) is processed last (the
rec edge is excluded from the sort). Two compounding problems:

1. `rec` is forced `full` (`src/gdbsp_compile_incremental.erl:21-28,176-179`),
   so base `rec_e` (2) is `full`.
2. `wrap_nonlinear`'s consumer-redirect skips `scc_id` nodes (`:218`), so the
   rec feedback stays on `distinct`'s `full` output rather than its
   `differentiate`.

Result: `plus` (10) sees `[full (rec_e), delta (join's differentiate)]` →
`merge_modes` crashes.

### 2.4 Classification is duplicated and inconsistent

`src/gdbsp_operator_spec.erl` exports `is_linear/1`, `needs_full_input/1`,
`produces_full_output/1` (documented in `docs/compilation.md` §6.1) — but
**nothing calls them**. `gdbsp_compile_incremental.erl` re-implements the
classification via hardcoded `process` clauses, and disagrees with the spec
(`rec`/`rec_output` are "linear" in the incrementalizer but
`gdbsp_operator_spec:is_linear` returns `false`).

---

## 3. Design

Reframe to two orthogonal axes with a single source of truth and non-crashing
bookkeeping:

1. **`rec`/`rec_output` = linear pass-through (delta).** Remove the
   `rec => full` pre-seed and the forced-`full` clause; fold `rec` into the
   linear clause next to `rec_output`. Runtime treats them as delta forwarders
   (`src/gdbsp_rec.erl` consolidates and forwards deltas, never a full Z-set).

2. **Drop the `scc_id` skip** in `wrap_nonlinear`'s consumer-redirect. It was
   added to "preserve full-mode feedback" under the wrong rec=full model. With
   rec=delta, the feedback edge and `rec_output`'s downstream must point at the
   `differentiate`. This makes `rec_p`'s inputs `[source Δ, differentiate Δ]` →
   delta, eliminating the mismatch at its root.

3. **Reconcile instead of crash.** Replace `merge_modes`'
   `error({mode_mismatch,…})` with converter insertion: for a linear multi-input
   node (`plus`), insert a `differentiate` before each `full` input so all inputs
   become `delta`. Defensive — after (1)+(2) the mismatch should not arise, but
   the pass must never crash on a valid graph.

4. **Single source of truth.** Drive classification from
   `gdbsp_operator_spec:is_linear/needs_full_input/produces_full_output`,
   deleting the hardcoded guard lists.

5. **Remove dead `scc_internal` flag** (`insert_integrates` emits plain
   `{integrate}`).

6. **Reframe docs** (`docs/compilation.md` §6): replace "full/delta mode" with
   the two axes and note operators are delta-native, I/D are structural (kept
   for performance).

---

## 4. File-by-file changes

### `src/gdbsp_operator_spec.erl`

- Add `rec` / `rec_output` to `is_linear/1`.

### `src/gdbsp_compile_incremental.erl`

- Remove `rec => full` from `InitialModeMap` (keep `integrate => full`).
- Split the `integrate; rec → full` clause: keep `integrate → full`, delete the
  `rec` part.
- Add `rec` to the linear clause alongside `rec_output`.
- Remove `not maps:is_key(scc_id, CMeta) andalso` from the `wrap_nonlinear`
  redirect.
- Replace `merge_modes`' `error({mode_mismatch,…})` with reconciliation
  (insert `differentiate` before `full` inputs, emit `delta`).
- Replace inline operator guard-lists with `gdbsp_operator_spec` classification.
- Drop `scc_internal => true` in `insert_integrates` → plain `{integrate}`.

### `docs/compilation.md` (§6)

- Replace "full/delta mode" with two axes: *linear vs non-linear* (drives I/D)
  and *blocking vs pass-through* (runtime emission). Note operators are
  delta-native; I/D are structural, kept for performance.

---

## 5. Verification gates

- `rebar3 ct` → target 640/640 pass (currently 639/1).
- Pinned guardrails must stay green: `incrementalize_filter` (2 nodes),
  `incrementalize_join` (≥5).
- Regression targets: `e2e_fixpoint_downstream` (the failure), all `fixpoint_*` /
  `circuit_*fixpoint*` fixtures, the 3 `ensure_matches_incremental` cases, and
  `gdbsp_rec_SUITE`.
- `RENDER_DOT=1` re-dump to confirm the `plus`/`distinct`/`rec`/`rec_output`
  region is delta-consistent with no mismatch.

---

## 6. Risks

- The `scc_id`-skip removal is the highest-risk change (a deliberate workaround
  for the old rec=full model); the fixpoint suite is the safety net.
- Spec-driven classification must preserve the exact wrap counts the compile
  tests assert.

## 7. Out of scope

- Not removing the incrementalization pass (wanted for performance).
- Not touching gg-runtime's checkpoint-wrappers seam.
