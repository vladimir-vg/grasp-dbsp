# Grasp DBSP

A [Database Stream Processor (DBSP)](docs/20_dbsp-budiu.pdf) runtime and a
small, declarative language for **incremental, streaming relational queries**,
implemented in Erlang.

You write queries in `.gdbsp` source, compile them into a DBSP *circuit*
(a directed graph of stream operators over Z-sets), and run them offline over
JSONL or as a long-lived HTTP service. Changes stream through the circuit as
weighted *deltas* (`+1` insert, `-1` retract), so results are maintained
incrementally rather than recomputed.

## Features

- **Relational operators** — `join`, `aggregate`, `filter`, `project`,
  `antijoin`, `distinct`, `order`, and more.
- **Recursive queries** — `fixpoint` instantiation maps `WITH RECURSIVE`
  CTEs to iterative circuits.
- **Static types** — typed streams and functions with full type inference,
  using `integer`, `i64`, `string("UTF-8")`, `struct`, `map`, `array`, and
  `enum`.
- **Concurrent by construction** — every DBSP operator (including those
  inside `fixpoint` circuits) runs as its own Erlang process, so multicore
  machines are utilized with no extra configuration.
- **Three ways to run it** — `validate`, offline `run`, and an HTTP `serve`
  mode — from a single `gdbsp` escript.

## Quick start

