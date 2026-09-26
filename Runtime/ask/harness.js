// Runtime/ask/harness.js — Ask's agent loop.
//
// Hosted in a hidden WKWebView (Sources/Search/Harness.swift); also loads
// under bun for tests (Runtime/ask/test/harness.bun.js). ES2020, no imports —
// the file is inlined into loadHTMLString. Two rules hold the design up:
//
//   * no network of its own. window.fetch is never touched — every request
//     crosses window.__native.post({kind:"fetch",…}) into Swift, which owns
//     URLSession and injects credentials server-side. The page never holds
//     a key; it names a provider (`auth:"openrouter"`) and Swift attaches it.
//   * one window.__h namespace, both ways: run/steer/stop come in from the
//     app, _fetchMeta/_fetchLine/_fetchEnd/_tool are its bridge replies, and
//     fetchNative/tool are the same doors used by tests.
//
// The loop: history → provider stream → text deltas ({kind:"event",
// name:"delta"}) + tool calls → execute via the bridge → results back as
// messages → repeat until the model stops calling tools, calls `done`, or
// hits the step cap.
(function () {
'use strict';

// ── small things ─────────────────────────────────────────────────

function uuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
    var r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 3 | 8)).toString(16);
  });
}
function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
function trim(s, n) {
  s = String(s == null ? '' : s);
  return s.length > n ? s.slice(0, n) + '…' : s;
}
function now() { return Date.now() / 1000 - 978307200; } // Cocoa ref-date seconds
function tabId(id) { return String(id).split('-')[0].toLowerCase(); }
function parseArgs(text) {
  if (text == null) return {};
  if (typeof text === 'object') return text;
  try { return JSON.parse(text); } catch (e) { return { _raw: String(text) }; }
}
function post(message) { if (window.__native) window.__native.post(message); }
function log(text) {
  if (window.__native) post({ kind: 'log', text: String(text) });
  else if (typeof console !== 'undefined') console.log('[harness]', text);
}
// Every event carries the turn's stamp (job.chat.turn, set by the app on
// run) so a killed turn's trailing emits can't write into the turn that
// took its place — Harness drops what doesn't match the live stamp.
// Stamped by the emitting ctx, never the global: an old ctx's tail must
// keep the old stamp even after a new run has taken `current`.
function emit(ctx, name, data) {
  if (ctx && ctx.turn != null && data && typeof data === 'object' && data.turn == null) data.turn = ctx.turn;
  post({ kind: 'event', name: name, data: data });
}

// ── the native fetch ─────────────────────────────────────────────
// {kind:"fetch", id, url, method, headers, body, stream, auth} leaves;
// _fetchMeta/_fetchLine×n/_fetchEnd come back. stream → lines arrive as the
// response does; otherwise the whole body lands on _fetchEnd.

var seq = 0;
var fetches = {};
var pendingTools = {};

function fetchNative(spec) {
  var id = ++seq;
  var f = fetches[id] = {
    status: 0, headers: {}, body: '', error: null, done: false,
    lines: [], waiting: null, waitingBody: null, waitingMeta: null
  };
  post({
    kind: 'fetch', id: id,
    url: spec.url, method: spec.method || 'GET',
    headers: spec.headers || {}, body: spec.body == null ? null : String(spec.body),
    stream: !!spec.stream, auth: spec.auth || null
  });
  var res = {
    id: id,
    get status() { return f.status; },
    get ok() { return f.status >= 200 && f.status < 300; },
    get body() { return f.body; },
    get error() { return f.error; },
    headers: { get: function (name) { return f.headers[String(name).toLowerCase()] || null; } },
    text: function () { return settled(f).then(function () { return f.body; }); },
    json: function () { return res.text().then(JSON.parse); },
    // resolves once _fetchMeta has landed (or the request died first) —
    // status/ok are meaningless before it
    ready: function () {
      if (f.status || f.done || f.error) return Promise.resolve();
      return new Promise(function (resolve) { f.waitingMeta = resolve; });
    },
    // an async iterator over response lines — the SSE door
    lines: function () {
      return {
        next: function () {
          if (f.lines.length) return Promise.resolve({ value: f.lines.shift(), done: false });
          if (f.error) return Promise.reject(new Error(f.error));
          if (f.done) return Promise.resolve({ value: undefined, done: true });
          return new Promise(function (resolve, reject) { f.waiting = { resolve: resolve, reject: reject }; });
        },
        [Symbol.asyncIterator]: function () { return this; }
      };
    },
    abort: function () { post({ kind: 'abort', id: id }); }
  };
  return res;
}

function settled(f) {
  if (f.error) return Promise.reject(new Error(f.error));
  if (f.done) return Promise.resolve();
  return new Promise(function (resolve, reject) { f.waitingBody = { resolve: resolve, reject: reject }; });
}

