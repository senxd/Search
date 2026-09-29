// drive.test.js — runs drive.js inside jsdom and asserts the contract in
// Runtime/ask/PROTOCOL.md: snapshot shape, ref stability and staleness,
// loc= handles, fill/click/select/check/press, iframe recursion, marks.
//
//   bun Runtime/ask/drive.test.js
//
// jsdom is the only dependency and it is not vendored — resolve it from
// $JSDOM, then a bare import (if this file sits under a node_modules reach),
// then the scratch dir the file was built against. If none exist:
//   mkdir -p /tmp/drivetest && cd /tmp/drivetest && bun init -y && bun add jsdom
//
// jsdom has no layout, so the test installs the layout it needs:
// getBoundingClientRect answers from a data-rect="x,y,w,h" attribute (or a
// sensible default), elementFromPoint answers the deepest element whose
// rect contains the point, scrollIntoView exists and is a no-op.

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const here = dirname(fileURLToPath(import.meta.url));
const DRIVE = join(here, 'drive.js');

let JSDOM = null;
for (const spec of [process.env.JSDOM, 'jsdom', '/tmp/drivetest/node_modules/jsdom'].filter(Boolean)) {
  try { JSDOM = (await import(spec)).JSDOM; if (JSDOM) break; } catch (e) {}
}
if (!JSDOM) { console.error('jsdom not found — `bun add jsdom` somewhere and set JSDOM to its path'); process.exit(2); }

let passed = 0, failed = 0;
function ok(cond, name, extra) {
  if (cond) { passed++; console.log('  ok   ' + name); }
  else { failed++; console.log('  FAIL ' + name + (extra ? ' — ' + extra : '')); }
}
function eq(a, b, name) { ok(a === b, name, JSON.stringify(a) + ' !== ' + JSON.stringify(b)); }

const PAGE = `<!doctype html><html><body>
<nav aria-label="Main">
  <a href="#home" data-rect="8,8,60,20">Home</a>
  <a href="#about" data-rect="76,8,60,20">About</a>
</nav>
<main>
  <h1 data-rect="8,40,400,32">A small fixture</h1>
  <p data-rect="8,80,400,20">Words for the agent to read.</p>
  <form id="f">
    <label for="who">Your name</label>
    <input id="who" type="text" data-rect="8,110,200,22">
    <input id="agree" type="checkbox" data-rect="8,140,16,16">
    <select id="pick" data-rect="8,170,120,22"><option value="a">Aye</option><option value="b">Bee</option></select>
    <button id="save" data-rect="8,200,80,28">Save</button>
  </form>
  <div id="cursorDiv" style="cursor:pointer" data-rect="8,240,100,30">not a button but acts like one</div>
  <input type="hidden" value="ghost">
  <button id="below" data-rect="8,2000,80,28">Below the fold</button>
</main>
</body></html>`;

