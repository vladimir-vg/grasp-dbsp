#!/usr/bin/env node
// Converts syntaxes/gdbsp.tmLanguage.yml → syntaxes/gdbsp.tmLanguage.json

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const src = path.join(__dirname, 'syntaxes', 'gdbsp.tmLanguage.yml');
const dst = path.join(__dirname, 'syntaxes', 'gdbsp.tmLanguage.json');

const doc = yaml.load(fs.readFileSync(src, 'utf8'));
fs.writeFileSync(dst, JSON.stringify(doc, null, '\t') + '\n');
console.log('Built', dst);
