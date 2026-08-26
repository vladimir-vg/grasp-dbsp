# gdbsp CLI — Implementation Plan

Date: 2026-08-26
Status: approved

---

## 1. Goal

A command-line front-end (`gdbsp`) for Grasp DBSP that:

- takes `.gdbsp` source, compiles and instantiates a circuit, and verifies
  correctness;
- feeds input streams from JSONL files (one per source table) or over HTTP;
- exposes output streams as JSONL to files, stdout, or HTTP.

See [cli.md](../cli.md) for the semantics this tool implements.

---

## 2. Locked decisions

| Topic | Decision |
|-------|----------|
| Packaging | `rebar3 escript` — binary `gdbsp`, `escript_main_app grasp_dbsp`, `main gdbsp_cli`. |
| HTTP server | cowboy 2.12.0. |
| Subcommands | `validate`, `run`, `serve` (below). |
| Sources | One or more `.gdbsp` files/dirs; parsed separately, programs merged; order-independent. |
| Output selection | Explicit `--output`. `validate` has none. |
| Epochs | Hardcoded unit-batch ingress coordinator; no external epoch control, no config. |
| Output JSONL | Header line (`name → type`) + plain canonical values (below). |
| Arg parsing | Hand-rolled, no new dependency. |
| Shared compile logic | Extracted into `src/gdbsp_loader.erl`; `gdbsp_e2e_SUITE` refactored to use it. |

---

## 3. CLI surface

```
gdbsp validate SOURCE...
gdbsp run      --output NAME=DEST... --input TABLE=FILE.jsonl... SOURCE...
gdbsp serve    --output NAME... [--listen IP:PORT] SOURCE...
```

- `validate` — parse+merge → compile+type-check → incrementalize →
  instantiate-and-stop. Output-agnostic. Exit 0/1.
- `run` — offline batch. `--output NAME=DEST` (repeatable, required; `DEST`
  is a file path or `-` for stdout). `--input TABLE=FILE.jsonl` per source.
- `serve` — long-running HTTP mode (see §5).

---

## 4. Output JSONL format

```
{"id":"i64","dept":"i64","total":"i64"}          # line 0 — schema header (columns_to_json)
[1, {"id":"1","dept":"10","total":"150"}]        # data — [weight, plain_row]
[-1, {"id":"1","dept":"10","total":"150"}]
```

- Line 0 = `gdbsp_value_json:columns_to_json/1`, emitted once per stream.
- Data lines = `[weight, row]` using canonical value encoding (ints-as-strings,
  dates-as-objects, bytes-base64) — symmetric with input, no `{value,...}`
  wrapper, no `{"type":...}` envelope.

---

## 5. HTTP API (`serve`)

| Endpoint | Method | Behaviour |
|----------|--------|-----------|
| `/inputs/{table}` | POST | JSONL body (`[weight,row]` per line) appended to the table's ingress buffer. 404 unknown table; 400 decode error with line index. |
| `/outputs/{name}` | GET | Chunked JSONL: header line then one line per delta, flushed per epoch. 404 unknown output. |
| `/healthz` | GET | 200 liveness. |

---

## 6. Architecture (new/changed modules)

| Module | Kind | Role |
|--------|------|------|
| `gdbsp_loader` | new | Source discovery/merge + `compile/3` → `{Plan, SourceTypeMap, OutputTypes}`. |
| `gdbsp_value_json` | fix | `encode_value`/`encode_field` must handle `{optional,_}`, `{dynamic,_}`, `{json,_}`, `{closure,...}` wrapped values (current crash reproduced). |
| `gdbsp_input_node` | new | Production source proc. |
| `gdbsp_output_sink` | new | Emits header + data lines; retains raw deltas (pull) + broadcasts lines (push). |
| `gdbsp_ingress` | new | Unit-batch epoch coordinator. |
| `gdbsp_runtime` | new | Thin orchestration (circuit_proc + nodes + sinks + ingress). |
| `gdbsp_http` | new | Cowboy router + handlers. |
| `gdbsp_cli` | new | `main/1` + pure `run/1`/`parse_args/1`. |

---

## 7. Implementation phases (TDD: RED → implement → GREEN → refactor)

### Phase 0 — build wiring
Add `cowboy` dep + escript profile to `rebar.config`.
Verify: `rebar3 compile`; baseline `rebar3 ct` green.

### Phase 1 — `gdbsp_loader` + e2e refactor
- `gdbsp_loader_SUITE`: `load_sources` (file/dir/multi-file merge/order
  independence/missing-file/parse-error), `compile` (happy path, unknown
  output, compile-error passthrough).
- Move `compile_to_plan`, `build_source_type_map`, `add_output_nodes`,
  `output_types_from_graph` from `gdbsp_e2e_SUITE` into `gdbsp_loader`.
- Verify: `rebar3 ct --suite=gdbsp_loader_SUITE,gdbsp_e2e_SUITE`.

### Phase 2 — encoder fix + `gdbsp_output_sink`
- `gdbsp_value_json_SUITE` (new): round-trip matrix over all types
  (int/string/f64/numeric/date/time/timestamp/interval/optional/dynamic/json/
  closure/array/map/bytes/bits/enum). First red case: `optional`
  (`function_clause` at `encode_value({optional,i64}, 5)`).
- Fix `encode_value`/`encode_field` wrapper handling.
- `gdbsp_output_sink_SUITE`: header line then data lines; raw-delta retention;
  subscriber broadcast; `epoch_done` notification; `await_epoch_done`.

### Phase 3 — `gdbsp_input_node`
- `gdbsp_input_node_SUITE`: wiring ack; forward `{delta,...}`; forward
  `epoch_done`.

### Phase 4 — `gdbsp_ingress`
- `gdbsp_ingress_SUITE`: unit batch (≤1 row/table/epoch); multi-table
  lockstep; empty batches for idle/exhausted tables; monotonic epoch;
  `exhausted`. Tested against stub input nodes.

### Phase 5 — `gdbsp_runtime` + offline CLI
- `gdbsp_cli_SUITE`: `parse_args` (all forms + errors/exit codes); `run`
  end-to-end via `gdbsp_cli:run/1` with temp `.gdbsp` + JSONL goldens
  (asserting header + data output).
- Implement `gdbsp_runtime`, `gdbsp_cli`.
- Verify: `rebar3 escriptize` + smoke `validate`/`run`.

### Phase 6 — `gdbsp_http` + `serve`
- `gdbsp_http_SUITE` (gun/httpc): POST input buffers; GET output streams
  header+data, flush-per-epoch; 404 unknown table/output; 400 bad line;
  `/healthz`.
- Implement cowboy handlers + `serve`.

### Phase 7 — regression + docs alignment
- Full `make test` green; smoke all three subcommands; confirm `cli.md`
  matches behaviour.

---

## 8. Verification gates

- Per phase: `rebar3 ct --suite=<X>`.
- Full: `make test`.
- Release: `rebar3 escriptize` + manual smoke of all three subcommands.