function _fetchMeta(id, status, headersJSON) {
  var f = fetches[id]; if (!f) return;
  f.status = status || 0;
  try { f.headers = JSON.parse(headersJSON || '{}'); } catch (e) { f.headers = {}; }
  if (f.waitingMeta) { var w = f.waitingMeta; f.waitingMeta = null; w(); }
}
function _fetchLine(id, line) {
  var f = fetches[id]; if (!f) return;
  f.body += line + '\n';
  if (f.waiting) { var w = f.waiting; f.waiting = null; w.resolve({ value: line, done: false }); }
  else f.lines.push(line);
}
function _fetchEnd(id, status, body, error) {
  var f = fetches[id]; if (!f) return;
  if (status) f.status = f.status || status;
  if (typeof body === 'string') f.body = body;
  if (error) f.error = String(error);
  f.done = true;
  // A dead stream throws on whoever is parked reading it — a quiet
  // {done:true} would pass a truncated body off as a whole one.
  if (f.waiting) {
    var w = f.waiting; f.waiting = null;
    if (f.error) w.reject(new Error(f.error)); else w.resolve({ value: undefined, done: true });
  }
  if (f.waitingBody) {
    var w2 = f.waitingBody; f.waitingBody = null;
    if (f.error) w2.reject(new Error(f.error)); else w2.resolve();
  }
  if (f.waitingMeta) { var w3 = f.waitingMeta; f.waitingMeta = null; w3(); }
  delete fetches[id]; // the response object keeps `f` alive for its callers
}

// ── the tool bridge ──────────────────────────────────────────────
// {kind:"tool", id, name, args} where name is a Drive op ("page.snapshot"…);
// the answer is _tool(id, resultObject).

function tool(name, args) {
  return new Promise(function (resolve) {
    var id = ++seq;
    pendingTools[id] = resolve;
    post({ kind: 'tool', id: id, name: name, args: args || {} });
  });
}
function _tool(id, result) {
  var r = pendingTools[id]; delete pendingTools[id];
  if (r) r(result && typeof result === 'object' ? result : {});
}

// The grant door — {kind:"grant", id, tab} reaches Drive's tabs.grant, the
// one op that writes tab consent, and the only bridge message that names
// it: a `tool` call can't — `granted` is stripped from its args and the op
// refused — so consent can never be something the model asks for. Only
// attachTabs calls this; the chip it works from was the user's own act.
function grantTab(tab) {
  return new Promise(function (resolve) {
    var id = ++seq;
    pendingTools[id] = resolve;
    post({ kind: 'grant', id: id, tab: tab });
  });
}

// SSE — yield each `data:` payload parsed; [DONE] or stream end stops.
async function* sse(res) {
  for await (var line of res.lines()) {
    if (!line || line.slice(0, 5) !== 'data:') continue;
    var data = line.slice(5).trim();
    if (!data) continue;
    if (data === '[DONE]') return;
    try { yield JSON.parse(data); } catch (e) { /* keepalives etc. */ }
  }
}

async function drain(res) {
  for await (var line of res.lines()) { /* to the end, for res.body */ }
}

// ── the tool set ─────────────────────────────────────────────────
// Model-facing names → Drive ops (Runtime/ask/PROTOCOL.md). `done` is not an
// op — it ends the loop here.

var TARGET = {
  ref: { type: 'string', description: 'element ref from the last snapshot, e.g. "e3"' },
  loc: { type: 'string', description: 'locator handle: css:…, role:…, href:…, xpath:…' },
  css: { type: 'string', description: 'a CSS selector' },
  text: { type: 'string', description: 'visible text to match' }
};
function obj(props, required) { return { type: 'object', properties: props, required: required || [] }; }
function withTab(props, required) {
  var p = { tab: { type: 'string', description: 'tab id — 8 hex chars, from tabs_list or tab_open' } };
  for (var k in props) p[k] = props[k];
  return obj(p, ['tab'].concat(required || []));
}
function withTarget(props, required) {
  var merged = {};
  for (var k in TARGET) merged[k] = TARGET[k];
  for (var k2 in props) merged[k2] = props[k2];
  return withTab(merged, required);
}

// Mutating tools take `why` — one line of the model's own reasoning, shown
// on the consent card if the session's mode makes the op ask. The gate
// reads it and strips it; it never reaches the page.
var WHY = { type: 'string',
  description: 'one line on why this step — shown on the consent card if the action needs approval' };

