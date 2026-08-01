# Function Definition Parser — Implementation Plan

Date: 2026-08-01
Status: draft

This document describes the concrete steps to implement inline function body
definitions in `.gdbsp` source. It is a **temporary execution plan** — design
rationale and permanent specification live in [syntax.md](syntax.md),
[grasp-dbsp.md](grasp-dbsp.md), and [compilation.md](compilation.md). Remove
this file after the feature is implemented.

---

## 1. Task Order

### Step 1 — New Header: `include/gdbsp_parse_expr.hrl`

Define the parse expression type. This is the syntactic representation
preserving operator structure, dot chains, and literal forms before desugaring.

- `parse_expr()` sum type: `{var, Line, Name}`, `{const, Line, Value, Tag, Src, Type}`,
  `{symbol, Line, Name}`, `{binop, Line, Op, LHS, RHS}`, `{unop, Line, Op, E}`,
  `{call, Line, Name, Args}`, `{agg, Line, Name, Args}`,
  `{dict_literal, Line, KwArgs, Rest}`, `{array_literal, Line, Elems}`,
  `{subscript, Line, Obj, Spec}`, `{dot_access, Line, Obj, Field}`.
- `const_tag()` — `integer | decimal | float | string | bits | absent`.
- `kv_arg()` — `{kv, Name, Value}` (used in call args and dict literals).
- `array_elem()` — `expr()` | `{rest, Line, Var}`.
- `subscript_spec()` — `{index, expr()}` | `{slice, Start, Stop, Step}`.

### Step 2 — Lexer

**2a.** Create `src/gdbsp_lexer_core.xrl`.

Adapt from `gg_c_lexer_core.xrl`. Token rules:

- Comment `#[^\n]*` → skip.
- Whitespace `[\040\t]+` → skip.
- Newline `\n` → `{token, {newline, Line}}`.
- Keywords: `function`, `circuit`, `fixpoint`, `not`, `and`, `or`, `true`,
  `false`, `null` (NULL), `absent` (ABSENT), `input`, `eval`, `enum`, `closure`.
- Operators: `:=` → `walrus`, `::` → `double_colon`, `->` → `arrow`, `**` →
  `double_star`, `!=`, `>=`, `<=`, `++`, `<<<`, `>>>`, `<<`, `>>`, `~`, `&`,
  `^`, `|`, `.`, `+`, `-`, `*`, `/`, `%`, `=`, `>`, `<`, `:`, `,`, `(`, `)`,
  `{`, `}`, `[`, `]`.
- Literals: integers `[0-9]+`, floats/decimal (with `.` or `e`/`E`), bits
  `0b[01]+`, strings `"(\\.|[^\"])*"`.
- Identifiers: `[a-zA-Z_][a-zA-Z0-9_]*(:[a-zA-Z_][a-zA-Z0-9_]*)*`.
- Include Erlang helper code: `parse_number/1`, `unescape/1`, `to_binary/1`,
  `parse_bit_string/1`.

**2b.** Create `src/gdbsp_lexer.erl`.

Wrapper around the leex-generated scanner:

- Strips skip tokens.
- Indentation tracking: after a `circuit NAME(params):` header, lines starting
  with whitespace are circuit body lines. Emits `{body_line, Line}` for body
  content, `{body_end, Line}` when indentation drops back to or below header
  level.
- Export `string/1 :: binary() -> {ok, [token()]} | {error, term()}`.

**2c.** Write unit tests for the lexer: verify tokenization of sample `.gdbsp`
snippets covering all token types.

### Step 3 — Parser Rewrite: `src/gdbsp_parse.erl`

Replace the current line-oriented recursive descent parser with a token-based
parser.

**3a.** Top-level `parse_program/1`.

Loop over tokens, collecting all declarations in any order. Dispatch on token
patterns:

- `{identifier, _, Name}, {double_colon, _}` → `parse_typespec(Name, Rest)`
- `{identifier, _, Name}, {walrus, _}` → if next token is `'function'` then
  `parse_fn_def(Name, Rest)` else `parse_node_def(Name, Rest)`
- `{'circuit', _}` → `parse_circuit_def(Rest)`

Return `{ok, #gdbsp_program{}}` or `{error, term()}`.

