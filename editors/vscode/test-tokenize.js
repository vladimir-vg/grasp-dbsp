#!/usr/bin/env node
// Tokenizes examples/example.gdbsp with the compiled grammar and reports
// every scope assigned. Used to verify the grammar loads and runs cleanly.

const fs = require('fs');
const path = require('path');
const vsctm = require('vscode-textmate');
const oniguruma = require('vscode-oniguruma');

(async () => {
  const grammarPath = path.join(__dirname, 'syntaxes', 'gdbsp.tmLanguage.json');
  const examplePath = path.join(__dirname, 'examples', 'example.gdbsp');

  const wasmBin = fs.readFileSync(
    path.join(__dirname, 'node_modules', 'vscode-oniguruma', 'release', 'onig.wasm')
  ).buffer;
  const onigLib = oniguruma.loadWASM(wasmBin).then(() => ({
    createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
    createOnigString: (s) => new oniguruma.OnigString(s),
  }));

  const registry = new vsctm.Registry({
    onigLib,
    loadGrammar: async () => JSON.parse(fs.readFileSync(grammarPath, 'utf8')),
  });

  const grammar = await registry.loadGrammar('source.gdbsp');
  if (!grammar) {
    console.error('FAILED to load grammar');
    process.exit(1);
  }

  const lines = fs.readFileSync(examplePath, 'utf8').split(/\r?\n/);
  let stack = null;
  let prevScopes = new Set();
  const allScopes = new Set();

  for (const line of lines) {
    const result = grammar.tokenizeLine(line, stack);
    stack = result.ruleStack;
    const lineScopes = new Set();
    for (const tok of result.tokens) {
      for (const scope of tok.scopes) {
        lineScopes.add(scope);
        allScopes.add(scope);
      }
    }
    // Print only lines whose scope set changed vs the previous line (compact).
    const key = [...lineScopes].sort().join(' ');
    if (key !== [...prevScopes].sort().join(' ')) {
      console.log(`\n${line}`);
      const byStart = result.tokens.map((t) => ({
        start: t.startIndex,
        end: t.endIndex,
        scopes: t.scopes.slice(-2).join(', '),
      }));
      console.log('  ' + byStart.map((t) => `${t.scopes}${JSON.stringify(line.slice(t.start, t.end))}`).join('  |  '));
    }
    prevScopes = lineScopes;
  }

  console.log('\n=== Distinct scopes produced ===');
  console.log([...allScopes].sort().join('\n'));
})().catch((e) => {
  console.error('Grammar error:', e && e.message ? e.message : e);
  process.exit(1);
});
