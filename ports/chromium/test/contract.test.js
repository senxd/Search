import { test } from 'node:test';
import assert from 'node:assert/strict';
import { address, searchTemplate } from '../src/address.js';
import { shouldBlock } from '../src/page-scripts.js';
import { EngineRegistry, CONTRACT_VERSION, REQUIRED_METHODS } from '../src/contract.js';

test('addresses preserve explicit URLs, encode searches, and reject executable schemes', () => {
  assert.equal(address('localhost:8080/a'), 'http://localhost:8080/a');
  assert.equal(address('example.com/a'), 'https://example.com/a');
  assert.equal(address('a & b', 'https://duckduckgo.com/?q=%s'), 'https://duckduckgo.com/?q=a%20%26%20b');
  for (const value of ['javascript:alert(1)', 'file:///etc/passwd', 'data:text/html,x', 'https://name:pass@example.com']) assert.throws(() => address(value));
  assert.throws(() => searchTemplate('https://%s.example.com/'));
  assert.throws(() => searchTemplate('https://example.com/no-placeholder'));
});

test('shield matches domain boundaries, preserves first-party requests, and supports overrides', () => {
  assert.equal(shouldBlock('https://stats.google-analytics.com/tag.js', 'https://example.com'), true);
  assert.equal(shouldBlock('https://notgoogle-analytics.com/tag.js', 'https://example.com'), false);
  assert.equal(shouldBlock('https://google-analytics.com/tag.js', 'https://google-analytics.com'), false);
  assert.equal(shouldBlock('https://google-analytics.com/tag.js', 'https://example.com', false), false);
});

test('engine registration rejects invalid adapters and duplicate names', () => {
  const registry = new EngineRegistry();
  registry.register('bad', () => ({ id: 'bad', version: CONTRACT_VERSION }));
  assert.throws(() => registry.create('bad'), { code: 'INVALID_ADAPTER' });
  assert.throws(() => registry.create('missing'), { code: 'UNKNOWN_ENGINE' });
  assert.throws(() => registry.register('bad', () => {}), { code: 'INVALID_ENGINE' });
  registry.register('ok', () => ({ id: 'ok', version: CONTRACT_VERSION, capabilities: {}, ...Object.fromEntries(REQUIRED_METHODS.map(method => [method, async () => {}])) }));
  assert.equal(registry.create('ok').id, 'ok');
});