**3b.** Parse all existing declaration types.

- `parse_node_def/2` — `NAME := OP(args)` or `NAME := circuit_call(...)`
  or `NAME := other_node` (plus alias). Produce `#gdbsp_node_def{}`.
- `parse_typespec/2` — `NAME :: stream(...)` or
  `NAME :: function((params) -> ret)` or
  `NAME :: aggregate_function((params) -> ret)`. Produce `#gdbsp_typespec{}`.
- `parse_circuit_def/1` — `circuit NAME(params):` followed by indented body
  lines. Produce `#gdbsp_circuit_def{}`.
- Fixpoint instantiation (`NAME := fixpoint(args)`) is handled within
  `parse_node_def`.

**3c.** Rewrite type parsing to be token-based.

Adopt the approach from `gg_c_parser:parse_type/1`. The type grammar matches
[syntax.md §4](syntax.md#41-type-grammar). Implement:

- `parse_type/1` — dispatches to scalar, compound, or type variable.
- `parse_scalar_type/1` — `i64`, `string(...)`, `enum(...)`, etc.
- `parse_compound_type/1` — `struct(...)`, `array(...)`, `map(K,V)`,
  `optional(T)`, `closure(...)`.
- `parse_struct_fields/1` — `NAME: type` or `STRING: type`.
- `parse_stream_type/1` — `stream(type)`.
- `parse_fn_type_params/1` — mixed positional/keyword param list for
  function/aggregate typespecs.

**3d.** Adopt expression parser from `gg_c_parser.erl`.

Copy the precedence-climbing chain from `gg_c_parser.erl` into a new set of
functions within `gdbsp_parse.erl`. The entry point is `parse_expr/1`, producing
`parse_expr()` nodes.

Precedence levels (same as `gg_c_parser.erl`):
1. `parse_or/1` → `parse_and/1`
2. `parse_and/1` → `parse_cmp/1`
3. `parse_cmp/1` — no chaining
4. `parse_grouped_binary/1` — dispatches to `++`, bitwise, shift, arithmetic
5. `parse_prefix/1` — unary `not`, `-`, `~`
6. `parse_atomic/1` — literals, vars, calls, dicts, arrays, dots, subscripts

Cross-group error detection: mixing incompatible operators (e.g., `a + b < c`)
without parentheses produces `{error, {cross_group_arithmetic, Op}, Tokens}`.

In function bodies, aggregates (`name<args>`) and closures (`closure(...)`)
produce parse errors.

**3e.** Parse function definitions.

```erlang
parse_fn_def(Name, [{'function', _}, {'(', _} | Rest]) ->
    {Params, Rest2} = parse_fn_params(Rest),
    {'arrow', _} = expect(Rest2),
    {Body, Rest3} = parse_expr(tl(Rest2)),
    {')', _} = expect(Rest3),
    #gdbsp_fn_def{name = Name, params = Params, body = Body, line = Line}.
```

`parse_fn_params/1`:
- Positional: `{identifier, _, N}, {',', _}, Rest` → `[{pos, N} | ...]`
- Keyword shorthand: `{identifier, _, N}, {':', _}, ...` → `[{kw, N, N} | ...]`
- Keyword explicit: `{identifier, _, K}, {':', _}, {identifier, _, V}, ...` →
  `[{kw, K, V} | ...]`
- List ends at `{arrow, _}` token.

Validation: positional before keyword; no duplicate param names. Errors use
`throw({parse_error, Line, Msg})`.

**3f.** Verify all existing `test/parse_fixtures/parse.yaml` tests pass with
the rewritten parser.

### Step 4 — AST Records

**4a.** Add to `include/gdbsp_parse.hrl`:

```erlang
-record(gdbsp_fn_def, {
    name    :: binary(),
    params  :: [{pos, binary()} | {kw, binary(), binary()}],
    body    :: gdbsp_parse_expr:parse_expr(),
    line    :: pos_integer()
}).
```

**4b.** Extend `#gdbsp_program{}`:

```erlang
-record(gdbsp_program, {
    nodes      :: [#gdbsp_node_def{}],
    typespecs  :: [#gdbsp_typespec{}],
    circuits   :: [#gdbsp_circuit_def{}],
    fn_defs    :: [#gdbsp_fn_def{}]
}).
```

Requires adding `-include("gdbsp_parse_expr.hrl")` to `gdbsp_parse.hrl`.

### Step 5 — Expression Lowering: `src/gdbsp_compile_expr.erl`

New module. Converts parse expressions to the runtime expression format
(`gdbsp_expr.hrl`).

**5a.** `lower_expr(parse_expr(), Bindings) -> expr()`.

| Parse expr | Runtime expr |
|---|---|
| `{const, _, N, integer, _, _}` | `{value, integer, N}` |
| `{const, _, V, decimal, _, _}` | `{value, numeric, V}` |
| `{const, _, V, float, _, _}` | `{value, f64, V}` |
| `{const, _, S, string, _, _}` | `{value, {string, <<"UTF-8">>}, S}` |
| `{const, _, B, bits, _, _}` | `{value, bits, B}` |
| `{const, _, absent, _, _, _}` | `{value, absent, absent}` |
| `{symbol, _, <<"true">>}` | `{value, {enum, <<"false">>,<<"true">>}, <<"true">>}` |
| `{symbol, _, <<"false">>}` | `{value, {enum, *}, <<"false">>}` |
| `{symbol, _, <<"null">>}` | `{value, {enum, [<<"null">>]}, <<"null">>}` |
| `{var, _, Name}` (bound) | `{arg, Name}` |
| `{binop, _, Op, L, R}` | `{call, desugar(Op), [L', R'], #{}}` |
| `{unop, _, Op, E}` | `{call, desugar(Op), [E'], #{}}` |
| `{dot_access, _, Obj, F}` | `{call, <<"struct:get">>, [Obj'], #{<<"key">> => {value, {string,<<"UTF-8">>}, F}}}` |
| `{array_literal, _, Elems}` | `{call, <<"array">>, Elems', #{}}` |
| `{dict_literal, _, KwArgs, Rest}` | `{call, <<"map">>, [], KwMap}` (no rest) or `{call, <<"map_merge">>, [{call,<<"map">>, [], KwMap}, Rest'], #{}}` |
| `{subscript, _, Obj, {index, K}}` | `{get, Obj', [K']}` |
| `{subscript, _, Obj, {slice, S, E, St}}` | `{slice, Obj', S', E', St'}` |
| `{call, _, Name, Args}` | split pos/kw → `{call, Name, Pos', KwMap}` |

`Bindings` maps `var_name => arg_name`. For function bodies, all vars map to
`{arg, Name}`. Unbound variables (not in Bindings) produce an error.

**5b.** `lower_fn_body(#gdbsp_fn_def{}, #gdbsp_typespec{}) -> expr()`.

Build bindings from the typespec parameter list: match positional by index,
keyword by key name. Then call `lower_expr/2`.

### Step 6 — Function Body Type Checking (in `gdbsp_compile_expr.erl`)

**6a.** `check_fn_body(expr(), TypeEnv, DeclaredRetType) -> ok | {error, [Error]}`.

Walks the runtime expression tree, inferring types:
- `{value, T, _}` → `T`
- `{arg, Name}` → lookup in `TypeEnv`
- `{call, Name, PosArgs, KwArgs}` → infer arg types, call
  `gdbsp_builtins:lookup_fn(Name, PosTypes, KwPairs)`, return result type.
  Error if lookup fails.
- `{get, _, _}` → `dynamic`
- `{slice, ...}` → `dynamic`

Verifies inferred return type matches `DeclaredRetType` via
`gdbsp_type:canonical_text/1` equality. Collects all errors encountered
during the walk (doesn't stop at the first error).

**6b.** `check_all_fns(#gdbsp_program{}) -> {ok, FnJsonMap, Warnings} | {error, ErrorMap}`.

For each `#gdbsp_fn_def{}`:
1. Find matching `#gdbsp_typespec{spec = {function, PosTypes, KwMap, RetType}}`
   by name. Error if not found (`missing_typespec`).
2. Verify param count/key match between definition and typespec.
3. Build `TypeEnv` mapping variable names to declared types.
4. Lower body via `lower_fn_body/2`.
5. Check via `check_fn_body/3`.
6. On success, encode to JSON via `gdbsp_expr:expr_to_json/1` and add to
   `FnJsonMap`.

### Step 7 — `gdbsp_builtins.erl` Changes

Add `fn_overloads` entries for the short operator names:

| New name | Implementation (reuse existing) |
|----------|-------------------------------|
| `<<"add">>` | same overloads as `<<"math:add">>` |
| `<<"sub">>` | same overloads as `<<"math:sub">>` |
| `<<"mul">>` | same overloads as `<<"math:mul">>` |
| `<<"div">>` | same overloads as `<<"math:div">>` |
| `<<"mod">>` | same overloads as `<<"math:mod">>` |
| `<<"neg">>` | same overloads as `<<"math:neg">>` |
| `<<"bits_or">>` | same overloads as `<<"bits:or">>` |
| `<<"bits_xor">>` | same overloads as `<<"bits:xor">>` |
| `<<"bits_and">>` | same overloads as `<<"bits:and">>` |
| `<<"bits_shl">>` | same overloads as `<<"bits:shl">>` |
| `<<"bits_shr">>` | same overloads as `<<"bits:shr">>` |
| `<<"bits_rotl">>` | same overloads as `<<"bits:rotl">>` |
| `<<"bits_rotr">>` | same overloads as `<<"bits:rotr">>` |
| `<<"bits_not">>` | same overloads as `<<"bits:not">>` |

The existing namespaced entries remain as aliases. Update `binop_fn_name/1` to
map operators to the new short names.

### Step 8 — Compilation Integration: `src/gdbsp_compile.erl`

Add a pre-lowering pass that compiles inline function definitions:

```erlang
compile(Program, Options) ->
    ExternalFnReg = maps:get(fn_registry, Options, #{}),
    {ok, InlineFnReg, Warnings} = gdbsp_compile_expr:check_all_fns(Program),
    FnReg = maps:merge(ExternalFnReg, InlineFnReg),
    % ... existing pipeline continues with FnReg ...
```

Inline definitions override external ones when both exist. Typespec-only
functions use the external JSON body as before.

### Step 9 — Tests

**9a. Parse tests.** New YAML sections in `test/parse_fixtures/parse.yaml`:

- Function definition with all-positional params.
- Function definition with mixed positional/keyword params.
- Function definition with explicit keyword variable names (`d: dvar`).
- Expression: arithmetic, comparison, boolean, concatenation, bitwise.
- Expression: function calls, struct construction (`struct(...)`), map literals
  (`{k: v}`), array literals, dot access, subscripts.
- Operator precedence: `a + b * c`, `a > b and c < d`.
- Cross-group error: `a + b < c`.
- Aggregates in function body → parse error.
- Closure in function body → parse error.

**9b. Lowering tests.** Verify parse_expr → runtime expr conversion for each
node type. Verify correct operator desugaring names.

**9c. Type-check tests.**

- Correct function body with matching return type.
- Return type mismatch → error.
- Unbound variable in body → error.
- Param count mismatch → error.
- Keyword param mismatch → error.

**9d. Compilation integration tests.**

- Full compile of `.gdbsp` with inline function bodies.
- Mixed inline + external functions (inline overrides, external used as
  fallback).
- External-only functions continue to work.

**9e. Backward compatibility.** All existing tests in
`test/parse_fixtures/parse.yaml` pass unchanged.

### Step 10 — `rebar.config`

If the leex compiler plugin is not already present, add it so that
`gdbsp_lexer_core.xrl` is compiled during `rebar3 compile`.

---

## 2. Files Summary

| Action | File |
|--------|------|
| CREATE | `include/gdbsp_parse_expr.hrl` |
| CREATE | `src/gdbsp_lexer_core.xrl` |
| CREATE | `src/gdbsp_lexer.erl` |
| CREATE | `src/gdbsp_compile_expr.erl` |
| REWRITE | `src/gdbsp_parse.erl` |
| MODIFY | `include/gdbsp_parse.hrl` |
| MODIFY | `src/gdbsp_compile.erl` |
| MODIFY | `src/gdbsp_builtins.erl` |
| MODIFY | `rebar.config` (leex plugin if needed) |
