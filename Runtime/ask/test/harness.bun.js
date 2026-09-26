// Runtime/ask/test/harness.bun.js — exercise harness.js against the real
// network under bun. The `window.__native` bridge is faked: fetch → bun's
// fetch with keys injected the way Harness.swift injects them, tool → mocks.
//
//   ~/.bun/bin/bun run Runtime/ask/test/harness.bun.js
//
// Keys come from the test world's own file — never hardcoded:
//   ~/Library/Application Support/Search (test)/ask.keys.json

import { readFileSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';
import { pathToFileURL } from 'url';

const here = new URL('.', import.meta.url).pathname;
const keysPath = join(homedir(), 'Library/Application Support/Search (test)/ask.keys.json');
const keys = JSON.parse(readFileSync(keysPath, 'utf8'));
const mask = (s) => (s ? s.slice(0, 10) + '…' + s.slice(-2) : '(unset)');
console.log('keys: ' + Object.keys(keys).map(k => k + '=' + mask(JSON.stringify(keys[k]).replace(/^"|"$/g, ''))).join(' '));

// ── the fake native side ─────────────────────────────────────────

globalThis.window = globalThis;
const events = [];
const inflight = {};

window.__native = {
  post(m) {
    if (m.kind === 'fetch') return void handleFetch(m);
    if (m.kind === 'abort') return void (inflight[m.id] && inflight[m.id].abort());
    if (m.kind === 'tool') return void setTimeout(() => window.__h._tool(m.id, mockTool(m.name, m.args)), 0);
    if (m.kind === 'event') { events.push(m); report(m); return; }
    if (m.kind === 'log') console.log('[harness]', m.text);
  }
};

async function handleFetch(m) {
  const headers = { ...(m.headers || {}) };
  // the same injection Harness.swift does server-side
  if (m.auth === 'openrouter' && keys.openrouter) headers['authorization'] = 'Bearer ' + keys.openrouter;
  if (m.auth === 'codex' && keys.codex) {
    try {
      let c = JSON.parse(keys.codex);
      if (c.tokens) c = c.tokens;
      headers['authorization'] = 'Bearer ' + c.access_token;
      headers['chatgpt-account-id'] = c.account_id;
    } catch {}
  }
  if (m.auth === 'devin' && keys.devin) headers['authorization'] = 'Bearer ' + keys.devin;
  const ac = new AbortController();
  inflight[m.id] = ac;
  try {
    const res = await fetch(m.url, { method: m.method || 'GET', headers, body: m.body, signal: ac.signal });
    const hs = {};
    res.headers.forEach((v, k) => { hs[k.toLowerCase()] = v; });
    window.__h._fetchMeta(m.id, res.status, JSON.stringify(hs));
    if (m.stream) {
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let i;
        while ((i = buf.indexOf('\n')) >= 0) {
          let line = buf.slice(0, i);
          buf = buf.slice(i + 1);
          if (line.endsWith('\r')) line = line.slice(0, -1);
          window.__h._fetchLine(m.id, line);
        }
      }
      if (buf.trim()) window.__h._fetchLine(m.id, buf);
      window.__h._fetchEnd(m.id, res.status, null, null);
    } else {
      window.__h._fetchEnd(m.id, res.status, await res.text(), null);
    }
  } catch (e) {
    window.__h._fetchEnd(m.id, 0, null, String((e && e.message) || e));
  } finally {
    delete inflight[m.id];
  }
}

// Every Drive op answered with something plausible; "Paris" is planted so a
// lookup-style call has an answer to find.
function mockTool(name, args) {
  switch (name) {
    case 'page.eval': case 'page.code': return { value: 'Paris' };
    case 'page.text': return { text: 'The capital of France is Paris.', truncated: false, url: 'https://example.test', title: 'Example' };
    case 'page.snapshot': return { snapshot: 'page Example\n  text "The capital of France is Paris."\n  link "Paris" [ref=e1]', version: 1, url: 'https://example.test', title: 'Example' };
    case 'tabs.list': return { tabs: [{ id: 't1', url: 'https://example.test', title: 'Example', loading: false }] };
    case 'tabs.attach': return { id: args.id, attached: true };
    case 'tabs.open': case 'page.go': return { id: args.tab || 't1', url: args.url || 'https://example.test' };
    case 'page.wait': return { id: args.tab, url: 'https://example.test', title: 'Example', loading: false };
    case 'page.screenshot': return { path: '/tmp/mock.png', width: 800, height: 600 };
    default: return { ok: true, note: 'mock ' + name };
  }
}

