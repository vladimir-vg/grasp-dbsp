# Function Semantics Robustness & Runtime Stdlib Gaps — Implementation Plan

Date: 2026-08-23
Status: draft

Follow-up to the inline-function work (`feat: inline functions …`,
`feat: explicit param-name threading …`). The full suite is green
(494 passed / 0 failed), but review surfaced correctness holes in the
function model and a set of latent runtime gaps in the stdlib
implementation tables. This plan hardens function semantics (recursion,
arity, keyword-arg, duplicate-name, stdlib-collision validation), makes
type inference strict and consistent (`get`/`slice` inference, `dynamic`
no longer a wildcard), unifies the type-inference test harness with the
real compile pipeline, and closes the runtime gaps that functions
surface (unary neg on `integer`, boolean operators, `bytes`/`bits`/
`array`/`temporal` modules).

Companion decisions agreed with the author:

- `dynamic` is a concrete, runtime-tagged type; it must **not** serve as
  `any`/generic. Type variables (`{type_var, _}`) are the generic
  mechanism.
- A concrete argument does **not** match a `dynamic` parameter (mismatch).
- Two `dynamic` types match regardless of their wrapped inner type
  (`dynamic` is a wrapper).
- Error signalling: each validation produces a distinct, greppable term
  (see §5). No silent precedence.

---

## 1. Scope

In scope:

1. Shared lower+infer pipeline (single code path for compile and tests).
2. `get`/`slice` type inference in both type-inference systems.
3. `exact_match` `dynamic` rules (strict, wrapper semantics).
4. Function validation: recursion/cycle, row-function arity, extra
   keyword args, duplicate inline names, stdlib-name collision.
5. Runtime gaps: unary neg on `integer`, boolean operators
   (`and`/`or`/`not`), and `bytes`/`bits`/`array`/`temporal` modules.
6. Tests for all of the above (§7).

Out of scope (deferred, per agreement):

- Fixed-width (`i8..u64` except `i64`) `sub/mul/div/mod/neg` impls and
  the `math_neg_i64` / `math_neg_numeric` / `math_abs_i64` functions.
  `integer` is the supported general-purpose numeric type for now.
- Beta-reduction memoization / expression sharing across call sites.
- Removing the external `fn_registry` (`functions:` YAML) mechanism —
  kept for now; new tests use inline definitions.

---

## 2. Shared lower+infer pipeline

### 2.1 Motivation

`gdbsp_type_infer_SUITE` currently re-implements a *subset* of
`gdbsp_compile:compile_with_names/2`: it calls `gdbsp_compile_lower:run/2`
then `gdbsp_type_infer:infer_lowered/4` with a hand-assembled
`Functions`/`StdlibMap`, skipping inline-function compilation and the
merged callable map. This means type-inference tests can drift from what
compilation actually does. Fix: extract one stage, use it everywhere.

### 2.2 `gdbsp_compile:infer/2`

New exported function carrying the *type-inference stage* of
`compile_with_names/2` verbatim:

```erlang
-spec infer(#gdbsp_program{}, fn_registry()) ->
    {ok, #lowered_graph{}, fn_registry(), fn_params()} | {error, term()}.
infer(Program, ExternalFnReg) ->
    try
        {ok, StdlibMap} = load_stdlib(),
        {InlineFnReg, FnParams} = compile_inline_fns(Program, StdlibMap),
        case duplicate_fn_names(ExternalFnReg, InlineFnReg) of
            [] -> ok;
            [Name | _] -> throw({compile_error, {duplicate_function, Name}})
        end,
        FnReg = maps:merge(ExternalFnReg, InlineFnReg),
        CallableMap = gdbsp_compile_expr:merge_callable_maps(
            StdlibMap,
            gdbsp_compile_expr:inline_sig_map(Program#gdbsp_program.typespecs)),
        TSMap = build_ts_map(Program#gdbsp_program.typespecs),
        case gdbsp_compile_lower:run(Program, #{}) of
            {ok, Lowered0} ->
                case gdbsp_type_infer:infer_lowered(Lowered0, TSMap, FnReg, CallableMap) of
                    {ok, Lowered} -> {ok, Lowered, FnReg, FnParams};
                    {error, _} = E -> E
                end;
            {error, _} = E -> E
        end
    catch
        throw:{compile_error, Reason} -> {error, {compile_error, Reason}};
        throw:{fixpoint_error, Reason} -> {error, {fixpoint_error, Reason}}
    end.
```

### 2.3 `compile_with_names/2` uses it