var TOOLS = [
  { name: 'tabs_list', op: 'tabs.list',
    description: 'List every browser tab: id, title, url, loading, which are agent tabs. Metadata only — you cannot see page contents this way.',
    params: obj({}) },
  { name: 'tab_open', op: 'tabs.open',
    description: 'Open a new agent tab at a URL and return its id. Background by default; foreground:true deliberately asks for the user\'s attention.',
    params: obj({ url: { type: 'string' }, foreground: { type: 'boolean' }, why: WHY }, ['url']) },
  { name: 'tab_attach', op: 'tabs.attach',
    description: 'Attach one of the user\'s tabs by id so you may read and drive it. Consent is required — a tab you were not given will refuse; report that and ask.',
    params: obj({ id: { type: 'string' }, why: WHY }, ['id']) },
  { name: 'navigate', op: 'page.go',
    description: 'Navigate a tab to a URL. All snapshot refs die — take a fresh snapshot before acting.',
    params: withTab({ url: { type: 'string' }, why: WHY }, ['url']) },
  { name: 'back', op: 'page.back', description: 'History back in a tab.', params: withTab({ why: WHY }) },
  { name: 'forward', op: 'page.forward', description: 'History forward in a tab.', params: withTab({ why: WHY }) },
  { name: 'reload', op: 'page.reload', description: 'Reload a tab.', params: withTab({ why: WHY }) },
  { name: 'wait', op: 'page.wait',
    description: 'Wait for a tab to settle (polls for load; seconds caps it).',
    params: withTab({ seconds: { type: 'number' } }) },
  { name: 'snapshot', op: 'page.snapshot',
    description: 'THE way to see a page: a compact semantic tree — text lines plus interactive elements as [ref=eN] handles. Prefer snapshot over read_text or screenshot when you need to act. scope:"viewport" narrows to what\'s visible; boxes:true adds coordinates; maxChars caps size.',
    params: withTab({ scope: { type: 'string', enum: ['full', 'viewport'] }, boxes: { type: 'boolean' }, maxChars: { type: 'number' } }) },
  { name: 'screenshot', op: 'page.screenshot',
    description: 'A PNG of the tab, returned to you as an image. marks:true draws numbered boxes on the interactive elements first.',
    params: withTab({ marks: { type: 'boolean' } }) },
  { name: 'read_text', op: 'page.text',
    description: 'The page\'s rendered text (document.body.innerText, ~120k cap). For reading prose; not for acting.',
    params: withTab({}) },
  { name: 'run_code', op: 'page.code',
    description: 'Run a whole JavaScript program in the page with the __drive helper in scope (snapshot, resolve, act, refs). The escape hatch — prefer one run_code over many tiny calls.',
    params: withTab({ js: { type: 'string' }, why: WHY }, ['js']) },
  { name: 'eval', op: 'page.eval',
    description: 'Raw evaluateJavaScript in the page; JSON-safe result. No helpers — run_code is usually better.',
    params: withTab({ js: { type: 'string' }, why: WHY }, ['js']) },
  { name: 'click', op: 'act.click',
    description: 'Click an element (ref from the last snapshot, or loc/css/text). button:"middle"|"right", double:true, modifiers:["cmd","shift","ctrl","opt"], withSnapshot:true returns a fresh snapshot.',
    params: withTarget({ button: { type: 'string' }, double: { type: 'boolean' }, modifiers: { type: 'array', items: { type: 'string' } }, withSnapshot: { type: 'boolean' }, why: WHY }) },
  { name: 'fill', op: 'act.fill',
    description: 'Set an input\'s value atomically (React-aware; works on contenteditable too).',
    params: withTarget({ text: { type: 'string' }, why: WHY }, ['text']) },
  { name: 'type', op: 'act.type',
    description: 'Type real per-character key events into an element. Prefer fill unless the page needs keystrokes.',
    params: withTarget({ text: { type: 'string' }, delay: { type: 'number' }, why: WHY }, ['text']) },
  { name: 'press', op: 'act.press',
    description: 'Press a key — "Enter", "Tab", "Escape", "Backspace", "a"… — with optional modifiers.',
    params: withTab({ key: { type: 'string' }, modifiers: { type: 'array', items: { type: 'string' } }, why: WHY }, ['key']) },
  { name: 'hover', op: 'act.hover',
    description: 'Move the pointer over an element (menus that open on hover).',
    params: withTarget({ why: WHY }) },
  { name: 'scroll', op: 'act.scroll',
    description: 'Scroll the page (ref:"page") or an element. dx/dy pixels, or toText to bring matching text into view.',
    params: withTab({ ref: { type: 'string' }, dx: { type: 'number' }, dy: { type: 'number' }, toText: { type: 'string' }, why: WHY }) },
  { name: 'select', op: 'act.select',
    description: 'Choose <select> options by value.',
    params: withTarget({ values: { type: 'array', items: { type: 'string' } }, why: WHY }, ['values']) },
  { name: 'check', op: 'act.check',
    description: 'Set a checkbox or radio on/off.',
    params: withTarget({ on: { type: 'boolean' }, why: WHY }, ['on']) },
  { name: 'submit', op: 'act.submit',
    description: 'Submit the form containing the element.',
    params: withTarget({ why: WHY }) },
  { name: 'click_at', op: 'act.clickAt',
    description: 'Click raw coordinates — for canvas/SVG where no element ref exists (get x,y from a boxes:true snapshot or a marked screenshot).',
    params: withTab({ x: { type: 'number' }, y: { type: 'number' }, why: WHY }, ['x', 'y']) },
  { name: 'console', op: 'page.console',
    description: 'Recent console messages collected from the tab.',
    params: withTab({}) },
  { name: 'frames', op: 'page.frames',
    description: 'List a tab\'s frames (ref, url, sameOrigin).',
    params: withTab({}) },
  { name: 'close_tab', op: 'tabs.close',
    description: 'Close an agent tab you opened.',
    params: obj({ id: { type: 'string' }, why: WHY }, ['id']) },
  { name: 'ask_user', op: 'ask.user',
    description: 'Ask the user a question and wait — for a choice only they can make or facts no tab holds. Result is {answer:"…"} or {declined:"dismissed"|"timeout"|"busy"}; a declined question means make your own call and say what you assumed. options[] become quick-pick pills; free text is always allowed.',
    params: obj({ question: { type: 'string' },
                 options: { type: 'array', items: { type: 'string' } } }, ['question']) },
  { name: 'done', op: null,
    description: 'Call when the task is complete — ends the turn. summary: one line on what was done or found.',
    params: obj({ summary: { type: 'string' } }, ['summary']) }
];

