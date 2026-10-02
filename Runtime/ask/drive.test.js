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
    <input id="who" type="text" value="initial-attribute-marker" data-rect="8,110,200,22">
    <label for="notes">Notes</label>
    <textarea id="notes" data-rect="8,135,200,40">initial-textarea-marker</textarea>
    <label for="secret">Password</label>
    <input id="secret" type="password" value="secret-password-marker" data-rect="8,178,200,22">
    <input type="mystery" value="invalid-type-marker">
    <input type="hidden" value="hidden-input-marker">
    <input type="text" style="display:none" value="display-none-marker">
    <div aria-hidden="true"><input type="text" value="aria-hidden-marker"></div>
    <input id="agree" type="checkbox" data-rect="8,140,16,16">
    <select id="pick" data-rect="8,170,120,22"><option value="a">Aye</option><option value="b">Bee</option></select>
    <button id="save" data-rect="8,200,80,28">Save</button>
  </form>
  <div id="cursorDiv" style="cursor:pointer" data-rect="8,240,100,30">not a button but acts like one</div>
  <svg id="plot" width="200" height="100">
    <path id="decorative" d="M0 0L10 10" />
    <text id="svg-static" x="8" y="20" data-rect="180,580,30,20">3</text>
    <text id="svg-action" role="button" aria-label="SVG action" x="8" y="40" data-rect="180,610,50,20">1</text>
    <text id="svg-pointer" style="cursor:pointer" x="8" y="60" data-rect="180,650,40,20">2</text>
    <text id="svg-hidden" aria-hidden="true" x="8" y="80" data-rect="180,710,60,20">hiddenSVG</text>
  </svg>
  <input type="hidden" value="ghost">
  <button id="below" data-rect="8,2000,80,28">Below the fold</button>
