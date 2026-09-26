// Runtime/ask/test/harness.unit.bun.js — harness.js's own logic, no
// network: window.__native is a script we drive by hand — fetch posts are
// answered with canned SSE, tool posts are counted. Covers the edge cases
// the live test can't reach: a mid-stream failure reaching a parked
// reader, calls batched after `done`, a summary of "done", and steer
// arriving between turns.
//
//   ~/.bun/bin/bun Runtime/ask/test/harness.unit.bun.js

import { join } from 'path';
import { pathToFileURL } from 'url';

const here = new URL('.', import.meta.url).pathname;

globalThis.window = globalThis;
const posts = [];          // every message the page sent
const events = [];         // the {kind:"event"} ones
const fetchIds = [];       // fetch ids in arrival order
let fetchHandler = null;   // (m) => answers a fetch post, async

window.__native = {
  post(m) {
    posts.push(m);
    if (m.kind === 'fetch') {
      fetchIds.push(m.id);
      const h = fetchHandler;
      if (h) setTimeout(() => h(m), 0);
      return;
    }
    if (m.kind === 'tool') {
      return void setTimeout(() => window.__h._tool(m.id, { ok: true, mock: m.name }), 0);
    }
    if (m.kind === 'event') events.push(m);
    // logs dropped — noise
  }
};

await import(pathToFileURL(join(here, '../harness.js')).href);
if (!window.__h) { console.error('harness.js did not define __h'); process.exit(1); }

let pass = 0, fail = 0;
function check(name, ok, detail) {
  console.log((ok ? 'PASS' : 'FAIL') + ' ' + name + (detail ? ' — ' + detail : ''));
  ok ? pass++ : fail++;
}
async function waitFor(pred, ms) {
  const deadline = Date.now() + (ms || 3000);
  while (Date.now() < deadline) { if (pred()) return true; await new Promise(r => setTimeout(r, 10)); }
  return false;
}

// ── #4 a parked lines() reader rejects when the stream dies ─────
// Before the fix, _fetchEnd resolved the waiter {done:true} even with an
// error — a truncated SSE read as a whole one.
{
  const res = window.__h.fetchNative({ url: 'https://unit.test/stream', stream: true });
  const id = fetchIds[fetchIds.length - 1];
  window.__h._fetchMeta(id, 200, '{}');
  window.__h._fetchLine(id, 'data: {"a":1}');
  const it = res.lines();
  const first = await it.next();                    // drains the buffered line
  const parked = it.next();                         // parks — nothing buffered
  window.__h._fetchEnd(id, 0, null, 'socket died mid-stream');
  const outcome = await parked.then(() => 'resolved', e => 'rejected: ' + e.message);
  check('#4 mid-stream failure rejects the parked lines() reader',
        first.value === 'data: {"a":1}' && outcome === 'rejected: socket died mid-stream', outcome);
}

// and a clean end still reads as done, not an error
{
  const res = window.__h.fetchNative({ url: 'https://unit.test/stream2', stream: true });
  const id = fetchIds[fetchIds.length - 1];
  window.__h._fetchMeta(id, 200, '{}');
  const it = res.lines();
  const parked = it.next();
  window.__h._fetchEnd(id, 200, null, null);
  const last = await parked;
  check('#4 clean end still resolves done', last.done === true);
}

// ── #5 + #6 done ends the batch; a summary of "done" is a reply ──
// One canned openrouter stream whose single chunk carries two tool calls:
// done{summary:"done"} and then an eval. The eval must never reach the
// tool bridge, and the user must still see a reply.
{
  posts.length = 0; events.length = 0;
  fetchHandler = (m) => {
    const chunk = 'data: ' + JSON.stringify({
      choices: [{ delta: { tool_calls: [
        { index: 0, id: 'call_1', function: { name: 'done', arguments: '{"summary":"done"}' } },
        { index: 1, id: 'call_2', function: { name: 'eval', arguments: '{"tab":"t1","js":"1"}' } }
      ] } }]
    });
    window.__h._fetchMeta(m.id, 200, '{}');
    window.__h._fetchLine(m.id, chunk);
    window.__h._fetchLine(m.id, 'data: [DONE]');
    window.__h._fetchEnd(m.id, 200, null, null);
  };
  const chat = 'unit-' + crypto.randomUUID();
  window.__h.run({ chat: { id: chat, title: 'unit', model: 'openrouter/unit-model',
                           messages: [{ role: 'you', text: 'hi' }], when: 0 },
                   tabs: [], text: 'hi' });
  const ended = await waitFor(() => events.some(e => e.name === 'done' && e.data.chat === chat));
  check('#5/#6 turn ended', ended);
  const toolPosts = posts.filter(p => p.kind === 'tool');
  check('#5 call after done never executes', toolPosts.length === 0,
        toolPosts.length + ' tool post(s)');
  check('#6 summary "done" still yields a reply',
        events.some(e => e.name === 'delta' && e.data.chat === chat && /done/.test(e.data.text)));
  fetchHandler = null;
}