// ── the system prompt ────────────────────────────────────────────

var SYSTEM = [
  'You are Ask — an agent living inside Search, the user\'s browser on this Mac.',
  'You work in real tabs: tabs the user attached (listed in context; yours to',
  'read and drive) and agent tabs you open with tab_open (in the background —',
  'they do not disturb the user unless you set foreground).',
  '',
  'Seeing: `snapshot` is the way — a compact tree of the page\'s text and its',
  'interactive elements as [ref=eN] handles. Act on refs (or loc/css/text',
  'queries) with click, fill, type, press, hover, scroll, select, check,',
  'submit, click_at. Refs die when the page navigates: after navigate, reload,',
  'back or forward, take a fresh snapshot before acting.',
  '',
  'Rhythm: snapshot → act → snapshot. Prefer `run_code` (a whole JS program',
  'with the __drive helper in scope) over many tiny calls when a step is',
  'complicated. `read_text` for long prose, `console` for page errors,',
  '`frames` for iframes, `screenshot` for a visual check, `wait` to let a',
  'page settle, `tabs_list` to survey.',
  '',
  'Rules: attaching a tab you were not given is refused — report it and ask.',
  'Never narrate ("I will now click…"); just act. Keep replies short — this',
  'is a chat sidebar, and tool calls show as cards of their own. When the',
  'task is complete, call `done` with a one-line summary.',
  '',
  'ask_user when you need the human — declined answers mean decide yourself.',
  'A denied call is the user\'s answer — say what you wanted and why; never',
  'retry it.'
].join('\n');

// ── providers ────────────────────────────────────────────────────
// Each turn(model, system, messages, ctx, hooks) returns {text, calls}:
// calls = [{id, name, args(object), raw(string)}]. hooks.delta(text) streams;
// hooks.activity(text) updates the status line; hooks.track(res) registers a
// fetch for stop() to abort.

// chat.effort → the wire's own word for it, or null to send nothing.
// "off" becomes "none" where the API can switch reasoning off entirely
// (openrouter); codex's models always reason, so its floor is "minimal".
// auto (nil) and anything unrecognized leaves the field out — the
// provider's own default then holds.
function effortLevel(ctx, provider) {
  var e = ctx && ctx.effort;
  // The whole ladder passes through — both wires take xhigh/max now.
  if (e === 'low' || e === 'medium' || e === 'high' || e === 'xhigh' || e === 'max') return e;
  if (e === 'off') return provider === 'codex' ? 'minimal' : 'none';
  return null;
}

function openaiMessage(m) {
  if (m.role === 'tool') return { role: 'tool', tool_call_id: m.callId, content: m.text };
  if (m.role === 'assistant' && m.calls && m.calls.length) {
    return {
      role: 'assistant', content: m.text || null,
      tool_calls: m.calls.map(function (c, i) {
        return {
          id: c.id || ('call_' + i), type: 'function',
          function: { name: c.name, arguments: c.raw != null ? c.raw : JSON.stringify(c.args || {}) }
        };
      })
    };
  }
  if (m.image || (m.images && m.images.length)) {
    var content = [{ type: 'text', text: m.text || '[image]' }];
    if (m.image) content.push({ type: 'image_url', image_url: { url: m.image } });
    (m.images || []).forEach(function (u) {
      content.push({ type: 'image_url', image_url: { url: u } });
    });
    return { role: 'user', content: content };
  }
  return { role: m.role, content: m.text };
}

async function openrouterTurn(model, system, messages, ctx, hooks) {
  var body = {
    model: model,
    messages: [{ role: 'system', content: system }].concat(messages.map(openaiMessage)),
    tools: TOOLS.map(function (t) {
      return { type: 'function', function: { name: t.name, description: t.description, parameters: t.params } };
    }),
    stream: true
  };
  // The chat's reasoning pick; unset means the model's own default.
  // TODO: a model that always reasons rejects effort "none" outright —
  // the right fallback is a retry with reasoning:{enabled:false}; for
  // now the provider's 400 reaches the user as-is.
  var effort = effortLevel(ctx, 'openrouter');
  if (effort) body.reasoning = { effort: effort };
  var res = fetchNative({
    url: 'https://openrouter.ai/api/v1/chat/completions',
    method: 'POST', auth: 'openrouter', stream: true,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  });
  hooks.track(res);
  await res.ready();
  if (!res.ok) {
    await drain(res);
    throw new Error('openrouter ' + res.status + ' — ' + trim(res.body, 800));
  }
  var text = '', calls = [];
  for await (var ev of sse(res)) {
    if (ctx.dead) break;
    var ch = ev.choices && ev.choices[0];
    if (!ch) continue;
    var d = ch.delta || {};
    if (typeof d.content === 'string' && d.content) { text += d.content; hooks.delta(d.content); }
    (d.tool_calls || []).forEach(function (tc) {
      var i = tc.index != null ? tc.index : calls.length;
      var c = calls[i] || (calls[i] = { id: '', name: '', raw: '' });
      if (tc.id) c.id = tc.id;
      var fn = tc.function || {};
      if (fn.name) c.name += fn.name;
      if (fn.arguments) c.raw += fn.arguments;
    });
  }
  return { text: text, calls: calls.filter(Boolean).map(function (c, i) {
    return { id: c.id || ('call_' + i), name: c.name, args: parseArgs(c.raw), raw: c.raw };
  }) };
}