// jsdom gives each iframe its own realm — prototypes included — so the
// layout mocks have to be installed per window, not once.
function patchWindow(w) {
  // Layout, such as it is: an element's rect is its data-rect, or a default
  // box so "is it visible" has an answer.
  w.Element.prototype.getBoundingClientRect = function () {
    const a = this.getAttribute && this.getAttribute('data-rect');
    let x = 0, y = 0, ww = 100, h = 20;
    if (a) { const p = a.split(',').map(Number); x = p[0]; y = p[1]; ww = p[2]; h = p[3]; }
    return { x, y, left: x, top: y, right: x + ww, bottom: y + h, width: ww, height: h, toJSON() { return {}; } };
  };
  // The deepest element containing the point wins, which is close enough to
  // paint order for a test.
  w.Document.prototype.elementFromPoint = function (px, py) {
    let best = null;
    const all = this.querySelectorAll('*');
    for (const el of all) {
      const r = el.getBoundingClientRect();
      if (px >= r.left && px < r.right && py >= r.top && py < r.bottom) best = el;
    }
    return best;
  };
  w.Element.prototype.scrollIntoView = function () {};
  // jsdom's focus path constructs a FocusEvent against a Window object its
  // own realm check rejects — unrelated to drive.js, so pretend focus here:
  // activeElement follows a marker on the document.
  try { Object.defineProperty(w.Document.prototype, 'activeElement', { configurable: true, get() { return this.__ae || this.body; } }); } catch (e) {}
  w.HTMLElement.prototype.focus = function () { this.ownerDocument.__ae = this; };
  w.HTMLElement.prototype.blur = function () { if (this.ownerDocument.__ae === this) this.ownerDocument.__ae = null; };
  // Same story for sessionStorage — jsdom's Storage fires a `storage`
  // event down a dispatch path that's half-built in outside-only eval and
  // can take the whole process with it. drive.js only needs get/set.
  const store = new Map();
  try {
    Object.defineProperty(w, 'sessionStorage', {
      configurable: true,
      value: { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) },
    });
  } catch (e) {}
  // jsdom reports the document as prerender-hidden, and drive.js paces its
  // stability frames by microtask on hidden pages. Tests pretend the tab is
  // visible so the rAF path is the one under test; a test can flip
  // w.__hidden to exercise the hidden path.
  try {
    Object.defineProperty(w.Document.prototype, 'hidden', { configurable: true, get() { return this.defaultView.__hidden === true; } });
    Object.defineProperty(w.Document.prototype, 'visibilityState', { configurable: true, get() { return this.__hidden || this.defaultView.__hidden ? 'hidden' : 'visible'; } });
    w.__hidden = false;
  } catch (e) {}
  return w;
}

function makeDom(html) {
  const dom = new JSDOM(html, {
    url: 'https://fixture.test/',
    pretendToBeVisual: true,
    runScripts: 'outside-only',
  });
  patchWindow(dom.window);
  return dom;
}

const dom = makeDom(PAGE);
const w = dom.window;
w.eval(readFileSync(DRIVE, 'utf8'));
const drive = w.__drive;

console.log('install');
ok(drive && drive.v >= 1, '__drive installed');
ok(drive.version > 0, 'version seeded');
// Idempotence: a second eval of the file must not clobber state.
const v0 = drive.version;
w.eval(readFileSync(DRIVE, 'utf8'));
ok(w.__drive === drive && drive.version === v0, 're-injection is a no-op');

