# Grasp DBSP — Syntax Specification

Date: 2026-08-23
Status: current

---

## 1. Lexical Tokens

### 1.1 Comments and Whitespace

```
comment    := "#" [^\n]* NEWLINE
whitespace := space | tab
```

Comments and whitespace are discarded by the lexer. They do not produce tokens.

### 1.2 Keywords

```
keyword := "function" | "aggregate_function" | "circuit" | "fixpoint"
         | "stream" | "struct" | "array" | "map" | "optional"
         | "closure" | "result_equivalent_closure"
         | "not" | "and" | "or"
         | "true" | "false" | "null" | "absent"
         | "input" | "eval" | "enum"
```

Operator names (`source`, `delay`, `map`, `join`, `plus`, `integrate`, etc.)
are context-dependent — they are lexed as identifiers and recognized as
operators by the parser based on position on the right-hand side of `:=`.

### 1.3 Operators and Delimiters

```
operator  := ":=" | "::" | "->" | "**"
           | "!=" | ">=" | "<=" | "="
           | "++" | "<<<" | ">>>" | "<<" | ">>"
           | "+" | "-" | "*" | "/" | "%"
           | "|" | "^" | "&" | "~" | "."
           | ">" | "<" | ":" | ","
           | "(" | ")" | "{" | "}" | "[" | "]"
```

### 1.4 Literals

```
integer_literal := DIGIT+
decimal_literal := DIGIT+ "." DIGIT+ ("e"|"E" ("+"|"-")? DIGIT+)?
float_literal   := DIGIT+ ("e"|"E" ("+"|"-")? DIGIT+)
bits_literal    := "0b" ("0"|"1")+
string_literal  := "\"" (escape | [^"])* "\""

DIGIT := [0-9]
```

### 1.5 Identifiers

```
identifier := LETTER (LETTER | DIGIT | "_")* (":" LETTER (LETTER | DIGIT | "_")*)*
LETTER     := [a-zA-Z]
```

Supports bare names (`x`, `my_func`) and dotted names (`std.add_i64`,
`std.string_upper`, `std.struct_get`). Dotted names are parsed from
`identifier` `.` `identifier` token sequences and joined into a single name
by the parser (`parse_compound_name/2`).

---

## 2. Program Structure

```
program      := declaration*
declaration  := node_def | typespec | fn_def | circuit_def | comment
```

Declarations may appear in any order. Forward references are allowed across
all declaration types.

---

## 3. Node Definitions

```
node_def := NAME ":=" node_rhs

node_rhs := OP "(" args? ")"            # known operator
          | NAME "(" kw_args ")"        # circuit instantiation
          | NAME "." NAME               # circuit access
          | NAME                        # plus alias

OP       := "source" | "delay" | "integrate" | "differentiate"
          | "distinct" | "plus" | "neg" | "map" | "flat_map"
          | "join" | "aggregate" | "filter" | "project"
          | "antijoin" | "fixpoint"

args     := arg ("," arg)*
arg      := NAME                        # variable reference to another node
          | STRING                      # string literal (e.g. table name)
          | kw_kwarg

kw_kwarg := NAME ":" "[" STRING ("," STRING)* "]"
          | NAME ":" STRING
          | NAME ":" NAME              # value field reference
```

### 3.1 Multiline Node Definitions

The opening `(` may be followed by a newline, with arguments on subsequent
lines, and the closing `)` on the same line as the last argument or on its own
line:

```
merged := plus(
  a,
  b,
  c
)
```

---

## 4. Type Annotations (Typespecs)

```
typespec := NAME "::" type_rhs

type_rhs := "stream" "(" type ")"
          | "function" "(" "(" fn_type_params? ")" "->" type ")"
          | "aggregate_function" "(" "(" fn_type_params? ")" "->" type ")"

fn_type_params := fn_type_param ("," fn_type_param)*
fn_type_param  := type                    # positional
                | STRING ":" type         # keyword
```

Positional params must precede keyword params. The `stream(...)` wrapper is
required for source node type annotations. Function and aggregate typespecs
use double parentheses: `function((params) -> ret)`.

### 4.1 Type Grammar

