# gdbsp Fixpoint Test-Gap Plan

Date: 2026-08-28
Status: draft

---

## 1. Context

Adding a recursive-closure cross fixture exposed two latent bugs in the
fixpoint pipeline. Neither bug is fixed as of this writing; this plan
records the tests that must be added (and should currently **fail**) to
capture each bug, so the fixes can be driven and verified by tests.

The bugs are:

- **Bug A** — the transitive-closure output contains duplicate rows because
  `distinct` dedupes by raw term while the same logical tuple arrives with two
  different type wrappers.
- **Bug B** — a fixpoint output that feeds a non-pass-through downstream
  operator (`map`/`filter`/`aggregate`) bypasses that operator entirely.

---

## 2. Root causes

### 2.1 Bug A — `dynamic` row type in the compile-graph phase

Type inference is **correct** (`gdbsp_compile:infer` assigns `integer` to every
node of the closure). The `dynamic` type is introduced later, in
`gdbsp_compile_graph:get_input_row_type/2`
(`src/gdbsp_compile_graph.erl:867-877`), which hardcodes
`{struct, #{each_col => dynamic}}` for the runtime `row_type` of `map`/`filter`
operators and for the join's `merged_fields`.

Consequence: base edges flow as `{value, integer, N}` (from `source`), while
join-derived rows flow as `{value, {dynamic, integer}, N}`. `distinct`
(`src/gdbsp_op_distinct.erl:64-81`) compares raw terms, so `(f=1,t=3)` from the
source and `(f=1,t=3)` from the join are treated as distinct and both survive.
This yields a duplicate whenever a tuple is both a direct edge and transitively
reachable — any "diamond" (`1→2, 1→3, 2→3`) or cycle.

### 2.2 Bug B — fixpoint output bypasses downstream operators

`wire_output_consumers/4` (`src/gdbsp_circuit_proc.erl:236-257`), via
`build_output_reachability/3` (`:280`) and `dfs_output_pids/3` (`:292`), walks
from each `rec_output` node through the whole downstream graph to collect
`output` pids, and registers those as the Rec process's direct consumers. The
Rec (`gdbsp_rec:handle_coord` epoch_done, `:183-194`) then emits the raw
consolidated body delta directly to those collectors, while the intermediate
operators (`map_index → aggregate → unwrap`, `filter`, …) are never fed.

This is harmless when the only downstream of `fp.path` is a pass-through `plus`
alias (as in all pre-existing fixpoint fixtures), but wrong the moment a
transforming operator sits between the fixpoint output and the collector.

---

## 3. Tests to add

### 3.1 (already committed) `recursive_closure_views` cross fixture

`test/gdbsp_cross_SUITE_data/recursive_closure_views/` — transitive closure plus
three derived views (two aggregates and a filter over an aggregate), over both a
diamond `basic/` graph and a cyclic `cycle/` graph. This currently **fails** and
captures **both** bugs at integration level: every output (`reach_set`,
`reach_counts_set`, `reach_max_set`, `reach_big_set`) returns the raw closure
with the duplicated row (Bug A) and without any transformation (Bug B).

### 3.2 `recursive_closure_diamond` cross fixture — isolates Bug A

A minimal closure-only fixture (no downstream operator, so Bug B is inert) over
a diamond graph. This isolates Bug A: the direct `fp.path` output should be 3
rows but currently emits 4 (one row duplicated).

```
test/gdbsp_cross_SUITE_data/recursive_closure_diamond/
├── recursive_closure_diamond.sql
├── recursive_closure_diamond.gdbsp
└── basic/
    ├── edge.input.jsonl
    └── reach_set.expected.jsonl
```

`recursive_closure_diamond.sql`:

```sql
CREATE TABLE edge (f INTEGER, t INTEGER);

CREATE VIEW reach_set AS
WITH RECURSIVE reach(f, t) AS (
  SELECT f, t FROM edge
  UNION
  SELECT r.f, e.t FROM reach r JOIN edge e ON r.t = e.f
)
SELECT f, t FROM reach;
```

`recursive_closure_diamond.gdbsp`:

```
circuit tc_body(edge: e, path: p):
    path_ready := map(p, path_for_join)
    edge_ready := map(e, edge_for_join)
    joined := join(edge_ready, path_ready, on: ["key"])
    joined_proj := project(joined, ["f", "t"])
    path := distinct(plus(e, joined_proj))

edge_src := source("edge")
edge_src :: stream(struct("f": integer, "t": integer))

edge_for_join :: function((struct("f": integer, "t": integer)) -> struct("key": integer, "f": integer))
edge_for_join := function((row) -> struct("key": row.t, "f": row.f))
path_for_join :: function((struct("f": integer, "t": integer)) -> struct("key": integer, "t": integer))
path_for_join := function((row) -> struct("key": row.f, "t": row.t))

fp := fixpoint(tc_body(edge: edge_src, path: edge_src))
reach_set := fp.path
```

