# Grasp DBSP — CLI

Date: 2026-08-26
Status: final

---

## 1. Overview

`gdbsp` is the command-line front-end for Grasp DBSP. It takes `.gdbsp`
source, compiles it, instantiates a running circuit, and drives it: inputs
may be fed from JSONL files or over HTTP, and outputs may be written to files
or stdout, or streamed over HTTP.

It is packaged as a single escript:

```
rebar3 escriptize
_build/default/bin/gdbsp ...
```

Three subcommands:

| Subcommand | Purpose |
|------------|---------|
| `validate` | Compile, type-check, incrementalize, and instantiate-and-stop the circuit. |
| `run`      | Feed inputs from JSONL files; write outputs to files or stdout. |
| `serve`    | Expose input and output streams over HTTP. |

---

## 2. Source input

Every subcommand takes one or more `SOURCE` arguments. Each `SOURCE` is a
`.gdbsp` file or a directory; directories are scanned recursively for
`*.gdbsp` files.

```
gdbsp validate a.gdbsp
gdbsp validate src/circuits/          # every *.gdbsp under this tree
gdbsp run --output ... a.gdbsp lib/more.gdbsp
```

When several files are given, each is parsed separately and the resulting
programs are **concatenated** into a single program. The order of files and
of declarations within them is irrelevant: Grasp DBSP collects all
declarations before resolving names. A declaration may repeat identically
(a no-op); a conflicting repeat is an error (see
[grasp-dbsp.md](grasp-dbsp.md)).

---

## 3. Output selection

`.gdbsp` source has no output nodes — which nodes serve as outputs is chosen
externally (see [grasp-dbsp.md](grasp-dbsp.md)). The CLI selects outputs per
subcommand:

- `run` — `--output NAME=DEST` writes stream `NAME` to `DEST`.
- `serve` — `--output NAME` exposes stream `NAME` at `GET /outputs/{name}`.
- `validate` — no output selection; it validates the whole circuit.

---

## 4. Subcommands

### 4.1 validate

```
gdbsp validate SOURCE...
```

Loads and concatenates the sources, then runs the full compilation pipeline —
parse, type-check, compile to a circuit graph, incrementalize — and finally
**instantiates and tears down** the circuit. Instantiation exercises the
deploy and wiring path, catching errors that only appear at spawn time.

Validation is output-agnostic: the whole circuit is checked, so any node may
later serve as an output.

Exit code `0` on success; `1` with a readable error on stderr otherwise.

### 4.2 run

```
gdbsp run --output NAME=DEST... --input TABLE=FILE.jsonl... SOURCE...
```

Offline batch mode.

- `--input TABLE=FILE.jsonl` binds one input stream: rows from `FILE.jsonl`
  are fed to the source table `TABLE`. Repeat for each source table.
- `--output NAME=DEST` (repeatable) is **required** and explicit. `DEST` is a
  file path, or `-` for stdout. Each listed output stream is emitted as JSONL
  (see §5), flushed once per epoch. Nodes not listed produce no output.

The circuit runs until every input stream is exhausted and all epochs have
drained, then exits.

### 4.3 serve

```
gdbsp serve --output NAME... [--listen IP:PORT] SOURCE...
```

Long-running HTTP mode.

- `--output NAME` (repeatable) exposes stream `NAME` at `GET /outputs/{name}`.
- `--listen IP:PORT` sets the bind address; the default is `127.0.0.1:8080`.

Inputs are delivered over HTTP (see §7); `serve` never writes to files or
stdout. The process stays running until interrupted.

---

## 5. JSONL wire format

Input and output streams use the same JSONL encoding: one line per delta,
a two-element array `[weight, row]`:

```json
[1, {"id": 1, "val": "100"}]
[-1, {"id": 1, "val": "100"}]
```

`weight` is a signed integer (`+1` inserts, `-1` retracts; see
[runtime-model.md](runtime-model.md) §1). `row` is a JSON object whose values
use the typed value encoding of [stdlib.md](stdlib.md) §2 (integers as
strings, `date` as a day count, `bytes` as base64, and so on).

Input rows are decoded against the source node's `stream(...)` type; output
rows are encoded from the output node's type.

Input JSONL carries **no epoch information** — only weights and rows. Epochs
are decided by the runtime (§6).

---

## 6. Epoch semantics

Epochs are owned entirely by the runtime; there is no external epoch control
and no configuration. An ingress coordinator holds a global epoch counter and
one row buffer per input table.

The policy is a hardcoded **unit batch**: each epoch consumes at most one row
from each table. An epoch is committed — its rows are delivered to the sources
and an `epoch_done` barrier is injected into every source — whenever at least
one table has a pending row; tables with no pending row contribute an empty
batch. This keeps multi-input circuits advancing in lockstep, consistent with
the barrier model in [runtime-model.md](runtime-model.md) §3.

In `run`, the coordinator iterates until all input files are exhausted; in
`serve`, it drains continuously as rows arrive.

---

## 7. HTTP API (`serve`)

| Endpoint | Method | Behaviour |
|----------|--------|-----------|
| `/inputs/{table}` | POST | JSONL body (`[weight,row]` per line); rows are appended to the table's buffer. `404` for an unknown table; `400` on a decode error (with the offending line index). |
| `/outputs/{name}` | GET | Chunked JSONL long-poll: one line per emitted delta, flushed once per epoch; the connection stays open. `404` for an unknown output. |
| `/healthz` | GET | `200` liveness probe. |

Each connected `/outputs/{name}` subscriber receives every emitted delta for
that stream, so multiple clients can tail the same output concurrently.

---

## 8. Errors and exit codes

- Compilation errors — `{compile_error, ...}`, `{fixpoint_error, ...}` — are
  normalized and printed to stderr with a class and message; `validate` and
  `run` exit `1`.
- In `run`, a per-row decode failure is reported with the file and line.
- Unknown `--output` or `--input` names are rejected before the circuit is
  instantiated.