// ChatGPT-backend Codex — the OpenAI Responses API over chatgpt.com.
// Auth is the `codex` key JSON injected by the bridge (Bearer access_token +
// ChatGPT-Account-Id); the wire shape follows leger/pi-ai: store:false,
// stream:true, OpenAI-Beta: responses=v1.
function responsesInput(messages) {
  var input = [];
  messages.forEach(function (m) {
    if (m.role === 'tool') {
      input.push({ type: 'function_call_output', call_id: m.callId, output: m.text });
      return;
    }
    if (m.role === 'assistant') {
      if (m.text) input.push({ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: m.text }] });
      (m.calls || []).forEach(function (c, i) {
        input.push({
          type: 'function_call', call_id: c.id || ('call_' + i), name: c.name,
          arguments: c.raw != null ? c.raw : JSON.stringify(c.args || {})
        });
      });
      return;
    }
    var content = [{ type: 'input_text', text: m.text || '' }];
    if (m.image) content.push({ type: 'input_image', image_url: m.image });
    (m.images || []).forEach(function (u) {
      content.push({ type: 'input_image', image_url: u });
    });
    input.push({ type: 'message', role: 'user', content: content });
  });
  return input;
}

async function codexTurn(model, system, messages, ctx, hooks) {
  var body = {
    model: model,
    instructions: system,
    input: responsesInput(messages),
    tools: TOOLS.map(function (t) {
      return { type: 'function', name: t.name, description: t.description, parameters: t.params, strict: false };
    }),
    tool_choice: 'auto',
    store: false,
    stream: true
  };
  // The chat's reasoning pick; unset means the model's own default.
  var effort = effortLevel(ctx, 'codex');
  if (effort) body.reasoning = { effort: effort };
  var res = fetchNative({
    url: 'https://chatgpt.com/backend-api/codex/responses',
    method: 'POST', auth: 'codex', stream: true,
    headers: {
      'content-type': 'application/json',
      'OpenAI-Beta': 'responses=v1',
      'originator': 'search'
    },
    body: JSON.stringify(body)
  });
  hooks.track(res);
  await res.ready();
  if (!res.ok) {
    await drain(res);
    throw new Error('codex ' + res.status + ' — ' + trim(res.body, 800));
  }
  var text = '', calls = [];
  for await (var ev of sse(res)) {
    if (ctx.dead) break;
    var type = ev.type || '';
    if (type === 'response.output_text.delta' && ev.delta) {
      text += ev.delta; hooks.delta(ev.delta);
    } else if (type === 'response.output_item.done' && ev.item && ev.item.type === 'function_call') {
      calls.push({
        id: ev.item.call_id || ev.item.id || ('call_' + calls.length),
        name: ev.item.name || '',
        args: parseArgs(ev.item.arguments),
        raw: ev.item.arguments || ''
      });
    } else if (type === 'response.function_call_arguments.done') {
      // arguments arrive complete here too — covered by output_item.done,
      // but a sparse stream may carry only this.
      var found = calls.some(function (c) { return c.id === ev.item_id; });
      if (!found && ev.name) calls.push({ id: ev.item_id, name: ev.name, args: parseArgs(ev.arguments), raw: ev.arguments || '' });
    } else if (type === 'response.failed' || type === 'error') {
      var msg = (ev.response && ev.response.error && ev.response.error.message) || ev.message || 'the codex stream failed';
      throw new Error('codex — ' + msg);
    }
  }
  return { text: text, calls: calls };
}

// Devin — v1 minimal: a REST session per turn (the whole transcript is its
// prompt), polled to finished. Turn-based only — no mid-run stream — and it
// works in Devin's environment, not these tabs; the tools aren't offered.
async function devinTurn(model, system, messages, ctx, hooks) {
  var prompt = system + '\n\n' + messages.map(function (m) {
    var who = m.role === 'assistant' ? 'Assistant' : m.role === 'tool' ? 'Tool result' : 'User';
    return who + ': ' + (m.text || '');
  }).join('\n\n');
  var res = fetchNative({
    url: 'https://api.devin.ai/v1/sessions',
    method: 'POST', auth: 'devin',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ prompt: prompt })
  });
  hooks.track(res);
  var data = await res.json().catch(function () { return {}; });
  await res.ready();
  if (!res.ok) throw new Error('devin ' + res.status + ' — ' + trim(res.error || res.body, 800));
  var session = data.session_id || data.id;
  if (!session) throw new Error('devin — no session id in ' + trim(res.body, 400));
  for (var tries = 0; tries < 200; tries++) {
    if (ctx.dead) return { text: '', calls: [] };
    await sleep(2500);
    hooks.activity('devin is working…');
    var s = fetchNative({ url: 'https://api.devin.ai/v1/sessions/' + session, auth: 'devin' });
    hooks.track(s);
    var body = await s.json().catch(function () { return {}; });
    var status = String(body.status_enum || body.status || '').toLowerCase();
    if (['finished', 'stopped', 'suspended', 'error', 'expired', 'blocked'].indexOf(status) >= 0) {
      var out = (body.structured_output && (body.structured_output.result || body.structured_output.message)) ||
        lastDevinMessage(body) || '(devin finished without a text answer)';
      hooks.delta(out);
      return { text: out, calls: [] };
    }
  }
  throw new Error('devin — the session did not finish');
}