```
type := scalar_type
      | "stream" "(" type ")"
      | "struct" "(" struct_fields ")"
      | "array" "(" type ")"
      | "array" "(" type "," INTEGER ("," INTEGER)* ")"
      | "map" "(" type "," type ")"
      | "optional" "(" type ")"
      | "closure" "(" "(" fn_type_params? ")" "->" type ")"
      | "result_equivalent_closure" "(" "(" fn_type_params? ")" "->" type ")"
      | TYPE_VAR                          # uppercase-first identifier

scalar_type := "i8" | "i16" | "i32" | "i64"
             | "u8" | "u16" | "u32" | "u64"
             | "integer" | "f32" | "f64" | "numeric"
             | "numeric" "(" INTEGER "," INTEGER ")"
             | "string" "(" STRING ")" | "string_with_encoding"
             | "bytes" | "bytes" "(" INTEGER ")"
             | "bits" | "bits" "(" INTEGER ")"
             | "enum" "(" STRING ("," STRING)* ")"
             | "date" | "time" | "timestamp" | "timestamp_with_timezone"
             | "interval" | "json" | "dynamic"

struct_fields := struct_field ("," struct_field)*
struct_field  := (NAME | STRING) ":" type
```

---

## 5. Function Definitions

```
fn_def := NAME ":=" "function" "(" fn_params "->" expr ")"

fn_params := fn_param ("," fn_param)*
fn_param  := NAME                    # positional: param name
           | NAME ":"                # keyword shorthand: key = var = NAME
           | NAME ":" NAME            # keyword explicit: key, var_name
```

Positional params must precede keyword params. Types are never present in
the function definition — they come exclusively from the matching `.gdbsp`
typespec. The body `expr` is a full expression (see §6).

A function must have a matching `:: function(...)` typespec. The typespec
and definition may appear in any order. A typespec without a definition
is allowed — the body is sourced from the external JSON function registry.

### 5.1 Parameter Shorthand

```
# Keyword shorthand — key and variable name are identical:
f := function((a, b, d:, e:) -> a + b + d + e)

# Equivalent explicit form:
f := function((a, b, d: d, e: e) -> a + b + d + e)

# Different key and variable name:
f := function((x, y, d: dvar, e: evar) -> x + y + dvar + evar)
```

### 5.2 Matching Typespec and Definition

- Positional params: matched by index. Count must be equal.
- Keyword params: matched by key NAME. Keys declared in the typespec must all
  be present in the definition. Extra definition keyword params (not in the
  typespec) are an error.
- Typespec keyword param keys use quoted strings (e.g., `"d": i64`); definition
  keyword param keys use bare identifiers (e.g., `d:`). The parser strips quotes
  from the typespec key for comparison.

```
# Typespec:
add :: function((i64, i64, d: i64, e: i64) -> i64)

# Definition:
add := function((x, y, d:, e:) -> x + y + d + e)
# param 0: i64 → positional x
# param 1: i64 → positional y
# param 2: d: i64 → keyword d (key matches, var = d)
# param 3: e: i64 → keyword e (key matches, var = e)
```

### 5.3 Type Variables

Type variables in function typespecs (uppercase identifiers like `T`, `K`, `V`)
are resolved at the call site by unification. Inline function bodies currently
require **exact (concrete) types** in the typespec — generic functions with type
variables in the typespec must use externally-provided JSON bodies. Type-variable
unification is implemented (`gdbsp_builtins:unify_types/3`) and used for
operator/overload resolution, but it is not applied to inline function bodies.

---

## 6. Expressions

Expressions appear in function body definitions. The expression grammar
supports the full Grasp expression syntax with the following exceptions:

- **Aggregate expressions** (`count<>`, `sum<col>`) — reserved for
  `aggregate_function` bodies (future).
- **Closure expressions** (`closure((x: T) -> body)`) — deferred to future
  work.

Both produce parse errors if encountered in a function body expression.

### 6.1 Precedence (Low to High)

