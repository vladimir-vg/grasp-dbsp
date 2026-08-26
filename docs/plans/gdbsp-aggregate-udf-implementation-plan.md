# aggregate as user-defined row→struct functions — Implementation Plan

Date: 2026-08-26
Status: approved

---

## 1. Goal

Replace the `aggregate(node, fn, by: [...], value: ..., as: ...)` builtin with
`aggregate(node, fn, by: [...])` where `fn` is a user-defined
`aggregate_function` typespec plus a `:= function((row) -> struct(...))` body
whose struct fields are `std.agg_*` calls. This lands the implementation that
commit `a5d825fb` left as docs+tests only (22 failing tests at HEAD).

---

## 2. Locked decisions

| Topic | Decision |
|-------|----------|
| Increments | Four separate, each compiling and non-regressive: (a) typespec+registry, (b) lowering+structural checks, (c) type inference+graph build, (d) runtime+stdlib. |
| Result bodies | Arbitrary scalar expressions over `std.agg_*` results (slot + result-expr model). |
| min/max | Weight-aware (multiset accumulator); covered by new retraction tests. |
| `std.agg_*` in scalar bodies | Compile error (`type_conflict`). |
| Runtime slot-arg failure | Hard failure — an unexpected `{error,_}`/`drop_row` is a type-checker bug; crash loudly, never skip a row. |
| New retraction tests | Dedicated `test/gdbsp_e2e_SUITE_data/e2e_aggregate_retractions.yaml`. |
| Obsolete paths | Removed, not kept for compatibility (`value:`/`as:`, `agg_col`, `resolve_agg_fn_name`, `std.agg_avg_i64/_f64/_numeric`). |

---

## 3. Target semantics

```
sum_sal :: aggregate_function((struct("dept": i64, "sal": i64)) -> struct("total": i64))
sum_sal := function((row) -> struct("total": std.agg_sum_i64(row.sal)))
agg := aggregate(src, sum_sal, by: ["dept"])
```

- `by:` fields are prepended to the returned struct; a by/result field-name
  clash is a compile error (`type_conflict`).
- The body must return a struct (`type_conflict` otherwise); ≥1 `std.agg_*`
  call (`no_aggregate_call`); no nesting (`nested_aggregate_call`); the row
  param may appear only inside an aggregate call's argument
  (`row_ref_outside_aggregate`).
- Empty groups drop the row (existing behavior).
- `std.agg_avg_integer` = `floor(sum/count)`, drops empty groups.

---

## 4. Design: the aggregate plan

The body compiles once (at `check_all_fns`) into a self-contained plan term,
stored in `AggReg`, consumed unchanged by the runtime op:

```erlang
plan := #{
  slots        => [slot()],     % ordered, left-to-right from the body
  result_expr  => expr(),       % body with each {agg,...} replaced by {value, SlotT, {slot,N}}
  result_type  => {struct, Fields, exact},
  row_arg      => binary(),     % fn's row param name
  kwarg_order  => #{...}
}
slot := #{
  name        => binary(),      % "std.agg_sum_i64"
  impl        => {{M,IF,2},{M,UF,3},{M,RF,1}},
  arg         => expr() | none, % arg expr over `row`; none for std.agg_count()
  result_type => gdbsp_column_type()
}
```

- Each `{agg, Name, PosArgs, KwArgs}` occurrence becomes one slot; `arg` is the
  lowered argument expr (e.g. `struct_get(row, sal)` or `*(struct_get(row,x),2)`).
- `result_expr` is the whole body with agg nodes replaced by slot placeholders,
  so **arbitrary expressions** over slot results are free (the body is just a
  normal expr tree evaluated by `gdbsp_eval`).
- Slot arg eval returns `{ok, {value, _, V}}`; the interpreter unwraps to raw
  `V` before calling `init`/`update` (matching the existing `agg_op_*` contract).

---

## 5. New error classes

| class | source | test |
|-------|--------|------|
| `no_aggregate_call` | body has no `std.agg_*` | `type_infer_aggregate_udf_6` |
| `nested_aggregate_call` | agg inside agg arg | `type_infer_aggregate_udf_7` |
| `row_ref_outside_aggregate` | row param outside agg arg | `type_infer_aggregate_udf_8` |
| `type_conflict` | non-struct body / by-result clash | `type_infer_aggregate_udf_3/4` |
| `missing_typespec` | aggregate fn referenced with no body | `type_infer_aggregate_udf_5`, `type_infer_24` |

These surface through `gdbsp_compile:infer` (`{inline_fn_errors, ...}`) for
body errors and `{error, #{class => ...}}` for type-inference errors.

---

## 6. Cross-cutting signature changes (in Phase A)

| Function | Old return | New return |
|---|---|---|
| `gdbsp_compile_expr:check_all_fns/2` | `{ok, FnReg, FnParams, Warn}` | `{ok, FnReg, AggReg, FnParams, Warn}` |
| `gdbsp_compile:infer/1` | `{ok, Lowered, FnReg, FnParams}` | `{ok, Lowered, FnReg, AggReg, FnParams}` |
| `gdbsp_compile_graph:build_from_lowered/5` | 5 args | 6 args (+AggReg) |
| `gdbsp_type_infer:infer_lowered/5` | 5 args | 6 args (+AggReg) |