function lastDevinMessage(body) {
  var msgs = body.messages || [];
  for (var i = msgs.length - 1; i >= 0; i--) {
    var m = msgs[i];
    var text = m.message || m.text || (m.payload && m.payload.message);
    var who = m.type || m.role || '';
    if (text && /devin|assistant|agent|message/i.test(String(who))) return String(text);
  }
  return null;
}

// Echo — no network: repeats the text and lists the tools it would have.
// For testing without keys.
function echoTurn(model, system, messages, ctx, hooks) {
  var last = null;
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === 'user') { last = messages[i].text; break; }
  }
  var names = TOOLS.map(function (t) { return t.name; }).join(', ');
  var out = 'Echo: ' + (last || '') + '\n\n(tools I would have: ' + names + ')';
  hooks.delta(out);
  return Promise.resolve({ text: out, calls: [] });
}

var PROVIDERS = {
  openrouter: { images: true, turn: openrouterTurn, defaultModel: 'z-ai/glm-5.3-flash' },
  codex: { images: true, turn: codexTurn, defaultModel: 'gpt-6-luna' },
  devin: { images: false, turn: devinTurn, defaultModel: 'devin' },
  echo: { images: false, turn: echoTurn, defaultModel: 'echo' }
};

function providerFor(model) {
  var id = String(model || '').trim() || 'openrouter/z-ai/glm-5.3-flash';
  var slash = id.indexOf('/');
  var name, rest;
  if (slash < 0) {
    if (PROVIDERS[id]) { name = id; rest = ''; }
    else { name = 'openrouter'; rest = id; }
  } else {
    name = id.slice(0, slash);
    rest = id.slice(slash + 1);
    if (!PROVIDERS[name]) { name = 'openrouter'; rest = id; }
  }
  var p = PROVIDERS[name];
  return { provider: p, name: name, model: rest || p.defaultModel };
}

// ── history & context ────────────────────────────────────────────
// chat.messages → internal messages: {role:'user'|'assistant'|'tool', text,
// calls?, callId?, image?, images?}. Last ~30 messages; tab chips become a
// line of context, the typed attachments their own lines or image parts,
// notes arrive inline. Tool calls from earlier turns replay only when
// their args still parse — and a tool result replays only beside its
// call, since an orphaned tool_call_id is an API error.

// The composer's typed pieces (AskAttach) → context lines plus any image
// parts the wire can take. `canImages` is the provider's own flag
// (PROVIDERS[].images): with it a base64 piece rides as a part, without
// it the piece degrades to a "[image: …]" line — nothing fakes a part on
// a wire that can't carry one (devin/echo).
function attachContext(pieces, canImages) {
  var lines = [], images = [];
  (pieces || []).forEach(function (p) {
    if (!p || typeof p !== 'object') return;
    var label = String(p.label || p.path || p.url || 'attachment');
    var at = p.path ? ' at ' + p.path : '';
    if (p.kind === 'site') {
      // A reference only — it never resolves to a tab the way a chip does.
      var where = p.url ? String(p.url) : label;
      var what = p.label && String(p.label) !== where ? ' — ' + String(p.label) : '';
      lines.push('[site: ' + where + what + ']');
    } else if (p.kind === 'file') {
      if (p.text != null) {
        // A file's own trailing newline would double as a blank line
        // before the fence — fold it into the fence's separator.
        var body = String(p.text);
        if (body.endsWith('\n')) body = body.slice(0, -1);
        lines.push('[file: ' + label + ']\n```\n' + body + '\n```');
      }
      else lines.push('[file: ' + label + at + ' — contents not attached]');
    } else if (p.kind === 'image') {
      if (p.data && canImages) {
        images.push('data:' + (p.mime || 'image/png') + ';base64,' + p.data);
      } else {
        lines.push('[image: ' + label + at + ']');
      }
    } else {
      lines.push('[' + String(p.kind || 'attachment') + ': ' + label + at + ']');
    }
  });
  return { text: lines.join('\n'), images: images };
}

function toHistory(messages, provider) {
  var canImages = !!(provider && provider.images);
  var out = [];
  (messages || []).slice(-30).forEach(function (m) {
    var text = String(m.text || '');
    // The consent chips ride as `tabs`; before the fields split the wire
    // called that array "attachments" — kind-less entries there are still
    // chips, while kind-labelled ones are the composer's typed pieces.
    var chips = (m.tabs || []).slice();
    var pieces = [];
    (m.attachments || []).forEach(function (a) {
      if (a && a.kind) pieces.push(a);
      else if (a) chips.push(a);
    });
    var head = '';
    if (chips.length) {
      head += '[attached tabs: ' + chips.map(function (t) {
        return (t.title || '') + ' <' + (t.address || '') + '>';
      }).join('; ') + ']\n';
    }
    var images = [];
    if (pieces.length) {
      var ac = attachContext(pieces, canImages);
      if (ac.text) head += ac.text + '\n';
      images = ac.images;
    }
    text = head + text;
    if (m.role === 'you') {
      var msg = { role: 'user', text: text };
      if (images.length) msg.images = images;
      out.push(msg);
    } else if (m.role === 'agent') {
      var calls = (m.tools || []).map(function (t) {
        var parsed = parseArgs(t.args);
        return parsed._raw !== undefined && t.args ? null : { id: t.id, name: t.name, args: parsed, raw: typeof t.args === 'string' ? t.args : null };
      }).filter(Boolean);
      var msg = { role: 'assistant', text: text };
      if (calls.length) msg.calls = calls;
      out.push(msg);
      (m.tools || []).forEach(function (t) {
        // A call with no result — a killed turn, an ask_user that went
        // unanswered — replays as a synthetic "ended" result: replaying
        // the bare tool_call without it is a provider 400.
        if (calls.some(function (c) { return c.id === t.id; })) {
          out.push({ role: 'tool', callId: t.id,
                     text: t.result != null ? String(t.result) : '(ended before it answered)' });
        }
      });
    } else if (m.role === 'note') {
      out.push({ role: 'user', text: '[note: ' + text + ']' });
    }
  });
  return out;
}