// ── transcript ───────────────────────────────────────────────────

let streamBuf = '';
function report(m) {
  if (m.name === 'delta') {
    streamBuf += m.data.text;
    process.stdout.write(m.data.text);
  } else if (m.name === 'tool') {
    const t = m.data.tool;
    console.log('\n  ⚙ ' + t.name + ' ' + t.args + (t.result != null ? ' → ' + JSON.stringify(t.result).slice(0, 300) : ' (running)'));
  } else if (m.name === 'activity') {
    if (m.data.text) console.log('\n  … ' + m.data.text);
  } else if (m.name === 'message') {
    console.log('\n— final message kept: ' + JSON.stringify(m.data.message.text).slice(0, 400) +
      ' (' + m.data.message.tools.length + ' tool cards)');
  } else if (m.name === 'done') {
    console.log('\n— done (error=' + JSON.stringify(m.data.error) + ')');
  }
}

// ── the run ──────────────────────────────────────────────────────

await import(pathToFileURL(join(here, '../harness.js')).href);
if (!window.__h) { console.error('harness.js did not define __h'); process.exit(1); }

// `bun run harness.bun.js [model]` — defaults to the cheapest real brain
// whose key exists: codex's ChatGPT login, else openrouter.
const MODEL = process.argv[2] || (keys.codex ? 'codex/gpt-6-luna' : 'openrouter/z-ai/glm-5.3-flash');
const PROMPT = 'Do not write a text reply. First call the eval tool (tab "t1", ' +
  'js "\\"Paris\\"") to look up the answer, then IMMEDIATELY call the done tool ' +
  'whose summary is the answer: what is the capital of France?';

const chat = 'bun-' + crypto.randomUUID();
console.log('model: ' + MODEL + '\nprompt: ' + PROMPT + '\n---');
window.__h.run({
  chat: { id: chat, title: 'bun test', model: MODEL,
          messages: [{ role: 'you', text: PROMPT }], when: 0 },
  tabs: [],
  text: PROMPT
});

const deadline = Date.now() + 120000;
while (Date.now() < deadline) {
  if (events.some(e => e.name === 'done')) break;
  await new Promise(r => setTimeout(r, 100));
}

// ── assertions ───────────────────────────────────────────────────

const deltas = events.filter(e => e.name === 'delta');
const tools = events.filter(e => e.name === 'tool');
const doneEv = events.filter(e => e.name === 'done').pop();
const toolsFinished = tools.filter(e => e.data.tool.result != null);
const sawParis = toolsFinished.some(e => /paris/i.test(JSON.stringify(e.data.tool.result || ''))) || /paris/i.test(streamBuf);
const calledDone = toolsFinished.some(e => e.data.tool.name === 'done');

console.log('---');
console.log((deltas.length > 0 ? 'PASS' : 'FAIL') + ' deltas streamed (' + deltas.length + ')');
console.log((toolsFinished.length > 0 ? 'PASS' : 'FAIL') + ' tool round-trip (' + toolsFinished.length + ' finished)');
console.log((sawParis ? 'PASS' : 'FAIL') + ' "Paris" came back through the loop');
console.log((calledDone ? 'PASS' : 'FAIL') + ' done tool called');
console.log((doneEv ? 'PASS' : 'FAIL') + ' done event (error=' + JSON.stringify(doneEv && doneEv.data.error) + ')');
process.exit(doneEv && deltas.length && toolsFinished.length && calledDone ? 0 : 1);