Call sites updated in Phase A: `gdbsp_compile_expr_SUITE.erl:266,350`,
`gdbsp_type_infer_SUITE.erl:148,179`, `gdbsp_e2e_SUITE.erl:742`,
`gdbsp_graphviz_SUITE.erl:290`, `gdbsp_compile.erl:40,71`.

---

## 7. Implementation phases (each compiles + non-regressive)

### Phase A — typespec recognition + registry split

- `gdbsp_compile_expr.erl`: `find_fn_typespec/2` matches `function` **and**
  `aggregate_function`; `check_all_fns` accumulates `FnReg` (scalar) and
  `AggReg` (aggregate); cross-kind duplicate-name check; thin
  `check_single_agg_fn` stub (delegates to Phase B's `gdbsp_agg_plan:compile`).
- `gdbsp_compile.erl`: thread `AggReg` through `compile_inline_fns`/`infer`.
- Signature/param threading + the 5 test call sites above.
- Gate: `rebar3 ct` — non-aggregate green; aggregate tests still red.

### Phase B — lowering + structural checks + plan builder

- `gdbsp_compile_expr.erl`: lowering context (`agg_names` set + allow-agg flag);
  inside an aggregate body, `{call, <<"std.agg_*">>, ...}` → `{agg, Name, ...}`
  (detected via stdlib `aggregate_function` membership, not name prefix).
  **Scalar** bodies reject `std.agg_*` with `type_conflict`.
- `gdbsp_type_infer_expr.erl`: `infer_expr({agg, ...}, ...)` resolves via
  `resolve_call`, yielding slot result types.
- New `src/gdbsp_agg_plan.erl`: `compile(FnDef, TS, StdlibMap)` → plan,
  enforcing §3/§5 structural checks.
- Gate: compiles; new error classes reachable through Phase C.

### Phase C — type inference + graph build

- `gdbsp_type_infer.erl`: rewrite `infer_lnode_type(aggregate, ...)` — drop
  `value:`/`as:`; look up `AggReg` (absent → `missing_typespec`); require struct
  return (`type_conflict`); prepend `by:` fields; by/result clash
  (`type_conflict`); output `{struct, ByFields ++ ResultFields, exact}`.
- `gdbsp_compile_graph.erl`: `build_aggregate_graph_lowered` emits
  `map_index#{key_vars, agg_row}` → `{aggregate, Plan}` →
  `map#{kind => agg_unwrap, group_by, row_type}`; delete
  `resolve_agg_fn_name`; `compute_schema_lowered` aggregate branch →
  `ByFields ++ ResultFieldNames`.
- `gdbsp_circuit.erl`: `op_args({aggregate, Plan}, _) when is_map(Plan) -> Plan`.
- Gate: **12 tests green** (`type_infer_11/12/24`, `type_infer_aggregate_udf_1..8`,
  `gdbsp_compile_SUITE:aggregate`).

### Phase D — runtime interpreter + stdlib + weight-aware min/max + tests

- `gdbsp_op_map_index.erl`: replace `agg_col` with `agg_row` (identity
  extractor → whole row); remove `agg_col`.
- `gdbsp_op_aggregate.erl`: plan interpreter — per key, per slot, fold rows
  evaluating `slot.arg`; unwrap to raw `V`; compute slot results; any `drop` →
  drop group; substitute slot results into `result_expr`, eval, emit
  `{1, {Key, ResultMap}}`. Slot-arg eval failures crash loudly (§2).
- `gdbsp_op_map.erl`: `agg_unwrap` merges by-fields (from key) with the result
  struct via `map_to_struct(Merged, row_type)`; drop `output_var`.
- `gdbsp_agg.erl`: replace `agg_op_min`/`agg_op_max` with weight-aware multiset
  accumulators: `init(V,W) -> #{V => W}`; `update` adds weight, drops zero;
  `result(Acc)` = `min`/`max` over `[{V,W} || W > 0]`, else `drop`. Add
  `agg_op_avg_integer` (floor sum/count, drop on empty).
- `gdbsp_builtins.erl:704` + `priv/stdlib.gdbsp:348`: add `std.agg_avg_integer`;
  remove `std.agg_avg_i64/_f64/_numeric`.
- Gate: **10 tests green** (e2e aggregate family); full `make test` green.

---

## 8. New tests

- `test/gdbsp_e2e_SUITE_data/e2e_aggregate_retractions.yaml`:
  - max: retract the current max → correct recompute.
  - min: symmetric.
  - duplicate value: two rows share the max, retract one → max still present.
  - empty group: retract all rows for a key → key disappears.
- `gdbsp_op_aggregate_SUITE.erl`: converted to the plan contract (struct rows,
  minimal single-slot sum plan) + min/max retraction cases.

---

## 9. Verification gates

- Per phase: `rebar3 ct` (targeted suites where noted).
- Phase C/D: full `make test` (RENDER_DOT=1) — expect 509 + 22 green at the end.

## 10. Out of scope / notes

- Untouched: uncommitted `rebar.config`/`rebar.lock` (cowboy/escript) and
  `docs/20_dbsp-budiu.pdf`.
- min/max correctness for *negative-weight* values relies on `W > 0` predicate
  (values with non-positive net weight are treated absent).
- min/max with duplicate weights is a multiset (multiplicity irrelevant to
  min/max) — correct by construction.