```erlang
compile_with_names(Program, Options) ->
    ExternalFnReg = maps:get(fn_registry, Options, #{}),
    Incr = maps:get(incrementalize, Options, false),
    case infer(Program, ExternalFnReg) of
        {ok, Lowered, FnReg, FnParams} ->
            case gdbsp_compile_graph:build_from_lowered(Lowered, FnReg, FnParams) of
                {ok, Graph, NameToId} -> %% incrementalize + return, unchanged
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.
```

Graph construction keeps its own `try/catch` (it can throw
`{compile_error, {recursive_function, _}}`, `{missing_function, _}`, …).

### 2.4 Type-inference test harness

`gdbsp_type_infer_SUITE`:

- `run_positive/…`: replace the manual load/lower/infer with
  `case gdbsp_compile:infer(Prog, Functions) of {ok, Lowered, _, _} -> …`.
- `run_negative/…`: normalize `{error, Reason}` before asserting:

  | Reason | Normalized class |
  |---|---|
  | `#{class := _} = Map` (from `infer_lowered`) | `Map.class` |
  | `{compile_error, {inline_fn_errors, #{_ := [First | _]}}}` | tag of `First` (`fn_lookup_error`, `unbound_var`, …) |
  | `{compile_error, {duplicate_function, _}}` | `duplicate_function` |

  The tag extraction mirrors `gdbsp_compile_expr` error term shapes:
  `{fn_lookup_error, _, _}`, `{unbound_var, _}`, `{return_type_mismatch, _, _}`, …

The external `functions:` registry remains supported (existing tests);
new tests use inline definitions in `source:`.

---

## 3. `get` / `slice` type inference

Currently `gdbsp_compile_expr:infer_expr_type` returns `{dynamic, []}`
for `{get, …}` and `{slice, …}`, and `gdbsp_type_infer`'s
`infer_expr_output_type` / `infer_map_output_type` have no `get`/`slice`
clauses (fall through to `dynamic` / input type). This makes
`row.vals[0]` (array element) infer `dynamic`, which then fails the
inline body's `return_type_mismatch` check (§7 item 5).

Both systems must infer the same shapes:

- `get(container, [key])`:
  - container `{array, T, _}`, integer key → `T`.
  - container `{map, K, V}`, key literal of `K` → `V`.
  - container `{struct, Fields, _}`, string-literal key → `field_type/2`.
  - container `dynamic`/`{dynamic, _}` → `dynamic` (legit, §4).
  - otherwise → error (unknown container), see §4.
- `slice(container, …)`:
  - `{array, T, _}` → `{array, T, varsize}`.
  - `string` / `{string, _}` → string.
  - `bytes` / `{bytes, _}` → bytes.
  - `dynamic`/`{dynamic, _}` → `dynamic`.
  - otherwise → error.

Files:

- `src/gdbsp_compile_expr.erl` — `infer_expr_type/4` clauses for
  `{get, …}` and `{slice, …}` (operating on `expr()`).
- `src/gdbsp_type_infer.erl` — `infer_expr_output_type/3` clauses for
  `#{<<"get">> := …}` and `#{<<"slice">> := …}` JSON nodes, and
  `infer_map_output_type/3` must also dispatch `get`/`slice` at the top
  level (a map whose whole body is a subscript).

The `std.struct_get` path is unchanged; this is the *subscript* syntax
(`a[k]`, `a[s:e]`).

---

## 4. `dynamic` semantics (`gdbsp_builtins:exact_match/2`)

Remove the two wildcard clauses and replace the refined-dynamic clause
with wrapper semantics:

```erlang
% REMOVE:
%   exact_match(dynamic, _) -> true;
%   exact_match(_, dynamic) -> true;
% CHANGE exact_match({dynamic, A}, {dynamic, B}) -> exact_match(A, B);
%   to ignore the wrapped inner type:
exact_match(dynamic, dynamic) -> true;
exact_match(dynamic, {dynamic, _}) -> true;
exact_match({dynamic, _}, dynamic) -> true;
exact_match({dynamic, _}, {dynamic, _}) -> true;
```

Net semantics:

| Arg → Param | Result |
|---|---|
| `dynamic` → `dynamic` | match |
| `{dynamic, string}` → `dynamic` / vice versa | match |
| `{dynamic, string}` → `{dynamic, i64}` | match (wrapper) |
| `dynamic` → `{string, _}` (e.g. `string_upper`) | **mismatch** |
| `i64` → `dynamic` | **mismatch** (D4) |
| `{type_var, _}` ↔ anything | match (unchanged; generic mechanism) |

Companion change — resolution failure is an error, not a `dynamic`
fallback: `gdbsp_type_infer:infer_call_output_type/3` currently returns
`dynamic` on `resolve_call` error; it must instead surface the error
(`error(#{class => type_conflict, …})` or propagate `no_matching_overload`).
`gdbsp_compile_expr:infer_expr_type` already reports `fn_lookup_error`
(its `dynamic` value is discarded), so no change there beyond the
`get`/`slice`/unknown-container clauses.