// ── #7 steer between turns queues for the next run ──────────────
// Before the fix, a steer landing after the last turn's done was dropped —
// Mind had already committed the message, so the line went unanswered.
{
  posts.length = 0; events.length = 0;
  window.__h.steer('while you were out');            // no live turn
  const chat = 'unit-' + crypto.randomUUID();
  window.__h.run({ chat: { id: chat, title: 'unit', model: 'echo/echo',
                           messages: [{ role: 'you', text: 'hello' }], when: 0 },
                   tabs: [], text: 'hello' });
  const ended = await waitFor(() => events.some(e => e.name === 'done' && e.data.chat === chat));
  check('#7 turn ended', ended);
  check('#7 queued steer is marked on the chat',
        events.some(e => e.name === 'delta' && e.data.chat === chat && /\(queued: while you were out\)/.test(e.data.text)));
  check('#7 queued steer reaches the model as a user message',
        events.some(e => e.name === 'delta' && e.data.chat === chat && /Echo: while you were out/.test(e.data.text)));
}

// ── #8 toHistory closes the unresolved-call hole ────────────────
// A tool card with result == null (a killed turn, an ask_user that went
// unanswered) used to replay as a bare tool_call — a provider 400. It now
// gets a synthetic "(ended before it answered)" result.
{
  const hist = window.__h.toHistory([
    { role: 'agent', text: '', tools: [
      { id: 'c1', name: 'ask_user', args: '{"question":"ok?"}', result: null },
      { id: 'c2', name: 'click', args: '{"tab":"t1"}', result: '{"ok":true}' },
      // c3's args don't parse — its call can't replay, so its result must
      // not either (a tool message with no call is an orphan → API error).
      { id: 'c3', name: 'click', args: 'not json {', result: '{"ok":true}' }
    ] },
    { role: 'you', text: 'again' }
  ]);
  const answered = hist.filter(m => m.role === 'tool' && m.callId === 'c2');
  const unresolved = hist.filter(m => m.role === 'tool' && m.callId === 'c1');
  check('#8 unresolved call replays a synthetic tool result',
        unresolved.length === 1 && /ended before it answered/.test(unresolved[0].text),
        JSON.stringify(unresolved));
  check('#8 answered call still replays its own result',
        answered.length === 1 && answered[0].text === '{"ok":true}',
        JSON.stringify(answered));
  // Every tool result still sits beside its call — nothing orphaned.
  const toolResults = hist.filter(m => m.role === 'tool').map(m => m.callId);
  check('#8 no orphaned tool results', toolResults.join(',') === 'c1,c2',
        toolResults.join(','));
}

// ── #9 the turn stamp rides every event ─────────────────────────
// job.chat.turn lands on the run's ctx and echoes in every emit's data —
// the app drops a killed turn's tail by it.
{
  posts.length = 0; events.length = 0;
  const chat = 'unit-' + crypto.randomUUID();
  window.__h.run({ chat: { id: chat, title: 'unit', model: 'echo/echo', turn: 'stamp-1',
                           messages: [{ role: 'you', text: 'hi' }], when: 0 },
                   tabs: [], text: 'hi' });
  const ended = await waitFor(() => events.some(e => e.name === 'done' && e.data.chat === chat));
  check('#9 turn ended', ended);
  const forChat = events.filter(e => e.data && e.data.chat === chat);
  check('#9 every event carries the turn stamp',
        forChat.length > 0 && forChat.every(e => e.data.turn === 'stamp-1'),
        JSON.stringify(forChat.map(e => [e.name, e.data.turn])));
}

