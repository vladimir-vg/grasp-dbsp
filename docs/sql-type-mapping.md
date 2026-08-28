# Grasp DBSP — SQL Type Mapping

Date: 2026-08-28
Status: draft

---

## 1. Purpose

Maps each Grasp DBSP type to its PostgreSQL and SQLite storage type.
Types whose mapping is exact in both directions appear in §2; everything
else appears in §3 with notes for both directions.

Notation: `→` = forward (DBSP → SQL), `←` = reverse (SQL → DBSP),
`—` = no exact type / no SQL equivalent. See [type-system.md](type-system.md)
for the type definitions.

---

## 2. Exact Bi-directional Mappings

| DBSP type | PostgreSQL | SQLite |
|-----------|------------|--------|
| `i16` | `smallint` | — |
| `i32` | `integer` | — |
| `i64` | `bigint` | `INTEGER` |
| `f32` | `real` | — |
| `f64` | `double precision` | `REAL` |
| `numeric` | `numeric` | — |
| `numeric(p,s)` | `numeric(p,s)` | — |
| `string("UTF-8")` | `text` | `TEXT` |
| `bytes` | `bytea` | `BLOB` |
| `bits` | `bit varying` | — |
| `bits(n)` | `bit(n)` | — |
| `date` | `date` | — |
| `time` | `time` | — |
| `timestamp` | `timestamp` | — |
| `timestamp_with_timezone` | `timestamptz` | — |
| `interval` | `interval` | — |
| `json` | `jsonb` | — |
| `enum("false","true")` | `boolean` | `INTEGER` (0/1) |
| `array(T)` | `T[]` | — |

`—` in a cell means no exact bi-directional type exists in that dialect;
the corresponding non-exact mapping is in §3.

---

## 3. Non-exact Mappings

A type appears here when the value domain of the SQL type does not
round-trip cleanly. The `→` column states whether the forward direction
(DBSP → SQL) is lossless; the `←` column states what is lost in the
reverse direction (SQL → DBSP).

### 3.1 PostgreSQL

| DBSP type | Target | → forward | ← reverse |
|-----------|--------|-----------|-----------|
| `i8` | `smallint` | lossless | lossy (range −128…127) |
| `u8` | `smallint` | lossless | lossy (negatives / >255) |
| `u16` | `integer` | lossless | lossy (negatives / >65535) |
| `u32` | `bigint` | lossless | lossy (negatives / >2³²−1) |
| `u64` | `numeric(20,0)` | lossless | lossy (negatives / >2⁶⁴−1) |
| `integer` | `numeric` | lossless | lossy (fractional numeric) |
| `string(encoding)` | `text` | lossless if DB encoding matches | lossy (encoding lost) |
| `string_with_encoding` | `text` | value kept, tag lost | lossy (tag lost) |
| `bytes(n)` | `bytea` + length check | lossless w/ check | lossy (length unenforced) |
| `enum(...)` | `text` + CHECK (or native `ENUM`) | lossless w/ check | lossy (structural ≠ nominal) |
| `enum("null")` | — | JSON-null symbol only | — |
| `array(T,N)` | `T[]` + cardinality check | lossless w/ check | lossy (dimension unenforced) |
| `array(T,D…)` | `T[]` | lossless | lossy (dimensions unenforced) |
| `map(K,V)` | `jsonb` (`hstore` if `string → string`) | lossless | lossy (shape unenforced) |
| `struct(...)` | composite type (top-level = row) | lossless | lossy (nominal) |
| `optional(T)` | nullable `T` | adds NULL state | NULL is a distinct state |
| `dynamic` | — | no SQL equivalent | — |
| `closure(...)` | — | no SQL equivalent | — |
| `result_equivalent_closure(...)` | — | no SQL equivalent | — |
| `absent` | — | internal only | — |

### 3.2 SQLite

SQLite has a single 64-bit signed `INTEGER`, an 8-byte `REAL`, `TEXT`, and
`BLOB`. Every DBSP integer type narrower than `i64` is therefore wider in
SQLite, making the reverse direction lossy.

| DBSP type | Target | → forward | ← reverse |
|-----------|--------|-----------|-----------|
| `i8`, `u8`, `u16`, `u32` | `INTEGER` | lossless | lossy (64-bit range) |
| `u64` | `TEXT` (decimal) | lossless | lossy (`INTEGER` fits only ≤2⁶³−1) |
| `integer` | `TEXT` | lossless | lossy (any text) |
| `f32` | `REAL` | lossless | lossy (extra precision) |
| `numeric`, `numeric(p,s)` | `TEXT` | lossless | lossy |
| `string(encoding)` | `TEXT` | value kept, encoding lost | lossy |
| `string_with_encoding` | `TEXT` | value kept, tag lost | lossy |
| `bytes(n)` | `BLOB` + length check | lossless w/ check | lossy (length unenforced) |
| `bits`, `bits(n)` | `BLOB` | lossless (as bytes) | lossy (bit-length lost) |
| `enum(...)` | `TEXT` | lossless | lossy |
| `date` | `TEXT` (ISO-8601) | lossless | lossy (any text) |
| `time` | `TEXT` (ISO-8601) | lossless | lossy |
| `timestamp` | `TEXT` (RFC-3339) | lossless | lossy |
| `timestamp_with_timezone` | `TEXT` (RFC-3339 + offset) | lossless | lossy |
| `interval` | `TEXT` (or 3 int columns) | lossless | lossy |
| `json` | `TEXT` (JSON1) | lossless | lossy (must be valid JSON) |
| `array(…)` | `TEXT` (JSON) | lossless | lossy |
| `map(K,V)` | `TEXT` (JSON) | lossless | lossy |
| `struct(...)` | table row (top-level); nested `TEXT` (JSON) | lossless | lossy |
| `optional(T)` | nullable `T` | adds NULL state | NULL is a distinct state |
| `dynamic` | — | no SQL equivalent | — |
| `closure(...)` | — | no SQL equivalent | — |
| `result_equivalent_closure(...)` | — | no SQL equivalent | — |
| `absent` | — | internal only | — |

---

## 4. Conventions

- **SQLite temporal values** are stored as ISO-8601 / RFC-3339 text,
  mirroring `gdbsp_cross_runner.erl`.
- **SQLite compound values** (`array`, `map`, nested `struct`) are stored as
  JSON text; SQLite has no native compound type.
- **`jsonb` is preferred** over `json` in PostgreSQL (binary storage,
  deterministic key ordering, equality/indexing).
- **`enum`** maps to `text` + CHECK rather than a native PostgreSQL `ENUM`:
  DBSP enums are structural (§2 of the type system), PostgreSQL enums are
  nominal, and the two do not round-trip.
- **`array(T)`** maps to PostgreSQL `T[]`; the exactness depends on `T`
  having an exact mapping itself.
- **`optional(T)`** is a nullability wrapper, not a distinct storage type;
  it maps to a nullable column in both dialects.