`basic/edge.input.jsonl`:

```
{"f": "integer", "t": "integer"}
{"f": "1", "t": "2"}
{"f": "1", "t": "3"}
{"f": "2", "t": "3"}
```

`basic/reach_set.expected.jsonl` (3 rows; currently 4):

```
{"f": "integer", "t": "integer"}
{"f": "1", "t": "2"}
{"f": "1", "t": "3"}
{"f": "2", "t": "3"}
```

### 3.3 `gdbsp_compile_SUITE` — captures Bug A's cause (`get_input_row_type`)

Two test functions in `test/gdbsp_compile_SUITE.erl` (register in `all/0`).
Both assert the compile-graph preserves the inferred concrete type instead of
`dynamic`.

```erlang
map_row_type_preserves_concrete_type(_Config) ->
    {ok, Prog} = parse_prog(
        "src := source(\"t\")\n"
        "src :: stream(struct(\"f\": i64, \"t\": i64))\n"
        "id := function((row) -> row)\n"
        "id :: function((struct(\"f\": i64, \"t\": i64)) -> struct(\"f\": i64, \"t\": i64))\n"
        "mapped := map(src, id)\n"),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    MapNode = hd([N || {_, N} <- maps:to_list(G#circuit_graph.nodes),
                       element(1, N#circuit_node.op) =:= map]),
    {map, #{row_type := {struct, #{<<"f">> := i64, <<"t">> := i64}, _}}} =
        MapNode#circuit_node.op,
    ok.

join_merged_fields_preserve_concrete_types(_Config) ->
    {ok, Prog} = parse_prog(
        "left := source(\"L\")\n"
        "left :: stream(struct(\"k\": i64, \"a\": i64))\n"
        "right := source(\"R\")\n"
        "right :: stream(struct(\"k\": i64, \"b\": i64))\n"
        "joined := join(left, right, on: [\"k\"])\n"),
    {ok, G} = gdbsp_compile:compile(Prog, #{incrementalize => false}),
    {_, JoinNode} = hd([{Id, N} || {Id, N} <- maps:to_list(G#circuit_graph.nodes),
                                    element(1, N#circuit_node.op) =:= join]),
    {join, #{merged_fields := #{<<"k">> := i64, <<"a">> := i64, <<"b">> := i64}}} =
        JoinNode#circuit_node.op,
    ok.
```

Both currently fail: `row_type`/`merged_fields` are `dynamic`, not `i64`.

### 3.4 `e2e_fixpoint_downstream` — isolates Bug B

A new `test/gdbsp_e2e_SUITE_data/e2e_fixpoint_downstream.yaml` over a **chain**
graph (so Bug A cannot trigger), with `aggregate` downstream of the fixpoint
output:

```yaml
- source: |
    circuit tc_body(edge: e, path: p):
        path_ready := map(p, path_for_join)
        edge_ready := map(e, edge_for_join)
        joined := join(edge_ready, path_ready, on: ["key"])
        joined_proj := project(joined, ["f", "t"])
        path := distinct(plus(e, joined_proj))

    edge_src := source("edge")
    edge_src :: stream(struct("f": integer, "t": integer))

    edge_for_join :: function((struct("f": integer, "t": integer)) -> struct("key": integer, "f": integer))
    edge_for_join := function((row) -> struct("key": row.t, "f": row.f))
    path_for_join :: function((struct("f": integer, "t": integer)) -> struct("key": integer, "t": integer))
    path_for_join := function((row) -> struct("key": row.f, "t": row.t))

    fp := fixpoint(tc_body(edge: edge_src, path: edge_src))

    cnt_fn :: aggregate_function((struct("f": integer, "t": integer)) -> struct("cnt": integer))
    cnt_fn := function((row) -> struct("cnt": std.agg_count()))
    reach_counts := aggregate(fp.path, cnt_fn, by: ["f"])

  input:
    - edge:
        - [1, {f: "1", t: "2"}]
        - [1, {f: "2", t: "3"}]
        - [1, {f: "3", t: "4"}]

  expected:
    - reach_counts:
        - [1, {f: "1", cnt: "3"}]
        - [1, {f: "2", cnt: "2"}]
        - [1, {f: "3", cnt: "1"}]
```

Expected `reach_counts` = per-source counts; with Bug B it returns the raw
closure `(f,t)`, so the `(f,cnt)` rows are reported as `missing`.

---

## 4. Verification gates

- Each of §3.2–3.4 must fail against the current implementation.
- After Bug A is fixed: §3.2, §3.3 pass; §3.1 reduces to failing only on the
  downstream-view counts (Bug B); §3.4 still fails.
- After Bug B is fixed: §3.1 and §3.4 pass fully.
- Full gate: `make test`.
