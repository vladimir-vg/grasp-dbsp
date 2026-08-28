# gdbsp Date Day-Count — Implementation Plan

Date: 2026-08-28
Status: draft

---

## 1. Goal

Change the internal representation of the `date` type from the
`{year, month, day}` tuple to an `i32` day count (days since 2000-01-01),
matching PostgreSQL `DateADT` exactly. The wire format changes accordingly
from the `{"year","month","day"}` object to `{"days_since_2000": "<int>"}`.

This makes `date ↔ PostgreSQL date` a perfect bi-directional mapping and
aligns the DBSP type with the source model (see
[type-system.md](../type-system.md) §3 and
[sql-type-mapping.md](../sql-type-mapping.md)).

The `interval` type is documented as storing `months` and `days` as `i32`
(matching PostgreSQL `interval`); this is a **spec-only** change with no code
impact because Erlang integers are arbitrary precision.

---

## 2. Locked decisions

| Topic | Decision |
|-------|----------|
| Internal repr | `i32` days since 2000-01-01 (`2000-01-01` = `0`) |
| Wire format | `{"days_since_2000": "<int>"}` — single string component, mirroring `timestamp`'s `{"epoch_microseconds": …}` |
| Range | 4713 BC .. 5874897 AD (PostgreSQL `date` range) |
| Special values | `epoch` = `-10957` (1970-01-01); `±infinity` = the `i32` endpoints (spec-only, not encoded today) |
| `interval` | `months`/`days` documented as `i32`; no code change |
| Backward compatibility | None — the `{"year","month","day"}` object is removed, not kept as a fallback |

---

## 3. Affected code

| File | Location | Change |
|------|----------|--------|
| `src/gdbsp_value_json.erl` | `encode_value(date, {Y, M, D})` (~203-204) | encode `date` as `#{<<"days_since_2000">> => i2b(Days)}` |
| `src/gdbsp_value_json.erl` | `decode_value(date, #{<<"year">> …})` (~308-310) | decode `#{<<"days_since_2000">> := Days}` → `{ok, b2i(Days)}` |
| `src/gdbsp_expr.erl` | `encode_value(date, {Y, M, D})` (~104-107) | same day-count object for typed literals |
| `src/gdbsp_expr.erl` | `decode_value(date, #{<<"value">> := #{…}})` (~334-335) | decode `days_since_2000` |
| `src/gdbsp_temporal.erl` | module comment | note `interval` `months`/`days` are `i32` |

No change is needed to comparison code: `date` comparison already flows
through the generic `std_eq` / `std_lt` / … fallback in `gdbsp_std.erl`,
which compares raw terms; a single integer compares identically to the old
tuple (term order on `{Y,M,D}` and on `Days` coincide for valid dates).

---

## 4. Affected tests

| File | Change |
|------|--------|
| `test/gdbsp_value_json_SUITE.erl:77` | `value_rt(date, {2020, 1, 2})` → `value_rt(date, 7306)` |
| `test/gdbsp_e2e_SUITE_data/e2e_temporal.yaml:8,12` | `{year: "2026", month: "7", day: "28"}` → `{days_since_2000: "9705"}` |
| `test/gdbsp_cross_runner.erl` | `sql_val_to_native(date, …)` / `parse_date_string/1` produce a day count from SQLite `"YYYY-MM-DD"` text via `calendar:date_to_gregorian_days/1` |

Day-count conversions for the fixtures above:

| Date | Days since 2000-01-01 |
|------|------------------------|
| 2020-01-02 | 7306 |
| 2026-06-18 | 9665 |
| 2026-07-28 | 9705 |
| 1970-01-01 (`epoch`) | -10957 |

The cross-runner conversion is the only place calendar math is needed:
`Days = calendar:date_to_gregorian_days({Y, M, D}) - calendar:date_to_gregorian_days({2000, 1, 1})`.
Erlang's `calendar` module is limited to years 0–9999, which is narrower than
the DBSP/PG range; this only affects the SQLite test harness (test dates are
within range), not the main code path, which stores the day count directly
with no calendar conversion.

---

## 5. Phases (TDD: RED → implement → GREEN → refactor)

### Phase 1 — `gdbsp_value_json`

- Update `gdbsp_value_json_SUITE.erl` `scalar_roundtrips` to expect the
  day-count wire format; run `rebar3 ct --suite=gdbsp_value_json_SUITE` to
  see the failure.
- Update `encode_value/2` / `decode_value/2` for `date`.
- Verify: `rebar3 ct --suite=gdbsp_value_json_SUITE`.

### Phase 2 — `gdbsp_expr`

- Update `gdbsp_expr.erl` `encode_value`/`decode_value` for `date`.
- Add/adjust any `gdbsp_compile_expr_SUITE` cases that embed date typed
  literals, if present.
- Verify: `rebar3 ct --suite=gdbsp_compile_expr_SUITE`.

### Phase 3 — e2e + cross runner

- Update `e2e_temporal.yaml` date fixture to `days_since_2000`.
- Update `gdbsp_cross_runner.erl` `parse_date_string/1` and the `date`
  clause of `sql_val_to_native/2` to emit the day count.
- Verify: `rebar3 ct --suite=gdbsp_e2e_SUITE,gdbsp_cross_SUITE`.

---

## 6. Verification gates

- Per phase: `rebar3 ct --suite=<X>`.
- Full: `make test`.
- Grep the tree for any remaining `{year, month, day}` / `"year"` date
  construction sites to confirm no stragglers.
