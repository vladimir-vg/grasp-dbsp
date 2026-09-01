# Changelog

All notable changes to Grasp DBSP are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-01

First release of the Grasp DBSP runtime and language.

### Added

- The `.gdbsp` language: source nodes with `stream(...)` type annotations,
  operator and node definitions, and `#` comments.
- Core operator set (`source`, `delay`, `integrate`, `differentiate`,
  `distinct`, `plus`, `neg`, `map`, `flat_map`, `join`, `aggregate`) and the
  extended set (`filter`, `project`, `antijoin`, `order`, `empty`).
- Function and aggregate-function declarations, with inline expression bodies
  (`std.agg_*`, arithmetic, comparisons, struct/array/map literals, dot access,
  subscripts/slices).
- Named, parameterised `circuit` definitions with macro expansion and nested
  node calls.
- `fixpoint` instantiation for recursive queries, with iterative convergence
  within a parent epoch.
- A static type system (scalars, `numeric(p,s)`, `string("UTF-8")`, `bytes`,
  `bits`, `enum`, `date`/`time`/`timestamp`/`interval`, `struct`, `array`,
  `map`, `optional`, type variables) with full type inference.
- Compilation pipeline: parse → type-check → compile to a circuit graph →
  incrementalize (automatic `integrate`/`differentiate` insertion around
  non-linear operators).
- The `gdbsp` CLI (packaged as a single escript) with `validate`, `run`
  (offline JSONL), and `serve` (HTTP) subcommands.
- JSONL wire format: `[weight, row]` deltas with typed value encoding, and an
  HTTP API (`/inputs`, `/outputs`, `/healthz`) for long-running deployment.
- Visual Studio Code syntax-highlighting extension (`editors/vscode`).
- SQL-to-GDBSP cross-fixtures validating equivalence against PostgreSQL
  (`test/gdbsp_cross_SUITE_data/`).