Verify no existing test relies on the `dynamic` wildcard (none found at
plan time; `e2e_types.yaml` uses `dynamic` only through `distinct`, and
`type_infer.yaml` uses `dynamic` only as an *output* of non-literal-key
`struct_get`, which stays legitimate).

---

## 5. Function validation

All produce a `throw({compile_error, Term})` caught by
`gdbsp_compile:infer/2` (or graph construction) and surfaced by the e2e /
type_infer harnesses. Terms are provisional but greppable.

### 5.1 Recursion / cycles

Location: `gdbsp_compile_graph:beta_reduce/4` — when a callee name is
already in `InProgress` (self- or mutual recursion), throw instead of
leaving the call unresolved:

```erlang
throw({compile_error, {recursive_function, Name}})
```

Error term: `recursive_function`.

### 5.2 Row-function arity

`map` / `filter` / `flat_map` functions must be unary (exactly one
positional param). Enforce in graph construction
(`gdbsp_compile_graph:make_operator_lowered/7`), which has `FnParams`.
For an inline fn with `length(pos) =/= 1` referenced by these operators:

```erlang
throw({compile_error, {row_fn_arity, Op, Name, Arity}})
```

Error term: `row_fn_arity`. (External functions without `FnParams` are
not checked — their arity is opaque.)

### 5.3 Extra keyword arguments at call sites

`gdbsp_builtins:match_kw/2` folds over the *callee's* declared kwargs and
ignores caller-supplied extras. Add a check that every caller kwarg key
is declared by the callee; on violation:

```erlang
{error, {unexpected_kw_arg, Key}}
```

This flows through `resolve_call` → `fn_lookup_error` in
`check_all_fns`, surfacing as `unexpected_kw_arg` in the message.

### 5.4 Duplicate inline function names

Two `fn_defs` with the same name must fail. Key on **definitions**
(`Program#gdbsp_program.fn_defs`), never on `typespecs` (repeated
typespecs for one definition stay legal — see §7 item 4). Detect in
`gdbsp_compile_expr:check_all_fns/2` (or `compile_inline_fns/2`) before
building maps (which are currently `maps:from_list`, last-wins):

```erlang
throw({compile_error, {duplicate_function, Name}})
```

Reuses the existing `duplicate_function` term (same as inline-vs-external).

### 5.5 Inline name colliding with a stdlib name

When an inline function name equals a stdlib function name (dotted
`std.*` names are parseable), fail instead of letting stdlib overload
order win. Detect when building the merged callable map in
`gdbsp_compile:infer/2` (or `compile_inline_fns/2`):

```erlang
throw({compile_error, {stdlib_collision, Name}})
```

Error term: `stdlib_collision` (distinct from `duplicate_function`).

---

## 6. Runtime stdlib gaps

### 6.1 `fn_impl` arity-name fixes (boolean operators)

`gdbsp_builtins:fn_impl/1` currently maps `std.and`/`std.or` to
`gdbsp_std:std_and_boolean/2` / `std_or_boolean/2`, but `gdbsp_std`
exports `std_and_boolean_boolean/2` / `std_or_boolean_boolean/2`. Fix the
MFAs.

### 6.2 Boolean operator lowering

The parser emits `{binop, 0, 'and'|'or', …}` and `{unop, 0, not_op, …}`,
but `binop_fn_name/1` has no `and`/`or` clauses and `unop_fn_name/1`
expects `'not'`. Reconcile (preferred: parser emits `'not'`; add
`binop_fn_name('and'|'or')`):

```erlang
binop_fn_name('and') -> <<"and">>;
binop_fn_name('or')  -> <<"or">>;
%% unop: change parse_prefix to emit 'not' (matching unop_fn_name('not'))
```

### 6.3 Unary neg on `integer`

`concrete_fn(<<"-">>, [integer])` emits `std.neg_integer`, but
`fn_impl/1` has no entry. Add:

```erlang
fn_impl(<<"std.neg_integer">>) -> {ok, {gdbsp_math, math_neg_integer, 1}}.
```

(`math_neg_integer/1` already exists.)

### 6.4 Missing modules

`fn_impl/1` references modules that do not exist. Implement the minimal
API each reference requires:

| Module (new) | Functions referenced |
|---|---|
| `gdbsp_bytes.erl` | `bytes_concat/2` |
| `gdbsp_bits.erl` | `bits_concat/2`, `bits_and/2`, `bits_or/2`, `bits_xor/2`, `bits_not/1`, `bits_shl/2`, `bits_shr/2`, `bits_rotl/2`, `bits_rotr/2` |
| `gdbsp_array.erl` | `array_concat/2` |
| `gdbsp_temporal.erl` | `temporal_add_interval_interval/2` (and `temporal_sub_interval_interval/2` if `std.sub_interval` is wired) |

