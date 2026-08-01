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

**2c.** Write tests for the lexer (see TDD Phase 1 below).

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

---

## 2. TDD Plan

Implementation follows a test-driven approach organized into six phases,
each with specific test modules and cycles.

### Key Principles

1. **New modules are pure TDD:** Lexer, expression lowering, and type checking
   — all new modules with no legacy code. Write test → fail → implement → pass.
2. **Parser is regression-first, then new features:** The parser is rewritten
   monolithically. The 10 existing `parse.yaml` fixtures serve as the regression
   contract. New YAML cases are added once the token-based parser is functional.
3. **Full regression after every change:** Run `rebar3 ct` before committing.

### Running Tests

```bash
# Individual test suites
rebar3 ct --suite=test/gdbsp_lexer_SUITE
rebar3 ct --suite=test/gdbsp_parse_SUITE
rebar3 ct --suite=test/gdbsp_compile_expr_SUITE
rebar3 ct --suite=test/gdbsp_compile_SUITE

# Full regression
rebar3 ct
```

### Phase 1: Lexer (Step 2)

**New test module:** `test/gdbsp_lexer_SUITE.erl` (Common Test). Tests
`gdbsp_lexer:string/1` in isolation.

| # | Test (write first) | Implement | Assert |
|---|---|---|---|
| 1 | Tokenize `name := source("table")` | leex rules for identifiers, strings, `:=`, `()`, newline | `[{identifier,"name"}, {walrus}, {identifier,"source"}, {'('}, {string,"table"}, {')'}]` |
| 2 | Tokenize `name :: stream(struct("f": i64))` | leex rules for `::`, compound type keywords | Full token sequence |
| 3 | Tokenize integer/float/decimal/bits literals (`42`, `3.14`, `0b1011`) | Literal leex rules + `parse_number/1`, `parse_bit_string/1` | Correct token types with parsed values |
| 4 | Tokenize expression operators: `+ - * / % = != < > <= >= and or not` | Operator leex rules | Each produces correct token atom |
| 5 | Tokenize bitwise: `\| ^ & << >> <<< >>> ~ ++` | Operator leex rules | Each produces correct token atom |
| 6 | Tokenize delimiters: `{ } [ ] . , : -> := :: **` | Delimiter leex rules | Each produces correct token atom |
| 7 | Tokenize function definition: `add := function((x, y, d:) -> x + y)` | All token types together | Correct token sequence |
| 8 | Tokenize circuit body with indentation → `body_line` / `body_end` markers | Indentation tracking in `gdbsp_lexer.erl` wrapper | Body content wrapped in markers |
| 9 | Tokenize comments — no tokens produced | `#[^\n]*` skip rule | Comment lines produce zero tokens |

Run: `rebar3 ct --suite=test/gdbsp_lexer_SUITE`

### Phase 2: Parser — Backward Compatibility (Steps 3a–3c, 3f, 10)

**Existing test module:** `test/gdbsp_parse_SUITE.erl` (10 test cases in
`test/parse_fixtures/parse.yaml`). These are the regression contract.

| # | Action | Verify |
|---|---|---|
| 1 | Implement `parse_program/1` skeleton + `parse_node_def/2` for known operators | Incrementally: first test case passes, then two, etc. |
| 2 | Add `parse_typespec/2` path (`:: stream(...)`, `:: function(...)`, `:: aggregate_function(...)`) | Parser produces identical `#gdbsp_typespec{}` structures to old parser |
| 3 | Add `parse_circuit_def/1` path with indented body | Circuit body nodes parsed correctly |
| 4 | Add fixpoint parsing within `parse_node_def` | Fixpoint args match old output |
| 5 | Add `rebar.config` leex plugin if needed | Compilation succeeds |

Run: `rebar3 ct --suite=test/gdbsp_parse_SUITE` after each sub-step.

### Phase 3: Parser — New Features (Steps 3d–3e, 4)

**Add YAML test cases** to `test/parse_fixtures/parse.yaml`. Each new case
is added BEFORE implementing the corresponding parser feature.