console.log('snapshot');
const s1 = drive.snapshot({});
const out = s1.snapshot;
console.log('--- snapshot ---\n' + out + '\n----------------');
ok(s1.url === 'https://fixture.test/' && s1.title === '', 'snapshot carries url+title');
ok(/- navigation "Main"/.test(out), 'nav landmark with aria name');
ok(/- link "Home" \[/.test(out) || /- link "Home" \*\[/.test(out), 'link line with ref');
ok(/- heading "A small fixture" \[level=1\]/.test(out), 'heading with level');
ok(/- "Words for the agent to read\."/.test(out), 'text run line');
ok(/- textbox "Your name"/.test(out), 'input named by <label for>');
ok(/- checkbox/.test(out), 'checkbox line');
ok(/- combobox/.test(out), 'select as combobox');
ok(/- button "Save" \*?\[ref=e\d+\]/.test(out), 'button line with ref');
ok(/- button "Save" \*?\[ref=e\d+\].*\[loc=css:#save\]/.test(out), 'css loc beside ref');
ok(/\[loc=role:button\[name="Save"\]\]/.test(out), 'role loc beside ref');
ok(/- generic \*?\[ref=e\d+\]/.test(out), 'cursor:pointer div earns a generic+ref line');
ok(!/hidden/.test(out.match(/ghost/) || ''), 'input[type=hidden] skipped');
ok(/below the fold/.test(out), 'below-fold note emitted');
ok(/note: 1 interactive element below/.test(out), 'exactly one below-fold element counted');

const refOf = (id) => { const el = w.document.getElementById(id); return el && el.__driveRef && el.__driveRef.ref; };
const saveRef = refOf('save');
ok(!!saveRef, 'save button has a ref: ' + saveRef);

console.log('ref stability');
const s2 = drive.snapshot({});
eq(refOf('save'), saveRef, 'ref stable across re-snapshot');
ok(!/- button "Save" \*\[/.test(s2.snapshot), 'no * on unchanged element in second snapshot');
ok(s2.version !== s1.version, 'version bumps per snapshot');

console.log('new marker');
const nb = w.document.createElement('button');
nb.textContent = 'Fresh';
nb.setAttribute('data-rect', '8,300,80,28');
w.document.querySelector('main').appendChild(nb);
const s3 = drive.snapshot({});
ok(/- button "Fresh" \*\[ref=e\d+\]/.test(s3.snapshot), 'new element starred');
ok(!/- button "Save" \*\[/.test(s3.snapshot), 'old element unstarred');

console.log('resolve');
ok(drive.resolve({ ref: saveRef }) === w.document.getElementById('save'), 'ref resolves to element');
ok(drive.resolve({ loc: 'css:#save' }) === w.document.getElementById('save'), 'loc css: resolves');
ok(drive.resolve({ loc: 'role:button[name="Save"]' }) === w.document.getElementById('save'), 'loc role: resolves');
ok(drive.resolve({ loc: 'href:#about' }) === w.document.querySelector('a[href="#about"]'), 'loc href: resolves');
ok(drive.resolve({ css: '#who' }) === w.document.getElementById('who'), 'css resolves');
ok(drive.resolve({ text: 'save' }) === w.document.getElementById('save'), 'text= resolves case-folded');
try { drive.resolve({ ref: 'e9999' }); ok(false, 'unknown ref throws'); }
catch (e) { ok(e.code === 'NOT_FOUND' || e.code === 'STALE_REF', 'unknown ref throws coded error (' + e.code + ')'); }

console.log('stale');
nb.remove();
const gone = w.document.createElement('button');
gone.textContent = 'Gone';
gone.setAttribute('data-rect', '8,320,80,28');
w.document.querySelector('main').appendChild(gone);
drive.snapshot({});
const goneRef = gone.__driveRef.ref;
gone.remove();
ok(drive.stale(goneRef) === true, 'stale() true for removed node');
try { drive.resolve({ ref: goneRef }); ok(false, 'stale ref throws'); }
catch (e) { eq(e.code, 'STALE_REF', 'stale ref throws STALE_REF'); }

console.log('act.fill');
const who = w.document.getElementById('who');
const events = [];
who.addEventListener('input', (e) => events.push('input:' + who.value));
who.addEventListener('change', () => events.push('change'));
const f1 = await drive.act('fill', { css: '#who' }, { text: 'Ada' });
eq(f1.ok, true, 'fill ok');
eq(who.value, 'Ada', 'fill sets value through the setter');
eq(events.join('|'), 'input:Ada|change', 'fill fires input then change: ' + events.join('|'));

console.log('act.click');
let clicked = 0;
const save = w.document.getElementById('save');
// A real handler leaves a trace — bump a DOM attribute so the auto-tier's
// "nothing happened" detector sees the page answer.
save.addEventListener('click', () => { clicked++; save.setAttribute('data-hits', String(clicked)); });
const c1 = await drive.act('click', { ref: saveRef }, {});
eq(c1.ok, true, 'click ok');
eq(clicked, 1, 'click dispatches to the element');
eq(c1.navChanged, false, 'no nav on a button without side effects');
ok(!c1.ignored && !c1.escalate, 'auto tier saw the DOM ripple — no escalation flags');
const c2 = await drive.act('click', { text: 'Save' }, {});
eq(c2.ok, true, 'click via text= ok');
eq(clicked, 2, 'text= click dispatches');
const staleAct = await drive.act('click', { ref: goneRef }, {});
eq(staleAct.code, 'STALE_REF', 'act on stale ref returns {error, code}');
ok(!!staleAct.error, 'stale act carries error string');

console.log('act.check/select/press/hover');
const k1 = await drive.act('check', { css: '#agree' }, { on: true });
eq(k1.ok, true, 'check ok');
eq(w.document.getElementById('agree').checked, true, 'checkbox toggled on');
const k2 = await drive.act('check', { css: '#agree' }, { on: true });
eq(k2.checked, true, 're-check idempotent');
const sel = w.document.getElementById('pick');
let selChanged = 0; sel.addEventListener('change', () => selChanged++);
const sv = await drive.act('select', { css: '#pick' }, { values: ['b'] });
eq(sv.ok, true, 'select ok');
eq(sel.value, 'b', 'select set');
eq(selChanged, 1, 'select fired change');
const hov = await drive.act('hover', { css: '#save' }, {});
eq(hov.ok, true, 'hover ok');
who.focus();
const keys = [];
who.addEventListener('keydown', (e) => keys.push('down:' + e.key + ':' + e.keyCode));
const p1 = await drive.act('press', null, { key: 'a' });
eq(p1.ok, true, 'press ok');
ok(keys.indexOf('down:a:65') !== -1, 'keydown carried key+keyCode: ' + keys.join(','));

console.log('iframes');
const fr = w.document.createElement('iframe');
fr.setAttribute('title', 'Inner');
fr.setAttribute('data-rect', '8,400,300,200');
w.document.querySelector('main').appendChild(fr);
await new Promise((r) => setTimeout(r, 10));
ok(!!fr.contentDocument, 'jsdom gave the iframe a document');
patchWindow(fr.contentWindow); // the frame is its own realm — mocks too
fr.contentDocument.body.innerHTML = '<button id="inner" data-rect="20,20,60,20">Inner button</button>';
const s4 = drive.snapshot({});
ok(/- iframe "Inner"/.test(s4.snapshot), 'iframe line emitted');
ok(/\[cross-origin\]/.test(s4.snapshot) === false, 'same-origin frame not flagged');
ok(/f0e\d+/.test(s4.snapshot), 'frame child ref carries f0 prefix: ' + (s4.snapshot.match(/f0e\d+/) || [])[0]);
const frameLine = s4.snapshot.split('\n').find((l) => /f0e\d+/.test(l));
ok(!!frameLine && /button "Inner button"/.test(frameLine), 'frame button emitted: ' + frameLine);
const fref = (s4.snapshot.match(/\[ref=(f0e\d+)\]/) || [])[1];
ok(drive.resolve({ ref: fref }) === fr.contentDocument.getElementById('inner'), 'frame ref resolves across documents');
const fl = drive.frames();
eq(fl.length, 1, 'frames() lists one');
eq(fl[0].sameOrigin, true, 'frame marked same-origin');
ok(fl[0].ref && /^e\d+$/.test(fl[0].ref), 'frame element itself has top-doc ref');

console.log('marks');
const m = drive.mark();
const overlay = w.document.getElementById('__drive-marks');
ok(!!overlay, 'mark() installs overlay');
ok(m.marks > 0 && overlay.children.length === m.marks, 'boxes painted: ' + m.marks);
ok(overlay.getAttribute('style').indexOf('pointer-events:none') !== -1, 'overlay is pointer-transparent');
drive.unmark();
ok(!w.document.getElementById('__drive-marks'), 'unmark() removes overlay');

console.log('scroll');
const sc = await drive.act('scroll', { css: '#below' }, { dx: 0, dy: 300 });
eq(sc.ok, true, 'scroll on element ok');
const sp = await drive.act('scroll', 'page', { dy: 500 });
eq(sp.ok, true, 'scroll page ok');
const st_ = await drive.act('scroll', null, { toText: 'Save' });
eq(st_.ok, true, 'scroll toText ok');

console.log('boxes + viewport scope');
const sb = drive.snapshot({ boxes: true });
ok(/\[box=8,200,80,28\]/.test(sb.snapshot), 'boxes emitted');
const sv2 = drive.snapshot({ scope: 'viewport' });
ok(!/Below the fold/.test(sv2.snapshot), 'viewport scope drops out-of-view elements');
ok(/- button "Save"/.test(sv2.snapshot), 'viewport scope keeps visible elements');

console.log('console + run');
w.console.log('hello from the page', { a: 1 });
w.console.error('boom');
ok(drive.console.length >= 2, 'console tapped');
ok(drive.console.some((l) => l.level === 'log' && /hello from the page/.test(l.text)), 'log line captured');
ok(drive.console.some((l) => l.level === 'error' && /boom/.test(l.text)), 'error line captured');
const r1 = await drive.run('return 1 + 1');
eq(r1.value, 2, 'run returns a value');
const r2 = await drive.run('console.log("inside run"); drive.resolve({css:"#save"}); return drive._describe(document.body)');
ok(r2.value === 'body', 'run sees the document: ' + JSON.stringify(r2));
ok(r2.consoleLines >= 1, 'run counts console lines');
const r3 = await drive.run('throw new Error("nope")');
eq(r3.error, 'nope', 'run reports errors as {error}');

console.log('keymap');
const km = drive.keymap('Enter');
eq(km.code, 'Enter', 'keymap Enter code');
eq(km.keyCode, 13, 'keymap Enter keyCode');
eq(km.chars, '\r', 'keymap Enter chars');
eq(drive.keymap('a').code, 'KeyA', 'keymap letter code');
eq(drive.keymap('a').keyCode, 65, 'keymap letter keyCode');
eq(drive.keymap('ArrowLeft').mac, 123, 'keymap arrow mac code');

console.log('event-tier handoff');
const c3 = await drive.act('click', { ref: saveRef }, { tier: 'event' });
eq(c3.ok, true, 'event tier ok');
eq(c3.handoff, 'event', 'event tier hands off with coordinates');
eq(clicked, 2, 'event tier did not JS-click');

console.log('fix 1 — frame() without rAF (hidden tab)');
{
  // A hidden tab's rAF never fires; the 50ms race keeps the loop alive.
  const realRaf = w.requestAnimationFrame;
  w.requestAnimationFrame = () => {};
  const t0 = Date.now();
  const wedged = await Promise.race([
    drive.act('click', { css: '#save' }, { tier: 'js' }).then(() => false),
    new Promise((r) => setTimeout(() => r(true), 3000)),
  ]);
  w.requestAnimationFrame = realRaf;
  eq(wedged, false, 'act completes with rAF disabled');
  ok(Date.now() - t0 < 3000, 'act finished fast without rAF (' + (Date.now() - t0) + 'ms)');
}

{
  // A truly hidden tab gets both wedges at once: no rAF and timers throttled
  // to ~1s. drive.js paces stability reads with microtasks there, so the
  // settle is fast even if every timer drags.
  w.__hidden = true;
  const realRaf = w.requestAnimationFrame;
  w.requestAnimationFrame = () => {};
  const t0 = Date.now();
  const r = await drive.act('click', { css: '#save' }, { tier: 'js' });
  w.requestAnimationFrame = realRaf;
  w.__hidden = false;
  eq(r.ok, true, 'hidden tab click still lands');
  ok(Date.now() - t0 < 1500, 'hidden tab settle stays fast (' + (Date.now() - t0) + 'ms)');
}

console.log('fix 2 — frame-space coordinates');
{
  // fr is at data-rect 8,400,300,200 in the top doc; inner is 20,20,60,20
  // in frame space — top-view centre is (8+20+30, 400+20+10) = (58, 430).
  const inner = fr.contentDocument.getElementById('inner');
  const res = await drive.act('click', { ref: inner.__driveRef.ref }, { tier: 'event' });
  eq(res.handoff, 'event', 'frame element hands off');
  eq(JSON.stringify(res.at), JSON.stringify([58, 430]), 'at is top-viewport coords: ' + JSON.stringify(res.at));
}

console.log('single-dispatch clicks');
{
  // A side effect with no DOM change must not trigger a retry.
  const dead = w.document.createElement('button');
  dead.textContent = 'Dead';
  dead.setAttribute('data-rect', '8,340,80,28');
  w.document.querySelector('main').appendChild(dead);
  drive.snapshot({});
  const deadRef = dead.__driveRef.ref;
  let requests = 0;
  dead.addEventListener('click', () => { requests++; });
  const d1 = await drive.act('click', { ref: deadRef }, {});
  eq(requests, 1, 'side effect without DOM mutation runs once');
  eq(d1.ok, true, 'auto click on dead button still reports the JS tier ran');
  eq(d1.ignored, undefined, 'a dispatched click is never retried for lack of DOM changes');
  eq(d1.tier, 'js', 'tier reported js');
  ok(Array.isArray(d1.at), 'click result carries its coordinates');

  // An occluded button must never dispatch to the overlay.
  const veil = w.document.createElement('div');
  veil.id = 'veil';
  veil.setAttribute('data-rect', '0,180,300,60'); // covers #save's 8,200,80,28 centre
  w.document.body.appendChild(veil);
  const cv = await drive.act('click', { ref: saveRef }, {});
  eq(cv.escalate, undefined, 'covered element is refused without clicking the overlay');
  eq(cv.code, 'COVERED', 'covered failure carries its reason code');
  eq(JSON.stringify(cv.at), JSON.stringify([48, 214]), 'covered failure carries element coordinates');
  veil.remove();
}

console.log('fix 4 — withSnapshot on every mutating verb');
{
  const s5 = await drive.act('select', { css: '#pick' }, { values: ['a'], withSnapshot: true });
  ok(typeof s5.snapshot === 'string' && /- combobox/.test(s5.snapshot), 'select withSnapshot');
  const k5 = await drive.act('check', { css: '#agree' }, { on: false, withSnapshot: true });
  ok(typeof k5.snapshot === 'string' && /- checkbox/.test(k5.snapshot), 'check withSnapshot');
  const h5 = await drive.act('hover', { css: '#save' }, { withSnapshot: true });
  ok(typeof h5.snapshot === 'string' && /- button/.test(h5.snapshot), 'hover withSnapshot');
  const scr5 = await drive.act('scroll', 'page', { dy: 10, withSnapshot: true });
  ok(typeof scr5.snapshot === 'string', 'scroll withSnapshot');
  const p5 = await drive.act('press', null, { key: 'Escape', withSnapshot: true });
  ok(typeof p5.snapshot === 'string', 'press withSnapshot');
  const ca5 = await drive.act('clickAt', null, { x: 48, y: 214, withSnapshot: true });
  ok(typeof ca5.snapshot === 'string', 'clickAt withSnapshot');
}

console.log('fix 5 — ARIA checkbox state + content names');
{
  const acb = w.document.createElement('div');
  acb.setAttribute('role', 'checkbox');
  acb.setAttribute('aria-checked', 'true');
  acb.setAttribute('data-rect', '8,360,140,24');
  acb.textContent = 'Pretend checkbox';
  w.document.querySelector('main').appendChild(acb);
  const s6 = drive.snapshot({});
  const line = s6.snapshot.split('\n').find((l) => /Pretend checkbox/.test(l));
  ok(!!line && /- checkbox "Pretend checkbox"/.test(line), 'role=checkbox names from content: ' + line);
  ok(!!line && /\[checked\]/.test(line), 'aria-checked=true shows [checked]');
  ok(!!line && /loc=role:checkbox/.test(line), 'aria checkbox gets a role loc');
  ok(drive.resolve({ loc: 'role:checkbox[name="Pretend checkbox"]' }) === acb, 'role loc resolves the aria checkbox');
}

console.log('open shadow roots and scoped snapshots');
{
  const host = w.document.createElement('div');
  host.attachShadow({mode: 'open'}).innerHTML = '<button id="shadow-button" data-rect="8,380,80,28">Shadow action</button>';
  w.document.body.appendChild(host);
  const tree = drive.snapshot({ interactive: true });
  ok(tree.snapshot.includes('Shadow action'), 'snapshot enters open shadow root');
  const button = drive.resolve({css: '#shadow-button'});
  ok(button === host.shadowRoot.querySelector('button'), 'CSS resolves in open shadow root');
  ok(drive.resolve({ref: button.__driveRef.ref}) === button, 'shadow refs resolve');
  const scoped = drive.snapshot({ref: button.__driveRef.ref});
  ok(scoped.snapshot.includes('Shadow action') && !scoped.snapshot.includes('Below the fold'), 'ref limits snapshot scope');
  host.remove();
}

console.log('fix 6 — refs pruned per snapshot');
{
  const tmp = w.document.createElement('button');
  tmp.textContent = 'Ephemeral';
  tmp.setAttribute('data-rect', '8,380,80,28');
  w.document.querySelector('main').appendChild(tmp);
  drive.snapshot({});
  const tref = tmp.__driveRef.ref;
  ok(drive.refs.has(tref), 'ref registered');
  tmp.remove();
  drive.snapshot({});
  ok(!drive.refs.has(tref), 'snapshot prunes disconnected refs');
}

console.log('fix 7 — misc correctness');
{
  // labelledby beats label.
  const lb = w.document.createElement('button');
  lb.setAttribute('aria-label', 'The Aria Name');
  lb.setAttribute('aria-labelledby', 'lbbits');
  lb.setAttribute('data-rect', '8,420,80,28');
  const src = w.document.createElement('span');
  src.id = 'lbbits';
  src.textContent = 'The Labelledby Name';
  w.document.querySelector('main').appendChild(src);
  w.document.querySelector('main').appendChild(lb);
  const s7 = drive.snapshot({});
  ok(/- button "The Labelledby Name"/.test(s7.snapshot), 'aria-labelledby outranks aria-label');

  // visibility:hidden mutes its own line; opacity:0 takes the subtree.
  const vh = w.document.createElement('button');
  vh.id = 'vishid'; vh.textContent = 'Invisible words'; vh.style.visibility = 'hidden';
  vh.setAttribute('data-rect', '8,450,80,28');
  const op = w.document.createElement('div');
  op.style.opacity = '0';
  const opb = w.document.createElement('button');
  opb.id = 'opaque'; opb.textContent = 'Zero opacity'; opb.setAttribute('data-rect', '8,480,80,28');
  op.appendChild(opb);
  w.document.querySelector('main').appendChild(vh);
  w.document.querySelector('main').appendChild(op);
  const s8 = drive.snapshot({});
  ok(!/Invisible words/.test(s8.snapshot), 'visibility:hidden emits no line');
  ok(!/Zero opacity/.test(s8.snapshot), 'opacity:0 prunes the subtree');

  // Middle click surfaces as auxclick, never click.
  const mid = w.document.getElementById('save');
  let midClicks = [], midAux = [];
  mid.addEventListener('click', () => midClicks.push(1));
  mid.addEventListener('auxclick', () => midAux.push(1));
  await drive.act('click', { css: '#save' }, { button: 'middle', tier: 'js' });
  eq(midAux.length, 1, 'middle click fires auxclick');
  eq(midClicks.length, 0, 'middle click does not fire click');

  // keypress belongs to keys that make text.
  const tgt = w.document.getElementById('who');
  tgt.focus(); // the press target is the active element — point it back
  let kp = 0;
  tgt.addEventListener('keypress', () => kp++);
  await drive.act('press', null, { key: 'Escape' });
  eq(kp, 0, 'Escape gets no keypress');
  await drive.act('press', null, { key: 'a' });
  eq(kp, 1, 'printable key keeps keypress');
  await drive.act('press', null, { key: 'Enter' });
  eq(kp, 2, 'Enter keeps keypress');

  // A malformed selector is NOT_FOUND with a string code, not a leaked
  // DOMException number.
  const bad = await drive.act('click', { loc: 'css:###[[[' }, {});
  eq(bad.code, 'NOT_FOUND', 'bad css loc is NOT_FOUND: ' + JSON.stringify(bad.code));
  ok(typeof bad.code === 'string', 'error code stays a string');
  const bad2 = await drive.act('click', { css: '###[[[' }, {});
  eq(bad2.code, 'NOT_FOUND', 'bad css query is NOT_FOUND too');
}

console.log('fix 8 — click inside a same-origin iframe is not ignored');
{
  // Regression for the double-fire: the post-click MutationObserver used
  // to root at the TOP document's documentElement, so a frame-local DOM
  // ripple read as silence — ignored:true — and Drive.swift's real
  // NSEvent re-clicked the same point (a counter went 0→2). jsdom hosts
  // same-origin iframes as genuine second documents/realms (the iframe
  // section above relies on it), so this is the true topology, not a
  // stand-in.
  const inner = fr.contentDocument.getElementById('inner');
  let inClicks = 0;
  inner.addEventListener('click', () => {
    inClicks++;
    inner.setAttribute('data-hits', String(inClicks)); // mutates the FRAME doc only
  });
  const res = await drive.act('click', { ref: inner.__driveRef.ref }, {});
  eq(res.ok, true, 'frame click ok');
  eq(inClicks, 1, 'frame handler fired once');
  ok(!res.ignored, 'frame DOM ripple seen — no ignored:true, no double-click');
}

console.log('\n' + passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