// Attached chips: the chip was the consent, so each tab goes through the
// grant door (not tabs.attach — consent is never a tool argument), then
// {id,title,url} plus a page.text excerpt folds into the turn's opening
// user message.
async function attachTabs(tabs) {
  if (!tabs || !tabs.length) return '';
  var parts = [];
  for (var i = 0; i < tabs.length; i++) {
    var t = tabs[i];
    var id = tabId(t.id);
    var r = await grantTab(id);
    if (r.error) {
      parts.push('- ' + (t.title || '') + ' <' + (t.address || '') + '> (attach failed: ' + r.error + ')');
      continue;
    }
    var excerpt = '';
    var tx = await tool('page.text', { tab: id });
    if (tx && tx.text) excerpt = String(tx.text).replace(/\s+/g, ' ').trim().slice(0, 1500);
    parts.push('- [' + id + '] ' + (t.title || '') + ' <' + (t.address || '') + '>' +
      (excerpt ? '\n  excerpt: ' + excerpt : ''));
  }
  return 'Attached tabs — you may read and drive these:\n' + parts.join('\n');
}

// ── tool results ─────────────────────────────────────────────────

// Strip the image payload for JSON-shaped copies of a result; the picture
// itself travels as a message part, not inside the JSON.
function slim(result) {
  if (!result || typeof result !== 'object') return result;
  var copy = {};
  for (var k in result) if (k !== 'image') copy[k] = result[k];
  return copy;
}
function resultText(result) {
  if (result == null) return '(no result)';
  if (typeof result === 'string') return result;
  try { return JSON.stringify(slim(result)); } catch (e) { return String(result); }
}

// ── the loop ─────────────────────────────────────────────────────
// `current` is the live turn; run() replaces it, steer() feeds it, stop()
// kills it.

var current = null;
// Steer text that arrived between turns — Mind already committed the
// message to the chat, so it is held here rather than dropped and is
// handed to the next run() as if it had been steered mid-turn.
var queuedSteer = [];

async function runCalls(calls, ctx, job, messages, provider, cardSink) {
  var chatId = job.chat.id;
  // null while the turn is open; the done call's summary string (maybe
  // empty) once it runs. Not truthiness — "done" is a real summary.
  var finished = null;
  for (var i = 0; i < calls.length; i++) {
    if (ctx.dead) break;
    var call = calls[i];
    var def = null;
    for (var j = 0; j < TOOLS.length; j++) if (TOOLS[j].name === call.name) def = TOOLS[j];
    emit(ctx, 'activity', { chat: chatId, text: call.name });
    var card = { id: call.id, name: call.name, args: trim(JSON.stringify(call.args || {}), 500), result: null, failed: false };
    cardSink(card);
    var result;
    if (call.name === 'done') {
      finished = String((call.args && call.args.summary) || '');
      result = { ok: true };
    } else if (!def || !def.op) {
      result = { error: 'unknown tool ' + call.name };
    } else {
      try { result = await tool(def.op, call.args || {}); }
      catch (e) { result = { error: String(e && e.message || e) }; }
    }
    card.failed = !!(result && result.error);
    card.result = trim(result && result.error ? result.error : resultText(result), 500);
    cardSink(card);
    messages.push({ role: 'tool', callId: call.id, text: trim(resultText(result), 24000) });
    if (result && result.image && provider.images) {
      messages.push({ role: 'user', text: '[screenshot of tab ' + (call.args && call.args.tab || '?') + ']', image: result.image });
    }
    // The turn ended — a call after done in the same batch must not run:
    // it would mutate pages the user thinks the agent is done with.
    if (finished != null) break;
  }
  return finished;
}