</main>
</body></html>`;

// jsdom gives each iframe its own realm — prototypes included — so the
// layout mocks have to be installed per window, not once.
function patchWindow(w) {
  // jsdom's outside-only Window fails the generated EventTarget realm check.
  // Keep a real event target for window lifecycle events exercised below.
  const windowEvents = w.document.createDocumentFragment();
  for (const method of ['addEventListener', 'removeEventListener', 'dispatchEvent']) {
    w[method] = windowEvents[method].bind(windowEvents);
  }
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
const who = w.document.getElementById('who');
who.value = 'Ada "typed"';
const notes = w.document.getElementById('notes');
notes.value = 'unsaved draft';
const s1 = drive.snapshot({});
const out = s1.snapshot;
console.log('--- snapshot ---\n' + out + '\n----------------');
ok(s1.url === 'https://fixture.test/' && s1.title === '', 'snapshot carries url+title');
ok(/- navigation "Main"/.test(out), 'nav landmark with aria name');
ok(/- link "Home" \[/.test(out) || /- link "Home" \*\[/.test(out), 'link line with ref');
ok(/- heading "A small fixture" \[level=1\]/.test(out), 'heading with level');
ok(/- "Words for the agent to read\."/.test(out), 'text run line');
ok(/- textbox "Your name"/.test(out), 'input named by <label for>');
ok(/- textbox "Your name".*\[value="Ada \\"typed\\""\]/.test(out), 'input snapshot shows its live value beside the accessible name');
ok(/- textbox "Notes".*\[value="unsaved draft"\]/.test(out), 'textarea snapshot shows its live value');
ok(/\[value="invalid-type-marker"\]/.test(out) && w.document.querySelector('input[type="mystery"]').type === 'text', 'invalid input types use the normalized text type');
ok(!out.includes('initial-attribute-marker') && !out.includes('initial-textarea-marker'), 'snapshot omits stale default values');
ok(!out.includes('secret-password-marker') && !out.includes('hidden-input-marker') && !out.includes('display-none-marker') && !out.includes('aria-hidden-marker'), 'snapshot excludes password and hidden field values');
notes.value = '  exact\ttext\nwith a trailing space ';
ok(drive.snapshot({}).snapshot.includes('[value=' + JSON.stringify(notes.value) + ']'), 'field values preserve exact whitespace and escape control characters');
notes.value = 'unsaved draft';
ok(/- checkbox/.test(out), 'checkbox line');
ok(/- combobox/.test(out), 'select as combobox');
ok(/- button "Save" \*?\[ref=e\d+\]/.test(out), 'button line with ref');
ok(/- button "Save" \*?\[ref=e\d+\].*\[loc=css:#save\]/.test(out), 'css loc beside ref');
ok(/\[loc=role:button\[name="Save"\]\]/.test(out), 'role loc beside ref');
ok(/- generic \*?\[ref=e\d+\]/.test(out), 'cursor:pointer div earns a generic+ref line');
ok(/- "3"/.test(out), 'visible SVG text appears in the full snapshot');
ok(/- button "SVG action" \*?\[ref=e\d+\]/.test(out), 'explicit SVG role and label produce a ref');
ok(/- generic \*?\[ref=e\d+\].*\[loc=css:#svg-pointer\]/.test(out), 'pointer SVG text earns a ref');
ok(!/decorative/.test(out), 'decorative SVG paths stay out of the snapshot');
ok(!/hiddenSVG/.test(out), 'aria-hidden SVG text stays out of the snapshot');
ok(!/hidden/.test(out.match(/ghost/) || ''), 'input[type=hidden] skipped');
ok(/below the fold/.test(out), 'below-fold note emitted');
ok(/note: 1 interactive element below/.test(out), 'exactly one below-fold element counted');

console.log('snapshot text colors');
const colorDom = makeDom('<div style="color:rgb(255,0,0)">Target</div><span style="color:rgb(27,155,216)">Other</span><button style="color:rgb(0,128,0)">Confirm</button><div style="display:none;color:red">hiddenColor</div><div aria-hidden="true" style="color:red">ariaColor</div><div style="visibility:hidden;color:red"><span style="visibility:visible;color:blue">Visible child</span></div><button aria-label="Icon only" style="color:red"></button><svg><text style="fill:red;color:blue">SVG label</text></svg>');
colorDom.window.eval(readFileSync(DRIVE, 'utf8'));
const colored = colorDom.window.__drive.snapshot({ textColors: true }).snapshot;
ok(/- "Target" \[color=rgb\(255, 0, 0\)\]/.test(colored), 'text colors expose computed rendered text color');
ok(/- "Other" \[color=rgb\(27, 155, 216\)\]/.test(colored), 'each text line retains its own color');
ok(/- button "Confirm".*\[color=rgb\(0, 128, 0\)\]/.test(colored), 'named controls carry their rendered text color');
ok(!colored.includes('hiddenColor') && !colored.includes('ariaColor'), 'colored snapshots retain hidden-text filtering');
ok(/- "Visible child" \[color=rgb\(0, 0, 255\)\]/.test(colored), 'visible child uses its own color under a hidden ancestor');
ok(!colorDom.window.__drive.snapshot({}).snapshot.includes('[color='), 'text colors are opt-in');
ok(/- button "Icon only"[^\n]*$/.test(colored.split('\n').find(line => line.includes('Icon only'))) && !colored.split('\n').find(line => line.includes('Icon only')).includes('[color='), 'ARIA-only names have no rendered text color');
ok(/- "SVG label" \[color=rgb\(255, 0, 0\)\]/.test(colored), 'SVG text uses fill rather than its unrelated CSS color');
const colorTarget = colorDom.window.document.querySelector('div');
colorTarget.style.color = 'blue';
ok(/- "Target" \[color=rgb\(0, 0, 255\)\]/.test(colorDom.window.__drive.snapshot({ textColors: true }).snapshot), 'colored snapshots read changed feedback rather than cache it');
colorDom.window.close();
const nestedDom = makeDom('<button><span style="color:red">Nested label</span></button><svg><text style="fill:blue">Base<tspan style="fill:red">Accent</tspan></text></svg><p style="opacity:0;color:red">opacityColor</p>');
nestedDom.window.eval(readFileSync(DRIVE, 'utf8'));
const nestedColors = nestedDom.window.__drive.snapshot({ textColors: true }).snapshot;
ok(/- "Nested label" \[color=rgb\(255, 0, 0\)\]/.test(nestedColors), 'full color snapshot retains nested HTML text feedback');
ok(!nestedDom.window.__drive.snapshot({ textColors: true, interactive: true }).snapshot.includes('[color='), 'interactive-only snapshot does not guess an aggregate label color');
ok(nestedColors.includes('BaseAccent') && !nestedColors.split('\n').find(line => line.includes('BaseAccent')).includes('[color='), 'aggregate SVG labels do not claim a single fill');
ok(!nestedColors.includes('opacityColor'), 'colored snapshots omit opacity-zero text');
nestedDom.window.close();
const paintDom = makeDom('<svg><defs><linearGradient id="mix"><stop stop-color="red"/></linearGradient></defs><text style="fill:url(#mix)">Gradient</text><text style="fill:none;stroke:red">Stroke only</text><text style="fill:red;fill-opacity:0;stroke:blue">Transparent fill</text></svg>');
paintDom.window.eval(readFileSync(DRIVE, 'utf8'));
const paintSnapshot = paintDom.window.__drive.snapshot({ textColors: true }).snapshot;
ok(paintSnapshot.includes('Gradient') && paintSnapshot.includes('Stroke only') && !paintSnapshot.includes('[color='), 'SVG non-solid fills are not mislabeled as colors');
ok(paintSnapshot.includes('Transparent fill') && !paintSnapshot.split('\n').find(line => line.includes('Transparent fill')).includes('[color='), 'SVG fill-opacity-zero text does not claim its unpainted fill color');
paintDom.window.close();



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
ok(drive.resolve({ loc: 'role:button[name="SVG action"]' }) === w.document.getElementById('svg-action'), 'role loc resolves an explicit SVG button');
ok(drive.resolve({ text: '2' }) === w.document.getElementById('svg-pointer'), 'text locator resolves visible interactive SVG text');
try { drive.resolve({ text: 'hiddenSVG' }); ok(false, 'hidden SVG text must not resolve'); }
catch (e) { ok(e.code === 'NOT_FOUND', 'hidden SVG text is not locator-visible'); }
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

const date = w.document.createElement('input');
date.id = 'date'; date.type = 'date'; date.value = '2011-01-01';
date.setAttribute('data-rect', '8,110,200,22');
w.document.body.appendChild(date);
let dateEvents = 0;
date.addEventListener('input', () => dateEvents++);
const beforeDateFocus = w.document.activeElement;
const invalidDate = await drive.act('fill', { css: '#date' }, { text: '05/20/2010' });
eq(invalidDate.code, 'INVALID_ARGUMENT', 'fill rejects a date value the browser would sanitize away');
eq(date.value, '2011-01-01', 'invalid fill preserves the existing field value');
eq(w.document.activeElement, beforeDateFocus, 'invalid fill preserves focus');
eq(dateEvents, 0, 'invalid fill emits no input event');
eq((await drive.act('fill', { css: '#date' }, { text: '2010-05-20' })).ok, true, 'fill accepts the native date format');
ok(drive.snapshot({}).snapshot.includes('[type=date] [value="2010-05-20"]'), 'snapshot exposes date type and exact value');
date.type = 'number'; date.value = '5';
eq((await drive.act('fill', { css: '#date' }, { text: 'five' })).code, 'INVALID_ARGUMENT', 'number sanitization also fails explicitly');
eq(date.value, '5', 'invalid number fill preserves the current value');
date.remove();

for (const [tag, attribute] of [['input', 'readonly'], ['textarea', 'readonly'], ['input', 'aria-readonly']]) {
  const field = w.document.createElement(tag);
  field.id = 'read-only'; field.value = 'original';
  field.setAttribute(attribute, attribute === 'aria-readonly' ? 'true' : '');
  field.setAttribute('data-rect', '8,110,200,22');
  w.document.body.appendChild(field);
  let events = 0;
  field.addEventListener('input', () => events++);
  field.addEventListener('change', () => events++);
  const beforeFocus = w.document.activeElement;
  eq((await drive.act('fill', { css: '#read-only' }, { text: 'changed' })).code, 'READ_ONLY', tag + ' ' + attribute + ' fill fails explicitly');
  eq(field.value, 'original', 'read-only fill preserves the value');
  eq(w.document.activeElement, beforeFocus, 'read-only fill preserves focus');
  eq(events, 0, 'read-only fill emits no editing event');
  ok(drive.snapshot({}).snapshot.includes('[readonly] [value="original"]'), 'snapshot exposes read-only state and current value');
  field.remove();
}

console.log('act.drag');
const dragSource = w.document.createElement('div');
dragSource.id = 'drag-source'; dragSource.textContent = 'Drag me';
dragSource.setAttribute('data-rect', '20,340,60,30');
const dragTarget = w.document.createElement('div');
dragTarget.id = 'drag-target'; dragTarget.textContent = 'Drop here';
dragTarget.setAttribute('data-rect', '180,340,80,40');
w.document.querySelector('main').append(dragSource, dragTarget);
drive.snapshot({});
const dragged = await drive.act('drag', { css: '#drag-source' }, { to: { css: '#drag-target' }, steps: 6 });
eq(dragged.handoff, 'drag', 'drag hands off to the native tier');
eq(dragged.from.join(','), '50,355', 'drag source center returned');
eq(dragged.to.join(','), '220,360', 'drag destination center returned');
eq(dragged.steps, 6, 'drag step count returned');
eq(dragged.holdMs, 0, 'drag defaults to no endpoint hold');
for (const holdMs of [0, 350, 2000]) {
  const held = await drive.act('drag', { css: '#drag-source' }, { to: [300, 380], holdMs });
  eq(held.holdMs, holdMs, 'drag preserves explicit hold duration ' + holdMs);
}
for (const holdMs of [-1, 2001, 1.5, Infinity, NaN, '350', true, null]) {
  const invalid = await drive.act('drag', { css: '#missing' }, { to: [300, 380], holdMs });
  eq(invalid.code, 'INVALID_ARGUMENT', 'invalid hold is rejected before resolving the source: ' + String(holdMs));
}
const draggedAt = await drive.act('drag', { css: '#drag-source' }, { to: [300, 380] });
eq(draggedAt.to.join(','), '300,380', 'coordinate destination accepted');
const draggedFrom = await drive.act('drag', { css: '#drag-source' }, { source: [35, 345], to: [300, 380], path: [[70, 360], [120, 370]] });
eq(draggedFrom.from.join(','), '35,345', 'coordinate source accepted');
eq(draggedFrom.path.length, 2, 'continuous path passed to the native tier');
const badDrag = await drive.act('drag', { css: '#drag-source' }, { to: [-1, 500] });
eq(badDrag.code, 'NOT_FOUND', 'out-of-viewport drag coordinate refused');

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
const hoverArea = w.document.querySelector('#cursorDiv');
const hoveredPoints = [];
const hoverEvents = [];
for (const type of ['pointerover', 'mouseover', 'mousemove', 'pointerenter', 'mouseenter']) {
  hoverArea.addEventListener(type, e => hoverEvents.push([e.type, e.clientX, e.clientY, e.buttons]));
}
let hoverClicks = 0;
hoverArea.addEventListener('mousemove', e => { hoveredPoints.push([e.clientX, e.clientY]); hoverArea.textContent = 'Pointer feedback ' + e.clientX + ',' + e.clientY; });
hoverArea.addEventListener('click', () => hoverClicks++);
const coordinateHover = await drive.act('hover', {}, { x: 20, y: 251, withSnapshot: true });
eq(coordinateHover.ok, true, 'coordinate hover succeeds');
eq(coordinateHover.element, 'div#cursorDiv', 'hover identifies the hit element so stale feedback outside a control can be recognized');
eq(JSON.stringify(hoveredPoints), '[[20,251]]', 'coordinate hover dispatches the requested point instead of element center');
eq(hoverClicks, 0, 'coordinate hover never clicks');
eq(JSON.stringify(hoverEvents), JSON.stringify(['pointerover', 'mouseover', 'mousemove', 'pointerenter', 'mouseenter'].map(type => [type, 20, 251, 0])), 'all hover events preserve coordinates and release mouse buttons');
const ambiguousHover = await drive.act('hover', { css: '#cursorDiv' }, { x: 20, y: 251 });
eq(ambiguousHover.code, 'INVALID_ARGUMENT', 'coordinate hover cannot also name a locator');
eq(hoveredPoints.length, 1, 'ambiguous hover dispatches no events');
ok(coordinateHover.snapshot && coordinateHover.snapshot.includes('Pointer feedback 20,251'), 'coordinate hover returns updated visible feedback');
for (const args of [{x: -1,y: 251}, {x: 20}, {x: Infinity,y: 251}, {x: w.innerWidth,y: 251}, {x: 20,y: -1}, {x: 20,y: w.innerHeight}]) {
  const before = hoveredPoints.length;
  const invalid = await drive.act('hover', {}, args);
  eq(invalid.code, 'INVALID_ARGUMENT', 'invalid coordinate hover is refused');
  eq(hoveredPoints.length, before, 'invalid coordinate hover dispatches no events');
}

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
const svgPointer = w.document.getElementById('svg-pointer');
let svgClicks = 0;
svgPointer.addEventListener('click', () => { svgClicks++; });
const svgRef = refOf('svg-pointer');
const sequence = [];
for (const type of ['pointerover', 'mouseover', 'mousemove', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'dblclick']) {
  svgPointer.addEventListener(type, (e) => sequence.push([e.type, e.buttons]));
}
const svgJsClick = await drive.act('click', { ref: svgRef }, { tier: 'js' });
eq(svgJsClick.ok, true, 'SVG text receives a JavaScript-tier click');
eq(sequence.map(([type]) => type).join(','), 'pointerover,mouseover,mousemove,pointerdown,mousedown,pointerup,mouseup,click', 'click event order is complete');
eq(sequence.filter(([type]) => type === 'pointerdown' || type === 'mousedown').map(([, buttons]) => buttons).join(','), '1,1', 'down events report a pressed button');
eq(sequence.filter(([type]) => type === 'pointerup' || type === 'mouseup' || type === 'click').map(([, buttons]) => buttons).join(','), '0,0,0', 'release and click events report no pressed buttons');
const svgClick = await drive.act('click', { ref: svgRef }, { tier: 'event' });
eq(svgClick.handoff, 'event', 'SVG text click hands off to the native event tier: ' + JSON.stringify(svgClick));
eq(JSON.stringify(svgClick.at), JSON.stringify([200, 660]), 'SVG text handoff uses its center point');
eq(svgClicks, 1, 'native SVG click handoff does not dispatch a second JavaScript click');
sequence.length = 0;
await drive.act('click', { ref: svgRef }, { double: true });
eq(sequence.filter(([type]) => type === 'pointerdown' || type === 'mousedown').map(([, buttons]) => buttons).join(','), '1,1,1,1', 'double-click down events report a pressed button');
eq(sequence.filter(([type]) => ['pointerup', 'mouseup', 'click', 'dblclick'].includes(type)).map(([, buttons]) => buttons).join(','), '0,0,0,0,0,0,0', 'both clicks and double-click report released buttons');

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

console.log('compact snapshots, bounded action evidence and live driver upgrades');
{
  const full = drive.snapshot({ interactive: true });
  const compact = drive.snapshot({ interactive: true, cssLocators: false });
  ok(full.snapshot.includes('[loc=css:'), 'SDK snapshot keeps CSS locators by default');
  ok(!compact.snapshot.includes('[loc=css:') && compact.snapshot.includes('[loc=role:'), 'compact snapshot retains role locators');
  const limited = await drive.act('click', { css: '#save' }, { withSnapshot: true, snapshotMaxChars: 500, cssLocators: false });
  ok(limited.ok && limited.snapshot.length < 1000 && limited.snapshotTruncated, 'bounded post-action snapshot has an explicit marker');
  ok(!limited.snapshot.includes('[loc=css:'), 'post-action snapshot honors compact mode');
  const reinserted = w.document.createElement('button');
  reinserted.textContent = 'Reinserted';
  w.document.body.appendChild(reinserted);
  drive.snapshot({});
  const ref = reinserted.__driveRef.ref;
  reinserted.remove(); drive.snapshot({});
  w.document.body.appendChild(reinserted); drive.snapshot({});
  ok(drive.resolve({ ref }) === reinserted, 'reinserted elements re-register their existing ref');
  reinserted.remove();

  const upgrade = new JSDOM('<button id="old">Old</button>', { url: 'https://example.test', runScripts: 'outside-only' });
  const uw = upgrade.window;
  uw.eval(readFileSync(DRIVE, 'utf8').replace('const BUILD = 8;', 'const BUILD = 7;'));
  uw.__drive.snapshot({});
  const old = uw.document.getElementById('old'), oldRef = old.__driveRef.ref;
  const removed = uw.document.createElement('button'); removed.textContent = 'Removed'; uw.document.body.appendChild(removed);
  uw.__drive.snapshot({}); const removedRef = removed.__driveRef.ref;
  removed.remove(); uw.__drive.snapshot({});
  delete uw.__drive._refCounter; delete uw.__drive._refEpoch; // simulate the legacy public state
  uw.eval(readFileSync(DRIVE, 'utf8'));
  const fresh = uw.document.createElement('button'); fresh.textContent = 'Fresh'; uw.document.body.appendChild(fresh);
  uw.__drive.snapshot({});
  ok(uw.__drive.resolve({ ref: oldRef }) === old, 'upgrade preserves advertised legacy refs');
  ok(uw.__drive.resolve({ ref: fresh.__driveRef.ref }) === fresh && fresh.__driveRef.ref !== removedRef,
     'upgrade cannot alias a pruned legacy ref');
  const firstNew = fresh.__driveRef.ref; fresh.remove(); uw.__drive.snapshot({});
  uw.eval(readFileSync(DRIVE, 'utf8').replace('const BUILD = 8;', 'const BUILD = 9;'));
  const newer = uw.document.createElement('button'); newer.textContent = 'Newer'; uw.document.body.appendChild(newer);
  uw.__drive.snapshot({});
  ok(newer.__driveRef.ref !== firstNew && uw.__drive.resolve({ ref: newer.__driveRef.ref }) === newer,
     'later upgrades preserve the counter beyond pruned refs');
  upgrade.window.close();
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

console.log('attention highlights');
{
  const doc = w.document, win = w;
  const target = doc.getElementById('save');
  const before = target.getAttribute('style');
  const owner = 'attention-test';
  let highlightBox;
  const attachShadow = w.Element.prototype.attachShadow;
  w.Element.prototype.attachShadow = function (opts) {
    const shadow = attachShadow.call(this, opts);
    if (this.hasAttribute('data-search-highlight')) highlightBox = shadow;
    return shadow;
  };
  eq(drive.highlight({ css: '#save' }, { duration: 1, scroll: false }, owner).highlighted, true, 'target is highlighted');
  w.Element.prototype.attachShadow = attachShadow;
  const overlay = doc.querySelector('[data-search-highlight]');
  ok(overlay && overlay.style.pointerEvents === 'none', 'outline allows page clicks');
  eq(overlay.shadowRoot, null, 'outline styles are isolated in a closed shadow root');
  eq(target.getAttribute('style'), before, 'target styles are preserved');
  const oldRect = target.getAttribute('data-rect');
  target.setAttribute('data-rect', '44,88,120,40');
  await new Promise(r => setTimeout(r, 150));
  eq(highlightBox.firstChild.style.left, '44px', 'outline follows target position');
  eq(highlightBox.firstChild.style.width, '120px', 'outline follows target size');
  target.setAttribute('data-rect', oldRect);
  eq(drive.clearHighlight('other').cleared, false, 'another session cannot clear the outline');
  let busy = false;
  try { drive.highlight({ css: '#save' }, {}, 'other'); } catch (e) { busy = e.code === 'BUSY'; }
  ok(busy, 'another session cannot replace the outline');
  eq(drive.clearHighlight(owner).cleared, true, 'owner can clear the outline');
  for (const [q, opts] of [[{}, {}], [{ css: '#save', text: 'Save' }, {}], [{ css: '' }, {}], [{ css: '#save' }, { duration: 31 }], [{ css: '#save' }, { duration: true }], [{ css: '#save' }, { scroll: 1 }]]) {
    let invalid = false;
    try { drive.highlight(q, opts, owner); } catch (e) { invalid = e.code === 'INVALID_ARGUMENT'; }
    ok(invalid, 'malformed highlight rejected: ' + JSON.stringify([q, opts]));
  }
  drive.highlight({ css: '#save' }, { duration: 1 }, owner);
  doc.dispatchEvent(new win.KeyboardEvent('keydown', { key: 'Escape' }));
  eq(doc.querySelector('[data-search-highlight]'), null, 'Escape dismisses outline');
  drive.highlight({ css: '#save' }, { duration: 1 }, owner);
  await new Promise(r => setTimeout(r, 1100));
  eq(doc.querySelector('[data-search-highlight]'), null, 'outline expires');
  const removed = doc.createElement('button');
  removed.id = 'attention-removed'; doc.body.appendChild(removed);
  drive.highlight({ css: '#attention-removed' }, { scroll: false }, owner);
  removed.remove();
  await new Promise(r => setTimeout(r, 150));
  eq(doc.querySelector('[data-search-highlight]'), null, 'removed target cleans up outline');
  const framed = fr.contentDocument.getElementById('inner');
  drive.highlight({ ref: framed.__driveRef.ref }, { scroll: false }, owner);
  ok(fr.contentDocument.querySelector('[data-search-highlight]'), 'outline uses target frame geometry');
  fr.contentDocument.dispatchEvent(new fr.contentWindow.KeyboardEvent('keydown', { key: 'Escape' }));
  eq(fr.contentDocument.querySelector('[data-search-highlight]'), null, 'frame Escape dismisses outline');
  drive.highlight({ css: '#save' }, { scroll: false }, owner);
  win.dispatchEvent(new win.Event('pagehide'));
  eq(doc.querySelector('[data-search-highlight]'), null, 'navigation clears outline before back-forward caching');
}

console.log('\n' + passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