| Level | Operators | Associativity |
|-------|-----------|---------------|
| 1 | `or` | left |
| 2 | `and` | left |
| 3 | `=`, `!=`, `<`, `<=`, `>`, `>=` | none (no chaining) |
| 4 | `++` (concatenation) | left |
| 5 | `\|` (bit-or), `^` (bit-xor) | left, same-op only |
| 6 | `&` (bit-and) | left |
| 7 | `<<`, `>>`, `<<<`, `>>>` (shift/rotate) | none (no chaining) |
| 8 | `+`, `-` (add/sub) | left |
| 9 | `*`, `/`, `%` (mul/div/mod) | left |
| 10 | `not`, `-` (unary), `~` (bit-not) | prefix |

Cross-group mixing without parentheses is an error. For example, `a + b < c`
produces `cross_group_arithmetic`. Use parentheses: `(a + b) < c`.

### 6.2 Atomic Expressions

```
atomic := literal
        | NAME                              # variable or param reference
        | NAME "(" fun_args? ")"            # function call
        | "{" kv_args "}"                   # map literal
        | "{" kv_args "," "**" NAME "}"     # map literal with rest spread
        | "[" expr_args? "]"                # array literal
        | "[" expr_args "," "*" NAME "]"    # array literal with rest spread
        | "(" expr ")"                      # grouping
        | atomic "." NAME                   # dot access (struct field)
        | atomic "[" expr "]"               # subscript
        | atomic "[" expr? ":" expr? (":" expr?)? "]"  # slice
```

### 6.3 Literals

```
literal := INTEGER | DECIMAL | FLOAT | BITS | STRING
         | "true" | "false" | "null" | "absent"
```

### 6.4 Function Call Arguments

```
fun_args := pos_args ("," kw_args)?
          | kw_args

pos_args := expr ("," expr)*
kw_args  := kw_arg ("," kw_arg)*
kw_arg   := NAME ":" expr
          | NAME ":"                        # shorthand: value = {var, NAME}
```

Positional arguments must precede keyword arguments.

### 6.5 Operator Desugaring

Binary and unary operators are desugared to function calls during lowering.
Parse expressions (`parse_expr()`) preserve the operator AST; the desugaring
happens during lowering to the runtime expression format. The desugared
function name is the operator character itself (not a named alias): `+` lowers
to a call to `+`, `&` to `&`, `not` to `not`, and so on. At type-check time
each operator call is resolved to a concrete stdlib function (`std.add_i64`,
`std.eq_string`, `std.bits_and`, …) based on operand types — see
[stdlib.md](stdlib.md) §3.

| Operator | Desugared function name |
|----------|------------------------|
| `+` | `+` |
| `-` (binary) | `-` |
| `-` (unary) | `-` |
| `*` | `*` |
| `/` | `/` |
| `%` | `%` |
| `=` | `=` |
| `!=` | `!=` |
| `<` | `<` |
| `<=` | `<=` |
| `>` | `>` |
| `>=` | `>=` |
| `and` | `and` |
| `or` | `or` |
| `not` | `not` |
| `++` | `++` |
| `\|` | `\|` |
| `^` | `^` |
| `&` | `&` |
| `<<` | `<<` |
| `>>` | `>>` |
| `<<<` | `<<<` |
| `>>>` | `>>>` |
| `~` | `~` |

### 6.6 Syntactic Desugaring

Some parse expression forms are desugared to function calls during lowering:

| Parse expression | Runtime expression |
|---|---|
| `r.field` | `std.struct_get(r, key: "field")` |
| `{k1: v1, k2: v2}` | `map(k1: v1, k2: v2)` |
| `[e1, e2, e3]` | `array(e1, e2, e3)` |

The `struct`, `array`, `map`, and `map_merge` constructors are special-cased
during type inference and evaluation; they are not resolved through stdlib.

---

## 7. Circuit Definitions

```
circuit_def := "circuit" NAME "(" circuit_params ")" ":"
                 body_line*
               (dedent)

circuit_params := circuit_param ("," circuit_param)*
circuit_param  := NAME ":" NAME     # keyword: internal_name
```

Circuit definitions are described in [circuits.md](circuits.md).
Fixpoint instantiation is described in [fixpoint-circuits.md](fixpoint-circuits.md).