Prerequisites: [Erlang/OTP](https://www.erlang.org/) and
[rebar3](https://rebar3.org/).

```bash
rebar3 escriptize            # build the single-binary CLI
_build/default/bin/gdbsp --help
```

Three subcommands:

| Command | Purpose |
|---------|---------|
| `gdbsp validate SOURCE...` | Parse, type-check, incrementalize, and instantiate-and-stop the circuit. |
| `gdbsp run --output NAME=DEST --input TABLE=FILE.jsonl SOURCE...` | Feed JSONL inputs; write JSONL outputs. |
| `gdbsp serve --output NAME... [--listen IP:PORT] SOURCE...` | Expose inputs/outputs over HTTP. |

## Example: SQL, translated to GDBSP

If you know SQL, the `.gdbsp` language reads as a direct transliteration. Start
from a couple of tables:

```sql
-- Employees and the departments they belong to. manager_id points at
-- the employee's manager. A manager_id of 0 means the employee is
-- top-level (no manager).
CREATE TABLE employees (
    emp_id     INTEGER,
    name       TEXT,
    dept_id    INTEGER,
    manager_id INTEGER,
    salary     INTEGER
);

CREATE TABLE departments (
    dept_id   INTEGER,
    dept_name TEXT
);
```

Here is the same schema, plus a rollup view, in GDBSP. Sources are the only
operators that need an explicit type annotation; the compiler infers the types
of every downstream node.

```gdbsp
# CREATE TABLE employees / departments
emp := source("employees")
emp :: stream(struct("emp_id": integer, "name": string("UTF-8"), "dept_id": integer, "manager_id": integer, "salary": integer))

dept := source("departments")
dept :: stream(struct("dept_id": integer, "dept_name": string("UTF-8")))

# FROM employees e JOIN departments d ON d.dept_id = e.dept_id
emp_dept := join(emp, dept, on: ["dept_id"])

# MAX(e.salary) and COUNT(*), grouped by dept_id, dept_name
stats :: aggregate_function((struct("dept_id": integer, "emp_id": integer, "name": string("UTF-8"), "manager_id": integer, "salary": integer, "dept_name": string("UTF-8"))) -> struct("max_salary": integer, "emp_count": integer))
stats := function((row) -> struct("max_salary": std.agg_max_integer(row.salary), "emp_count": std.agg_count()))

dept_stats_set := aggregate(emp_dept, stats, by: ["dept_id", "dept_name"])
```

This is the GDBSP equivalent of:

```sql
-- Department rollup: highest salary and headcount per department.
CREATE VIEW dept_stats_set AS
SELECT
    d.dept_id,
    d.dept_name,
    MAX(e.salary) AS max_salary,
    COUNT(*)       AS emp_count
FROM employees e
JOIN departments d ON d.dept_id = e.dept_id
GROUP BY d.dept_id, d.dept_name;
```

Feed it JSONL — one line per delta, a two-element `[weight, row]` array, with
values in their string encoding:

```jsonl
[1, {"emp_id": "1", "name": "Alice", "dept_id": "10", "manager_id": "0", "salary": "200000"}]
[1, {"emp_id": "2", "name": "Bob",   "dept_id": "10", "manager_id": "1", "salary": "120000"}]
[1, {"emp_id": "5", "name": "Eve",   "dept_id": "20", "manager_id": "1", "salary": "100000"}]
```

```jsonl
[1, {"dept_id": "10", "dept_name": "Engineering"}]
[1, {"dept_id": "20", "dept_name": "Sales"}]
```

```bash
gdbsp run \
  --input employees=employees.jsonl \
  --input departments=departments.jsonl \
  --output dept_stats_set=- \
  employee_org.gdbsp
```

Output is JSONL: a header line carrying the schema, then one delta per line.

```jsonl
{"dept_id":"integer","dept_name":{"string":{"encoding":"UTF-8"}},"emp_count":"integer","max_salary":"integer"}
[1,{"dept_id":"10","dept_name":"Engineering","emp_count":"1","max_salary":"200000"}]
[-1,{"dept_id":"10","dept_name":"Engineering","emp_count":"1","max_salary":"200000"}]
[1,{"dept_id":"10","dept_name":"Engineering","emp_count":"2","max_salary":"200000"}]
[1,{"dept_id":"20","dept_name":"Sales","emp_count":"1","max_salary":"100000"}]
```

Because evaluation is incremental, the aggregate emits a *delta stream*: as Bob
arrives, the previous `Engineering` total is retracted (`-1`) and the new one
inserted (`+1`). The final result is the net of all weights — `Engineering`
(`emp_count = 2`, `max_salary = 200000`) and `Sales` (`emp_count = 1`,
`max_salary = 100000`).

### Recursive queries

Recursive CTEs map to a named `circuit` plus a `fixpoint` instantiation:

```sql
-- Who reports to whom, transitively. A row (sub, mgr) means `sub` is a
-- direct or indirect report of `mgr`. Top-level employees (manager_id =
-- 0) never appear as a subordinate.
CREATE VIEW report_chain_set AS
WITH RECURSIVE chain(sub, mgr) AS (
    SELECT emp_id AS sub, manager_id AS mgr
    FROM employees
    WHERE manager_id <> 0
    UNION
    SELECT c.sub, e.manager_id
    FROM chain c
    JOIN employees e ON e.emp_id = c.mgr
    WHERE e.manager_id <> 0
)
SELECT sub, mgr FROM chain;
```

```gdbsp
has_mgr :: function((struct("emp_id": integer, "name": string("UTF-8"), "dept_id": integer, "manager_id": integer, "salary": integer)) -> enum("false","true"))
has_mgr := function((row) -> row.manager_id != 0)

to_edge :: function((struct("emp_id": integer, "name": string("UTF-8"), "dept_id": integer, "manager_id": integer, "salary": integer)) -> struct("sub": integer, "mgr": integer))
to_edge := function((row) -> struct("sub": row.emp_id, "mgr": row.manager_id))

with_mgr := filter(emp, has_mgr)
direct_reports := map(with_mgr, to_edge)

circuit chain_body(direct: e, chain: p):
    p_ready := map(p, p_for_join)
    e_ready := map(e, e_for_join)
    joined := join(e_ready, p_ready, on: ["key"])
    joined_proj := project(joined, ["sub", "mgr"])
    chain := distinct(plus(e, joined_proj))

e_for_join :: function((struct("sub": integer, "mgr": integer)) -> struct("key": integer, "sub": integer))
e_for_join := function((row) -> struct("key": row.mgr, "sub": row.sub))

p_for_join :: function((struct("sub": integer, "mgr": integer)) -> struct("key": integer, "mgr": integer))
p_for_join := function((row) -> struct("key": row.sub, "mgr": row.mgr))

fp := fixpoint(chain_body(direct: direct_reports, chain: empty()))
report_chain_set := fp.chain
```

The `circuit` iterates `chain_body` to convergence; `fp.chain` exposes the
transitive closure.

## Documentation

The docs live in [`docs/`](docs/) and serve as the language and runtime manual:

- [grasp-dbsp.md](docs/grasp-dbsp.md) — the language: declarations, operators, functions, examples.
- [syntax.md](docs/syntax.md) — lexical and syntactic specification.
- [type-system.md](docs/type-system.md) / [type-inference.md](docs/type-inference.md) — types and how they flow.
- [stdlib.md](docs/stdlib.md) — function and aggregate registry, value encoding.
- [runtime-model.md](docs/runtime-model.md) — Z-sets, epochs, deltas, barriers.
- [compilation.md](docs/compilation.md) — how `.gdbsp` compiles to a deployable circuit.
- [circuits.md](docs/circuits.md) / [fixpoint-circuits.md](docs/fixpoint-circuits.md) — named circuits and fixpoint instantiation.
- [cli.md](docs/cli.md) — the `gdbsp` command-line tool in detail.

More runnable examples live under
[`test/gdbsp_cross_SUITE_data/`](test/gdbsp_cross_SUITE_data/) — each fixture
pairs a `.sql` query with an equivalent `.gdbsp` program and expected output.

## Editor support

A Visual Studio Code syntax-highlighting extension ships in
[`editors/vscode/`](editors/vscode/).

## Development

```bash
make test     # run the Common Test suite (renders circuit graphs via Graphviz)
```

## Limitations

- **Integer literals are `integer`** — numeric literals in expressions are
  typed `integer` (not `i64`/`u64`/…), so combining a literal with a
  fixed-width field — e.g. `row.x + 1` where `x` is `i64` — is a type error.
- **Narrow test coverage** — the end-to-end SQL fixtures really exercise only
  `integer` and `string("UTF-8")`; other types have shallow round-trip
  coverage only.
- **Standard library is a draft** — `std.*` has comprehensive type
  signatures, but only a small subset has runtime implementations and tests.
- **In-memory only** — all state is held in RAM with no spill-to-disk or
  persistence, so it is not suited to datasets larger than memory.
- **Raw delta output** — `run` and `serve` emit a stream of `+1`/`-1`
  retractions rather than a materialized final table; consumers must sum
  weights to obtain the current result.

## License

[Apache-2.0](LICENSE). Contributions are governed by the
[Code of Merit](CODE_OF_MERIT.md).