async function loop(job, ctx) {
  var chatId = job.chat.id;
  var text = '', toolsShown = [];
  var error = null;
  // Tool cards go to the panel as they happen and into the saved message.
  var cardSink = function (card) {
    var held = toolsShown.filter(function (t) { return t.id === card.id; })[0];
    if (held) { held.result = card.result; held.failed = card.failed; }
    else toolsShown.push({ id: card.id, name: card.name, args: card.args, result: card.result, failed: card.failed });
    emit(ctx, 'tool', { chat: chatId, tool: {
      id: card.id, name: card.name, args: card.args,
      result: card.result, failed: card.failed
    } });
  };
  try {
    var resolved = providerFor(job.chat && job.chat.model);
    var provider = resolved.provider;
    var messages = toHistory(job.chat && job.chat.messages, provider);
    var context = await attachTabs(job.tabs);
    // The last .you message's typed pieces already folded in through
    // toHistory; job.attachments is the same payload, kept as the fallback
    // for a chat that doesn't persist them on its messages. Trust the
    // message when it carries the field — injecting both would double it.
    var raws = (job.chat && job.chat.messages) || [];
    var lastRaw = raws.length ? raws[raws.length - 1] : null;
    var extra = { text: '', images: [] };
    if (job.attachments && job.attachments.length && !(lastRaw && lastRaw.attachments != null)) {
      extra = attachContext(job.attachments, provider.images);
    }
    // The last history entry is this turn's text (Mind appends before run);
    // the attached-tab context goes into that message, the typed pieces'
    // lines ahead of the text the same way.
    var head = (context ? context + '\n\n' : '') + (extra.text ? extra.text + '\n\n' : '');
    var last = messages[messages.length - 1];
    if (last && last.role === 'user') {
      last.text = head + last.text;
      if (extra.images.length) last.images = (last.images || []).concat(extra.images);
    } else {
      var fresh = { role: 'user', text: head + String(job.text || '') };
      if (extra.images.length) fresh.images = extra.images;
      messages.push(fresh);
    }

    var hooks = {
      delta: function (t) { text += t; emit(ctx, 'delta', { chat: chatId, text: t }); },
      activity: function (t) { emit(ctx, 'activity', { chat: chatId, text: t }); },
      track: function (res) { ctx.fetchId = res.id; }
    };

    var finished = null, iter = 0;
    while (!ctx.dead && iter < 25 && finished == null) {
      iter++;
      while (ctx.steered.length) messages.push({ role: 'user', text: ctx.steered.shift() });
      hooks.activity('thinking…');
      ctx.fetchId = 0;
      var turn = await provider.turn(resolved.model, SYSTEM, messages, ctx, hooks);
      ctx.fetchId = 0;
      if (ctx.dead) break;
      var turnText = turn.text || '';
      var calls = turn.calls || [];
      if (turnText || calls.length) {
        messages.push({ role: 'assistant', text: turnText, calls: calls });
      }
      // No calls ends the turn — unless a steered message arrived meanwhile;
      // that starts another iteration as a fresh user message.
      if (!calls.length && !ctx.steered.length) break;
      finished = await runCalls(calls, ctx, job, messages, provider, cardSink);
      // If the model finished without saying anything, its done-summary is
      // the reply the user sees — whatever it says, so long as it says
      // something.
      if (finished != null && !turnText && finished) {
        text += finished;
        emit(ctx, 'delta', { chat: chatId, text: finished });
      }
    }
    if (iter >= 25 && finished == null && !ctx.dead) error = 'reached the 25-step limit';
  } catch (e) {
    error = String(e && e.message || e);
  }
  if (text || toolsShown.length) {
    emit(ctx, 'message', { chat: chatId, message: {
      id: uuid(), role: 'agent', text: text,
      tools: toolsShown, attachments: [], when: now()
    } });
  }
  emit(ctx, 'activity', { chat: chatId, text: '' });
  emit(ctx, 'done', { chat: chatId, error: ctx.dead ? null : error });
}

// Wind a turn down: flag it, abort its fetch, and unblock any mid-flight
// tool call so the loop can see dead — a Drive op that never answers
// shouldn't hold it forever.
function kill(ctx) {
  ctx.dead = true;
  if (ctx.fetchId) post({ kind: 'abort', id: ctx.fetchId });
  for (var id in pendingTools) {
    var r = pendingTools[id]; delete pendingTools[id];
    r({ error: 'stopped' });
  }
}

function run(job) {
  if (typeof job === 'string') { try { job = JSON.parse(job); } catch (e) { log('bad job JSON: ' + e); return; } }
  if (!job || !job.chat || !job.chat.id) { log('run() with no chat'); return; }
  if (current) kill(current);
  var ctx = current = { dead: false, steered: [], fetchId: 0, turn: job.chat.turn || null,
                        effort: job.chat.effort || null };
  while (queuedSteer.length) {
    var held = String(queuedSteer.shift());
    ctx.steered.push(held);
    emit(ctx, 'delta', { chat: job.chat.id, text: '(queued: ' + trim(held, 160) + ')\n' });
  }
  loop(job, ctx).catch(function (e) { log('loop fell: ' + (e && e.stack || e)); })
    .finally(function () { if (current === ctx) current = null; });
}

function steer(text) {
  if (current) { current.steered.push(String(text)); return; }
  // No live turn — the message is already in the chat; keep it for the
  // next run rather than answering it with silence.
  queuedSteer.push(String(text));
  log('steer with no live turn — queued for the next run: ' + trim(text, 120));
}

function stop() {
  if (current) kill(current);
}

window.__h = {
  run: run, steer: steer, stop: stop,
  fetchNative: fetchNative, tool: tool,
  _fetchMeta: _fetchMeta, _fetchLine: _fetchLine, _fetchEnd: _fetchEnd, _tool: _tool,
  toHistory: toHistory        // exposed for the unit test
};

})();