| # | Test case (YAML) | Implement | Assert |
|---|---|---|---|
| 1 | Function definition: `add := function((x, y) -> x + y)` | `parse_fn_def/2`, `parse_fn_params/1` for positional params | `#gdbsp_fn_def{name="add", params=[{pos,"x"},{pos,"y"}], body=...}` |
| 2 | Keyword params: `f := function((x, d:, e: evar) -> ...)` | Keyword shorthand `name:` and explicit `key: var` | `params=[{pos,"x"},{kw,"d","d"},{kw,"e","evar"}]` |
| 3 | Integer literal `42` in body | `parse_atomic/1` literal production | `{const, _, 42, integer, _, _}` |
| 4 | String `"hello"`, `true`, `false`, `null` | All literal + symbol types | Correct `{const,...}` / `{symbol,...}` nodes |
| 5 | Binary ops: `x + y`, `a * b` | Full precedence-climbing chain | `{binop, _, '+', {var,_,<<"x">>}, {var,_,<<"y">>}}` |
| 6 | Precedence: `a + b * c`, `x > y and z` | `parse_or` → `parse_and` → `parse_cmp` → `parse_grouped_binary` → `parse_prefix` | Correctly nested binop tree |
| 7 | Cross-group error: `a + b < c` | Error detection in `parse_grouped_binary_rest` | `{error, {cross_group_arithmetic, _}, _}` |
| 8 | Function calls: `sqrt(x)`, `struct:get(row, key: "col")` | `parse_atomic` call path, mixed pos/kw args | `{call, _, <<"sqrt">>, [{var,_,<<"x">>}]}` |
| 9 | Map literal `{a: 1, b: x}` | `parse_dict/1` | `{dict_literal, _, [{kv,<<"a">>,...},{kv,<<"b">>,...}], undefined}` |
| 10 | Array literal `[1, 2, 3]`, `[x, *rest]` | `parse_array/1` | `{array_literal, _, [...]}` |
| 11 | Dot access `row.field` | `parse_dot_chain` | `{dot_access, _, {var,_,<<"row">>}, <<"field">>}` |
| 12 | Subscript `arr[0]`, slice `s[0:5]` | `parse_subscript`, `parse_slice` | `{subscript, _, _, {index,...}}` / `{subscript, _, _, {slice,...}}` |
| 13 | Aggregate in function body → parse error | Guard in `parse_atomic` | `{error, ...}` |
| 14 | Closure in function body → parse error | Guard in `parse_atomic` | `{error, ...}` |
| 15 | Function def without matching typespec (positive — parse succeeds, error at compile) | Just parse successfully | `#gdbsp_fn_def{}` |
| 16 | Unknown variable in body (positive — parse succeeds, error at type-check) | Parse `{var, _, Name}` even for unknown names | `{var, _, <<"unknown">>}` |

Run: `rebar3 ct --suite=test/gdbsp_parse_SUITE` after each sub-step.

**After all Phase 3 tests pass:** Create `include/gdbsp_parse_expr.hrl` with
the `parse_expr()` type definition. Add `#gdbsp_fn_def{}` record and extend
`#gdbsp_program{}` with `fn_defs` field (Step 4).

### Phase 4: Expression Lowering + Type Checking (Steps 5–6)

**New test module:** `test/gdbsp_compile_expr_SUITE.erl` (Common Test). Tests
`gdbsp_compile_expr:lower_expr/2`, `check_fn_body/3`, and `check_all_fns/1`.

**4a. Lowering tests.**

| # | Test `lower_expr/2` input | Assert on output |
|---|---|---|
| 1 | `{const, _, 42, integer, _, _}`, `#{}` | `{value, integer, 42}` |
| 2 | `{const, _, <<"hi">>, string, _, _}`, `#{}` | `{value, {string, <<"UTF-8">>}, <<"hi">>}` |
| 3 | `{const, _, absent, _, _, _}`, `#{}` | `{value, absent, absent}` |
| 4 | `{symbol, _, <<"true">>}`, `#{}` | `{value, {enum,[<<"false">>,<<"true">>]}, <<"true">>}` |
| 5 | `{symbol, _, <<"null">>}`, `#{}` | `{value, {enum,[<<"null">>]}, <<"null">>}` |
| 6 | `{var, _, <<"x">>}`, `#{"x" => "x"}` | `{arg, <<"x">>}` |
| 7 | `{var, _, <<"y">>}`, `#{}` → error | `unbound_var` |
| 8 | `{binop, _, '+', {var,_,<<"x">>}, {var,_,<<"y">>}}`, `#{"x"=>"x","y"=>"y"}` | `{call, <<"add">>, [{arg,<<"x">>},{arg,<<"y">>}], #{}}` |
| 9 | All 23 operators (one test per operator) | Each produces correct desugared function name (see §6.5 of syntax.md) |
| 10 | `{unop, _, '-', {var,_,<<"x">>}}`, `#{"x"=>"x"}` | `{call, <<"neg">>, [{arg,<<"x">>}], #{}}` |
| 11 | `{dot_access, _, {var,_,<<"r">>}, <<"f">>}`, `#{"r"=>"r"}` | `{call, <<"struct:get">>, [{arg,<<"r">>}], #{<<"key">> => {value, {string,<<"UTF-8">>}, <<"f">>}}` |
| 12 | `{array_literal, _, [e1, e2]}`, bindings | `{call, <<"array">>, [e1', e2'], #{}}` |
| 13 | `{dict_literal, _, [{kv,<<"a">>,v1}], undefined}`, bindings | `{call, <<"map">>, [], #{<<"a">> => v1'}}` |
| 14 | `{call, _, <<"sqrt">>, [e1]}`, bindings | `{call, <<"sqrt">>, [e1'], #{}}` |
| 15 | `{call, _, <<"f">>, [e1, {kv,<<"k">>,v1}]}`, bindings | `{call, <<"f">>, [e1'], #{<<"k">> => v1'}}` |
| 16 | `{subscript, _, e, {index, k}}`, bindings | `{get, e', [k']}` |
| 17 | `{subscript, _, e, {slice, s, undefined, undefined}}`, bindings | `{slice, e', s', undefined, undefined}` |

**4b. Type checking tests.**

