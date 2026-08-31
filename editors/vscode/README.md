# Grasp DBSP for Visual Studio Code

Syntax highlighting for the **Grasp DBSP** language (`.gdbsp` files).

Grasp DBSP is a differential-dataflow language for streaming relational
queries. This extension provides TextMate grammar-based highlighting for its
full syntax: node/operator definitions, type annotations, function and
aggregate-function declarations, circuit definitions, and the expression
language (literals, operators, struct/array/map literals, subscripts/slices,
and `std.*` builtin calls).

## Features

- Highlighting for `.gdbsp` source files (language id `gdbsp`).
- `#` line comments, bracket matching, auto-closing pairs, and
  indentation-based folding (`offSide`) for circuit bodies.
- Distinct scopes for keywords, operators, type names, literals, function
  names, operator names (`source`, `map`, `join`, …), and `std.*` namespaced
  builtins.

## Development

```bash
npm install
npm run build-grammar   # regenerate syntaxes/gdbsp.tmLanguage.json from the .yml
npm test                # tokenize examples/example.gdbsp and dump scopes
```

The grammar is authored in `syntaxes/gdbsp.tmLanguage.yml` and compiled to
JSON by `build-grammar.js` (via `js-yaml`). Edit the `.yml`, then rebuild.

To test locally, open this folder in VS Code and press `F5` to launch an
Extension Development Host, then open `examples/example.gdbsp`.

## Release Notes

See [CHANGELOG.md](./CHANGELOG.md).