Each takes/returns `gdbsp` `value()` tuples, following `gdbsp_string.erl`
as the pattern. Interval arithmetic semantics (months/days/microseconds)
must be specified before `gdbsp_temporal` is implemented — see §9.

Also add the missing `fn_impl` entry for `std.sub_interval` if interval
subtraction is to be supported (currently absent, so `-` on two
`interval`s → `unknown_impl`).

---

## 7. Test plan

Per-item inventory agreed with the author. Error terms in `message:` /
`class:` assertions are the §5 terms.

### 7.1 `test/gdbsp_e2e_SUITE_data/e2e_inline_functions.yaml` (negative + positive)

1. **Recursion (self)** — `helper := function((n) -> helper(n))`,
   used by a map fn → `message: recursive_function`.
2. **Recursion (mutual)** — `a → b → a` → `message: recursive_function`.
3. **Extra kwarg** — `double(row.x, extra: 1)` → `message: unexpected_kw_arg`.
4. **Non-unary map fn** — 2-positional-param fn in `map` → `message: row_fn_arity`; same for `filter` and `flat_map` (three cases).
5. **Duplicate definition** — two `f := function(…)` → `message: duplicate_function`.
6. **Repeated typespec (positive)** — one definition, two identical
   `f :: function(…)` → compiles and returns identity.
7. **Stdlib collision** — `std.concat_string := function(…)` → `message: stdlib_collision`.
8. **Mismatched concrete arg** — `std.string_upper(row.x)` with `x: i64` → `message: fn_lookup_error`.
9. **`dynamic` arg into concrete param** — `std.string_upper(row.x)` with `x: dynamic` → `message: fn_lookup_error`.
10. **Unary neg on integer (positive)** — `-row.x` on `integer` → `-5`.
11. **Boolean operators (positive)** — `and`, `or`, `not` in filters,
    with boolean results.
12. **Boolean type mismatch (negative)** — `row.a and row.b` on `i64` → `message: fn_lookup_error`.

### 7.2 `test/gdbsp_e2e_SUITE_data/e2e_stdlib_impl.yaml` (new, positive)

13. **bytes** — `row.a ++ row.b` on `bytes` → concatenated base64.
14. **bits** — `row.a & row.b` on `bits` → bitwise-and base64.
15. **array** — `row.a ++ row.b` on `array(i64)` → concatenated list.
16. **temporal** — `row.a + row.b` on `interval` → summed interval.

### 7.3 `test/gdbsp_type_infer_SUITE_data/type_infer.yaml` (positive, inline defs)

17. **Subscript element type** — `struct("v": row.vals[0])` over
    `array(i64)` → `expected: out: {struct: {v: i64}}`.
18. **Slice array type** — `struct("v": row.vals[0:2])` over
    `array(i64)` → `expected: out: {struct: {v: {array: i64}}}`.

### 7.4 `test/gdbsp_compile_expr_SUITE.erl` (unit)

19. **`resolve_call` strict `dynamic`** — `dynamic` / `{dynamic, T}` args
    do **not** resolve `std.string_upper`; `{dynamic, A}` matches
    `{dynamic, B}`; concrete arg does not match a `dynamic` param;
    `{type_var, _}` still matches anything.

---

## 8. Implementation order

1. **§2 shared pipeline** (`infer/2` + harness) — pure refactor, keeps
   494 green; unblocks the remaining tests.
2. **§4 `dynamic` rules** + `infer_call_output_type` error propagation.
3. **§3 `get`/`slice` inference** (both files).
4. **§5 validation** (recursion, arity, kwarg, duplicate, stdlib collision).
5. **§6 runtime gaps** (boolean ops, `std.neg_integer`, `bytes`/`bits`/`array`/`temporal`).
6. **§7 tests** (write as the corresponding fix lands; some are red-first).

Run `make test` (i.e. `RENDER_DOT=1 rebar3 ct`) after each stage.

---

## 9. Open items / deferred

- **Interval arithmetic semantics** for `gdbsp_temporal` (how
  months/days/microseconds combine, normalization rules) — needs a spec
  before implementing item 16; the test's expected value in §7.2 is
  illustrative until then.
- Fixed-width `sub/mul/div/mod/neg` (`i8..u64` minus `i64`) and
  `math_neg_i64` / `math_neg_numeric` / `math_abs_i64` — deferred;
  `integer` remains the supported general-purpose numeric type.
- Beta-reduction sharing/memoization — deferred (correctness-only).
