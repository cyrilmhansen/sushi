#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const html = fs.readFileSync(new URL('../src/webui/index.html', import.meta.url), 'utf8');
const script = html.match(/<script id="dashboardScript">([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, 'dashboard script exists');

function actualFunction(name, endMarker, args, bindings) {
  const start = script.indexOf(`function ${name}(`);
  const end = script.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `${name} source is present`);
  const source = script.slice(start, end).trim();
  return new Function(...args, `${source}; return ${name};`)(...bindings);
}

test('dashboard write-origin metrics use the real element and render absent, empty and populated data', () => {
  assert.match(html, /id="dashWriteOrigins"/);

  const selectorExpr = script.match(/const \$ = id => ([\s\S]*?);/)?.[1];
  assert.ok(selectorExpr, 'dashboard element selector exists');
  const elements = new Map([['dashWriteOrigins', { id: 'dashWriteOrigins', tagName: 'DIV', addEventListener() {} }]]);
  const $ = new Function('document', `return id => ${selectorExpr};`)({ getElementById: id => elements.get(id) ?? null });
  assert.equal($('write-origins')?.id, 'dashWriteOrigins', 'dashboard suffix selects the intended node');

  const setHtml = (el, value) => { el.html = value; };
  const renderer = actualFunction('renderWriteOrigins', '\n  function push(',
    ['setHtml', 'esc', 'bytes', 'fmtInt', 'WRITE_KINDS', 'writeOriginExpansion'],
    [setHtml, String, value => `${value} B`, String, {}, new Map()]);
  const writeMetrics = actualFunction('prefixWrites', '\n  const writeOriginExpansion',
    ['bytes'], [value => String(value)]);
  const renderCall = script.match(/renderWriteOrigins\(\$\('write-origins'\), writes\?\.origins\);/)?.[0];
  assert.ok(renderCall, 'render path calls the origin renderer with the selected element');
  const render = new Function('$', 'renderWriteOrigins', 'writes', renderCall);

  const element = elements.get('dashWriteOrigins');
  assert.doesNotThrow(() => render($, renderer, writeMetrics(undefined)), 'metrics rendering continues when origin metrics are absent');
  assert.equal(element.html, '');
  assert.doesNotThrow(() => render($, renderer, writeMetrics({ written_bytes: {}, origins: {} })), 'metrics rendering continues when origins are empty');
  assert.match(element.html, /<table>[\s\S]*<tbody><\/tbody>/);

  const writes = writeMetrics({
    written_bytes: { ssm: 64 },
    origins: { decode_end: { ssm_files: 1, total_bytes: 64, written_bytes: { ssm: 64 } } },
  });
  assert.doesNotThrow(() => render($, renderer, writes));
  assert.match(element.html, /<table>/);
  assert.match(element.html, /Decode end/);
  assert.match(element.html, /64 B/);
});