| # | Test `check_fn_body/3` input | Assert |
|---|---|---|
| 1 | Body `{value, integer, 42}`, env `#{x => i64}`, ret `i64` | `ok` |
| 2 | Body `{value, integer, 42}`, env `#{}`, ret `string` | `return_type_mismatch` |
| 3 | Body `{arg, <<"x">>}`, env `#{<<"x">> => i64}`, ret `i64` | `ok` |
| 4 | Body `{arg, <<"x">>}`, env `#{}`, ret `i64` | `unbound_var` |
| 5 | Body `{call, <<"add">>, [{arg,<<"x">>},{arg,<<"y">>}], #{}}`, env `#{"x"=>i64, "y"=>i64}`, ret `i64` | `ok` (exercises `gdbsp_builtins:lookup_fn`) |
| 6 | Same body but ret `string` | `return_type_mismatch` |

**4c. Integration tests.** `check_all_fns/1` on full programs:

| # | Program input | Assert |
|---|---|---|
| 1 | fn_def with matching typespec | `{ok, FnJsonMap, []}` |
| 2 | fn_def without matching typespec | `{error, #{fn_name => missing_typespec}}` |
| 3 | Param count mismatch (positional) | `{error, ...}` |
| 4 | Keyword param name mismatch | `{error, ...}` |
| 5 | Round-trip: parse string → lower → JSON → `json_to_expr` | Runtime expr matches original lowered form |

Run: `rebar3 ct --suite=test/gdbsp_compile_expr_SUITE`

### Phase 5: Builtins (Step 7)

Add test cases to `test/gdbsp_compile_expr_SUITE.erl` (the type checker's
`check_fn_body/3` already exercises `lookup_fn` through call resolution; add
explicit tests here).

| # | Test | Assert |
|---|---|---|
| 1 | `gdbsp_builtins:lookup_fn(<<"add">>, [i64, i64], [])` | `{ok, i64, _}` |
| 2 | Same for all 14 new names | All resolve |
| 3 | `gdbsp_builtins:lookup_fn(<<"math:add">>, [i64, i64], [])` | `{ok, i64, _}` (backward compat) |
| 4 | `gdbsp_builtins:binop_fn_name('+')` | `<<"add">>` |
| 5 | Cross-check: operator desugaring produces names resolvable via `lookup_fn` | All 23 operators |

Run alongside Phase 4 tests: `rebar3 ct --suite=test/gdbsp_compile_expr_SUITE`

### Phase 6: Compilation Integration (Step 8)

**Modify existing test module:** `test/gdbsp_compile_SUITE.erl`. Add test cases
that compile full `.gdbsp` source strings with inline function bodies.

| # | Test | Assert |
|---|---|---|
| 1 | Compile `.gdbsp` with inline function + `map(input, fn)` | Circuit graph has `map` node with expression JSON from inline body |
| 2 | Inline fn overrides external fn_registry entry for same name | Inline body wins |
| 3 | Typespec-only fn (no `:= function(...)` line) + external fn_registry entry | External body used |
| 4 | Typespec-only fn with no external body → error | `missing_function` |

Run: `rebar3 ct --suite=test/gdbsp_compile_SUITE`

### Full Regression

After all phases complete:

```bash
rebar3 ct
```

All existing suites must pass unchanged:
- `gdbsp_parse_SUITE` (10 existing + 16 new = 26 test cases)
- `gdbsp_type_infer_SUITE` (34 test cases)
- `gdbsp_e2e_SUITE` (38 YAML files)
- `gdbsp_compile_lower_SUITE` (28 test cases)
- `gdbsp_compile_SUITE` (12 existing + 4 new = 16 test cases)
- All operator suites (10+ suites)
- `gdbsp_graphviz_SUITE`, `gdbsp_deploy_SUITE`
- `gdbsp_rec_SUITE`, `gdbsp_rec_coord_SUITE`, `gdbsp_rec_integration_SUITE`

### Test File Summary

| File | Action | Tests what |
|------|--------|-----------|
| `test/gdbsp_lexer_SUITE.erl` | CREATE | Lexer tokenization, indentation tracking (Phase 1) |
| `test/parse_fixtures/parse.yaml` | MODIFY | Add 16 new cases for fn defs + expressions (Phase 3) |
| `test/gdbsp_compile_expr_SUITE.erl` | CREATE | `lower_expr/2`, `check_fn_body/3`, `check_all_fns/1`, builtin lookups (Phases 4–5) |
| `test/gdbsp_compile_SUITE.erl` | MODIFY | Add 4 compilation integration cases (Phase 6) |

No changes needed for: `gdbsp_type_infer_SUITE`, `gdbsp_e2e_SUITE`,
`gdbsp_compile_lower_SUITE`, operator suites, rec suites — they use the
fn_registry API that remains unchanged.

---

## 3. Files Summary

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
| CREATE | `test/gdbsp_lexer_SUITE.erl` |
| CREATE | `test/gdbsp_compile_expr_SUITE.erl` |
| MODIFY | `test/parse_fixtures/parse.yaml` |
| MODIFY | `test/gdbsp_compile_SUITE.erl` |