// ── #10 chat.effort lands in the body; typed pieces fold into the turn ──
// One openrouter run with effort "high" and a .you message carrying every
// attachment kind: the wire body must carry reasoning.effort, the image a
// real image_url part, the rest context lines ahead of the user text —
// once, though job.attachments repeats the same payload.
{
  posts.length = 0; events.length = 0;
  let wire = null;
  fetchHandler = (m) => {
    wire = m;
    window.__h._fetchMeta(m.id, 200, '{}');
    window.__h._fetchLine(m.id, 'data: ' + JSON.stringify({ choices: [{ delta: { content: 'ok' } }] }));
    window.__h._fetchLine(m.id, 'data: [DONE]');
    window.__h._fetchEnd(m.id, 200, null, null);
  };
  const pieces = [
    { kind: 'site', label: 'Example', url: 'https://example.test' },
    { kind: 'file', label: 'note.txt', path: '/tmp/note.txt', text: 'file words' },
    { kind: 'file', label: 'big.bin', path: '/tmp/big.bin' },
    { kind: 'image', label: 'shot.png', path: '/tmp/shot.png', mime: 'image/png', data: 'QUJD' }
  ];
  const chat = 'unit-' + crypto.randomUUID();
  window.__h.run({ chat: { id: chat, title: 'unit', model: 'openrouter/unit-model', effort: 'high',
                           messages: [{ role: 'you', text: 'look', attachments: pieces }], when: 0 },
                   tabs: [], attachments: pieces, text: 'look' });
  const ended = await waitFor(() => events.some(e => e.name === 'done' && e.data.chat === chat));
  check('#10 turn ended', ended);
  const body = JSON.parse(wire.body);
  check('#10 effort lands as reasoning.effort', body.reasoning && body.reasoning.effort === 'high',
        wire.body.slice(0, 200));
  const user = body.messages.filter(m => m.role === 'user').pop();
  const parts = Array.isArray(user.content) ? user.content : [];
  check('#10 image piece becomes an image_url part',
        parts.some(p => p.type === 'image_url' && p.image_url && p.image_url.url === 'data:image/png;base64,QUJD'),
        JSON.stringify(user.content).slice(0, 300));
  const said = parts.filter(p => p.type === 'text').map(p => p.text).join('\n');
  check('#10 site/file lines precede the user text',
        said.indexOf('[site: https://example.test — Example]') >= 0 &&
        said.indexOf('[file: note.txt]\n```\nfile words\n```') >= 0 &&
        said.indexOf('[file: big.bin at /tmp/big.bin — contents not attached]') >= 0 &&
        said.indexOf('[site:') < said.indexOf('look'),
        said.slice(0, 300));
  check('#10 message attachments are not double-injected',
        (said.match(/\[site:/g) || []).length === 1, said.slice(0, 300));
  fetchHandler = null;
}

// ── #11 "off" maps to each wire's floor; auto sends nothing ───────
{
  const runs = [
    { model: 'openrouter/unit-model', effort: 'off', want: 'none' },
    { model: 'codex/gpt-6-luna', effort: 'off', want: 'minimal' },
    { model: 'openrouter/unit-model', effort: 'low', want: 'low' },
    { model: 'openrouter/unit-model', effort: 'medium', want: 'medium' },
    { model: 'codex/gpt-6-luna', effort: 'high', want: 'high' },
    { model: 'openrouter/unit-model', effort: 'xhigh', want: 'xhigh' },
    { model: 'codex/gpt-6-luna', effort: 'max', want: 'max' },
    { model: 'openrouter/unit-model', effort: undefined, want: null }
  ];
  for (const r of runs) {
    posts.length = 0; events.length = 0;
    let wire = null;
    fetchHandler = (m) => {
      wire = m;
      window.__h._fetchMeta(m.id, 200, '{}');
      window.__h._fetchLine(m.id, r.model.indexOf('codex') === 0
        ? 'data: ' + JSON.stringify({ type: 'response.output_text.delta', delta: 'ok' })
        : 'data: ' + JSON.stringify({ choices: [{ delta: { content: 'ok' } }] }));
      window.__h._fetchLine(m.id, 'data: [DONE]');
      window.__h._fetchEnd(m.id, 200, null, null);
    };
    const chat = 'unit-' + crypto.randomUUID();
    const c = { id: chat, title: 'unit', model: r.model, messages: [{ role: 'you', text: 'hi' }], when: 0 };
    if (r.effort !== undefined) c.effort = r.effort;
    window.__h.run({ chat: c, tabs: [], text: 'hi' });
    const ended = await waitFor(() => events.some(e => e.name === 'done' && e.data.chat === chat));
    const body = wire && JSON.parse(wire.body);
    check('#11 ' + r.model + ' effort ' + (r.effort || 'auto') + ' → ' + (r.want || '(absent)'),
          ended && !!body &&
          (r.want == null ? !body.reasoning : !!(body.reasoning && body.reasoning.effort === r.want)),
          wire ? wire.body.slice(0, 160) : 'no fetch');
    fetchHandler = null;
  }
}

// ── #12 job.attachments is the fallback when the message kept none ──
{
  posts.length = 0; events.length = 0;
  let wire = null;
  fetchHandler = (m) => {
    wire = m;
    window.__h._fetchMeta(m.id, 200, '{}');
    window.__h._fetchLine(m.id, 'data: ' + JSON.stringify({ choices: [{ delta: { content: 'ok' } }] }));
    window.__h._fetchLine(m.id, 'data: [DONE]');
    window.__h._fetchEnd(m.id, 200, null, null);
  };
  const chat = 'unit-' + crypto.randomUUID();
  window.__h.run({ chat: { id: chat, title: 'unit', model: 'openrouter/unit-model',
                           messages: [{ role: 'you', text: 'look' }], when: 0 },
                   tabs: [], text: 'look',
                   attachments: [{ kind: 'site', label: 'Example', url: 'https://example.test' },
                                 { kind: 'image', label: 'shot.png', path: '/p/shot.png', mime: 'image/png', data: 'QUJD' }] });
  const ended = await waitFor(() => events.some(e => e.name === 'done' && e.data.chat === chat));
  const body = JSON.parse(wire.body);
  const user = body.messages.filter(m => m.role === 'user').pop();
  const parts = Array.isArray(user.content) ? user.content : [];
  const said = parts.filter(p => p.type === 'text').map(p => p.text).join('\n');
  check('#12 job.attachments fold in when the message has none',
        ended && said.indexOf('[site: https://example.test — Example]') >= 0 && said.indexOf('[site:') < said.indexOf('look'),
        said.slice(0, 200));
  check('#12 job.attachments image rides as a part too',
        parts.some(p => p.type === 'image_url' && p.image_url && p.image_url.url === 'data:image/png;base64,QUJD'));
  fetchHandler = null;
}

// ── #13 toHistory: images degrade off-image wires; tabs ride as `tabs` ──
{
  const pieceMsg = [{ role: 'you', text: 'x', attachments: [
    { kind: 'image', label: 's.png', path: '/p/s.png', mime: 'image/png', data: 'QUJD' }] }];
  const noImages = window.__h.toHistory(pieceMsg);
  check('#13 image degrades to a text line without provider.images',
        noImages.length === 1 && noImages[0].text === '[image: s.png at /p/s.png]\nx' && !noImages[0].images,
        JSON.stringify(noImages));
  const withImages = window.__h.toHistory(pieceMsg, { images: true });
  check('#13 provider.images carries it as a part',
        withImages.length === 1 && withImages[0].text === 'x' &&
        !!withImages[0].images && withImages[0].images[0] === 'data:image/png;base64,QUJD',
        JSON.stringify(withImages));
  const tabs = window.__h.toHistory([{ role: 'you', text: 'x',
    tabs: [{ id: 't1', title: 'T', address: 'https://a.b' }] }]);
  check('#13 tab chips ride the renamed `tabs` field',
        tabs[0].text === '[attached tabs: T <https://a.b>]\nx', tabs[0].text);
}

// ── #14 toHistory: a kind-less `attachments` entry is still a tab chip ──
// Before the fields split, the wire's chips travelled under `attachments`;
// entries without a `kind` keep landing in the "[attached tabs: …]" line.
{
  const hist = window.__h.toHistory([{ role: 'you', text: 'old',
    attachments: [{ id: 't-old', title: 'Old Tab', address: 'https://old.example' }] }]);
  check('#14 legacy kind-less attachment rides as a tab chip',
        hist.length === 1 && hist[0].role === 'user' &&
        hist[0].text === '[attached tabs: Old Tab <https://old.example>]\nold',
        JSON.stringify(hist));
}

console.log('---');
console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
