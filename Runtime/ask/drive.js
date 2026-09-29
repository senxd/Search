// Ask — the page-side half of the agent.
//
// There is no CDP and no extension world to hide in: everything the agent
// knows about a page is computed here, in the page's own JavaScript, and
// comes back over evaluateJavaScript as one JSON-safe object per call.
// Swift prepends this file to everything it evaluates, so installing has to
// be cheap and safe to repeat — the guard below is the whole story, and a
// fresh document is what makes an old `window.__drive` go away rather than
// anything we clean up ourselves.
//
// The snapshot model is playwright-mcp's: the page is a tree of roles and
// accessible names, and anything the agent might touch carries a `ref`
// (e3, f0e7 inside the first iframe) that persists on the element itself as
// `__driveRef`. An unchanged element keeps the same ref from one snapshot
// to the next; a changed one earns a new one. Refs are the cheap diff the
// agent reads; `loc=` handles are the durable ones that survive staleness.
//
// Everything here is dependency-free and assumes nothing about layout
// beyond what WebKit gives a real page: a rect, a computed style, an
// elementFromPoint. When one of those is missing a verb degrades rather
// than throws, because an agent halfway down a retry loop deserves an
// answer, not an exception.
(function () {
'use strict';

// `v` is the build of this file — the guard compares it so a newer drive.js
// can replace an older one mid-session. It is not `version`, which is the
// snapshot lineage the protocol speaks about.
const BUILD = 4;
if (window.__drive && window.__drive.v >= BUILD) return;

// ---------------------------------------------------------------- util

const now = () => (window.performance && window.performance.now ? window.performance.now() : Date.now());
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// rAF never fires on a hidden or offscreen tab — and bench tabs are
// offscreen by design — so a bare requestAnimationFrame would wedge the
// actionability loop forever. Hidden pages also throttle timers down to
// ~1s each, which turns the two-frame stability read into seconds per
// iteration; pacing it with microtasks is safe there because nothing can
// move the layout between two microtask reads on a page nobody paints.
// On a visible tab rAF races a 50ms timer, keeping paint pace when there
// is paint and never outstaying it when there isn't.
const frame = () => {
  if (document.hidden || !window.requestAnimationFrame) return Promise.resolve();
  return Promise.race([new Promise((r) => window.requestAnimationFrame(() => r())), sleep(50)]);
};

const collapse = (s) => String(s).replace(/\s+/g, ' ').trim();
const clip = (s, n) => { s = collapse(s); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
const esc = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');

// jsdom doesn't know innerText; the page does. Either way this is the
// visible-words approximation a name is computed from.
const text = (el) => collapse((el.innerText !== undefined ? el.innerText : el.textContent) || '');

// Just the element's own text nodes — what becomes a `- "…"` run when the
// element hasn't already spent that text as its name.
const ownText = (el) => {
  let s = '';
  for (const n of el.childNodes || []) if (n.nodeType === 3) s += n.nodeValue;
  return collapse(s);
};

const rect = (el) => {
  try { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height, top: r.top, left: r.left }; }
  catch (e) { return { x: 0, y: 0, w: 0, h: 0, top: 0, left: 0 }; }
};

const style = (el) => { try { return window.getComputedStyle(el); } catch (e) { return null; } };

// ---------------------------------------------------------------- version

// `version` only has to do one thing: never repeat within a tab, so a ref
// minted before a navigation can never be mistaken for a live one. It bumps
// on every snapshot and once on load; sessionStorage carries it across
// documents when the page lets us, Date.now() when it won't.
let version = 0;
try { version = parseInt(window.sessionStorage.getItem('__drive.version'), 10) || 0; } catch (e) { version = 0; }
if (!version) version = Math.floor(Date.now() % 1e9) || 1;
function bumpVersion() {
  version += 1;
  try { window.sessionStorage.setItem('__drive.version', String(version)); } catch (e) { /* private worlds */ }
  return version;
}

// ---------------------------------------------------------------- state

let refCounter = 0;                                  // mints e1, e2, … — never reused
const refs = new Map();                              // ref -> WeakRef<Element>
let prevRefs = new Set();                            // refs present at the end of the last snapshot — the `*` diff
const consoleLines = [];                             // ring buffer, last 200

// Each element's ref is also written on the element as {ref, role, name,
// prefix} — that record is what lets a re-snapshot notice "same role, same
// name" and hand back the same ref instead of churning.
function ensureRef(el, role, name, prefix) {
  const cur = el.__driveRef;
  if (cur && cur.role === role && cur.name === name && cur.prefix === (prefix || '')) return cur.ref;
  const ref = (window.__driveRefNamespace || '') + (prefix || '') + 'e' + (++refCounter);
  el.__driveRef = { ref, role, name, prefix: prefix || '' };
  refs.set(ref, new WeakRef(el));
  return ref;
}

// Where an element's document sits in the iframe nesting: '' for the top
// document, 'f0' inside the first iframe (document order), 'f0f2' a level
// deeper. Prefixes are recomputed from the frame chain rather than a walk's
// own counter, so mark() mints the same refs snapshot() would.
function docPrefix(doc) {
  let p = '';
  try {
    while (doc && doc.defaultView && doc.defaultView.frameElement) {
      const f = doc.defaultView.frameElement;
      const sibs = f.ownerDocument.querySelectorAll('iframe,frame');
      const i = Array.prototype.indexOf.call(sibs, f);
      p = 'f' + (i < 0 ? 0 : i) + p;
      doc = f.ownerDocument;
    }
  } catch (e) { /* a cross-origin ancestor ends the chain where it stands */ }
  return p;
}

// ---------------------------------------------------------------- roles

// Tags that are never content. `input[type=hidden]` joins them via roleOf's
// null; SVG subtrees are skipped on their namespace instead.
const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'META', 'LINK', 'BASE', 'TITLE', 'HEAD']);

// Explicit role= beats the tag map; the first token is the one ARIA
// believes. null means "skip this subtree entirely" — a hidden input is
// chrome the agent can never see.
function roleOf(el) {
  const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
  if (explicit) return explicit.toLowerCase();
  switch (el.tagName) {
    case 'A': case 'AREA': return el.hasAttribute('href') ? 'link' : 'generic';
    case 'BUTTON': return 'button';
    case 'INPUT': {
      const t = (el.getAttribute('type') || 'text').toLowerCase();
      if (t === 'hidden') return null;
      if (t === 'checkbox') return 'checkbox';
      if (t === 'radio') return 'radio';
      if (t === 'button' || t === 'submit' || t === 'reset' || t === 'image' || t === 'file') return 'button';
      if (t === 'range') return 'slider';
      if (t === 'number') return 'spinbutton';
      return 'textbox';
    }
    case 'TEXTAREA': return 'textbox';
    case 'SELECT': return (el.multiple || parseInt(el.getAttribute('size'), 10) > 1) ? 'listbox' : 'combobox';
    case 'OPTION': return 'option';
    case 'IMG': return 'img';
    case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
    case 'NAV': return 'navigation';
    case 'MAIN': return 'main';
    case 'HEADER': return 'banner';
    case 'FOOTER': return 'contentinfo';
    case 'FORM': return 'form';
    case 'SECTION': return 'region';
    case 'ARTICLE': return 'article';
    case 'ASIDE': return 'complementary';
    case 'DIALOG': return 'dialog';
    case 'DETAILS': return 'group';
    case 'FIELDSET': return 'group';
    case 'TABLE': return 'table';
    case 'UL': case 'OL': case 'MENU': return 'list';
    case 'LI': return 'listitem';
    case 'SUMMARY': return 'summary';
    case 'TR': return 'row';
    case 'TD': return 'cell';
    case 'TH': return 'columnheader';
    case 'IFRAME': case 'FRAME': return 'iframe';
    case 'PROGRESS': return 'progressbar';
    case 'METER': return 'meter';
    case 'HR': return 'separator';
    case 'LABEL': return 'generic';       // a name source, not a node
    default: return 'generic';
  }
}

// Roles whose name is the words inside them. Cells and listitems are
// deliberately not here — their content arrives as `- "…"` children, which
// is how a table stays readable instead of duplicating every cell twice.
const CONTENT_NAME_ROLES = new Set([
  'button', 'link', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
  'tab', 'option', 'switch', 'heading', 'summary', 'treeitem',
  'checkbox', 'radio',
]);

// Accessible name: aria-labelledby, then aria-label, then the attribute
// fallbacks, then content for the roles that are named by their contents,
// then the label/legend machinery.
function nameOf(el, role) {
  // accName order: labelledby wins over label — the referenced elements are
  // the more deliberate name.
  const lb = el.getAttribute('aria-labelledby');
  if (lb && lb.trim()) {
    const s = collapse(lb.trim().split(/\s+/)
      .map((id) => el.ownerDocument.getElementById(id))
      .filter(Boolean).map(text).filter(Boolean).join(' '));
    if (s) return clip(s, 80);
  }
  const aria = el.getAttribute('aria-label');
  if (aria && aria.trim()) return clip(aria, 80);
  const alt = el.getAttribute('alt'); if (alt && alt.trim()) return clip(alt, 80);
  const ph = el.getAttribute('placeholder'); if (ph && ph.trim()) return clip(ph, 80);
  const ti = el.getAttribute('title'); if (ti && ti.trim()) return clip(ti, 80);
  if (el.tagName === 'INPUT') {
    const t = (el.getAttribute('type') || 'text').toLowerCase();
    if (t === 'submit' || t === 'button' || t === 'reset' || t === 'image') {
      const v = el.getAttribute('value') || el.value;
      if (v && String(v).trim()) return clip(v, 80);
    }
  }
  if (CONTENT_NAME_ROLES.has(role)) {
    const t = text(el);
    if (t) return clip(t, 80);
  }
  try {
    if (el.labels && el.labels.length) {
      const s = collapse(Array.prototype.map.call(el.labels, text).filter(Boolean).join(' '));
      if (s) return clip(s, 80);
    }
  } catch (e) { /* labels is a form-affinity luxury */ }
  const wrapping = el.closest ? el.closest('label') : null;
  if (wrapping) { const s = text(wrapping); if (s) return clip(s, 80); }
  if (el.tagName === 'FIELDSET' || role === 'group') {
    const legend = el.querySelector && el.querySelector('legend');
    if (legend) { const s = text(legend); if (s) return clip(s, 80); }
  }
  return '';
}

// Roles that make an element worth a ref on their own — the widget set.
const WIDGET_ROLES = new Set([
  'button', 'link', 'textbox', 'checkbox', 'radio', 'combobox', 'listbox',
  'slider', 'spinbutton', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
  'tab', 'option', 'switch', 'treeitem', 'searchbox', 'summary', 'iframe',
]);

// Anything the agent could plausibly click, fill, or scroll earns a ref.
// cursor:pointer is how a div confesses it is a button; scrollHeight is how
// a pane confesses it is scrollable. `st` is the computed style the caller
// already paid for, when it did.
function isInteractive(el, role, st) {
  if (WIDGET_ROLES.has(role)) return true;
  if (el.tagName === 'A' && el.hasAttribute('href')) return true;
  if (el.tagName === 'INPUT' || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA' || el.tagName === 'SUMMARY') return true;
  if (el.hasAttribute('onclick')) return true;
  const ti = el.getAttribute('tabindex');
  if (ti !== null && +ti >= 0) return true;
  if (el.isContentEditable || (el.hasAttribute('contenteditable') && el.getAttribute('contenteditable') !== 'false')) return true;
  if (!st) st = style(el);
  if (st && st.cursor === 'pointer') return true;
  try { if (el.scrollHeight > el.clientHeight + 8 && el.clientHeight > 0) return true; } catch (e) {}
  return false;
}

// ---------------------------------------------------------------- locs

// The durable handles. `css:` is the shortest selector that names the
// element uniquely-ish: an id wins, then tag.first-class, then an
// nth-of-type chain climbing until something is unique. `role:` survives a
// ref going stale, which is the whole reason refs aren't enough.
const cssIdent = (s) => String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => '\\' + c);

function cssLoc(el) {
  try {
    const doc = el.ownerDocument;
    if (el.id) {
      const sel = '#' + cssIdent(el.id);
      if (doc.querySelectorAll(sel).length === 1) return sel;
    }
    const tag = el.tagName.toLowerCase();
    const cls = (el.getAttribute('class') || '').trim().split(/\s+/).filter(Boolean)[0];
    const cand = cls ? tag + '.' + cssIdent(cls) : tag;
    if (doc.querySelectorAll(cand).length === 1) return cand;
    // `a>b` with no spaces keeps the token bracket-safe in a snapshot line.
    const seg = (e) => {
      const t = e.tagName.toLowerCase();
      let i = 1;
      for (let s = e.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === e.tagName) i++;
      return t + ':nth-of-type(' + i + ')';
    };
    let path = seg(el), e = el.parentElement, hops = 0;
    while (e && hops < 4) {
      path = seg(e) + '>' + path;
      if (doc.querySelectorAll(path).length === 1) return path;
      e = e.parentElement; hops++;
    }
    return path;
  } catch (e) { return el.tagName.toLowerCase(); }
}

const roleLoc = (role, name) => 'role:' + role + (name ? '[name="' + esc(name) + '"]' : '');

// ---------------------------------------------------------------- snapshot

// One depth-first walk emits the YAML-ish tree. Indentation tracks the
// *emitted* tree, not the DOM — transparent divs collapse so nesting reads
// the way the page does. Returns lines + counters so truncation is a pure
// function of the result.
const WALK_CAP = 8000; // a safety bound for pathological pages, not a budget

function children(el) {
  if (el.tagName === 'SLOT') {
    const assigned = el.assignedElements && el.assignedElements({ flatten: true });
    if (assigned && assigned.length) return assigned;
  }
  return (el.shadowRoot || el).children || [];
}

function snapshotLines(opts) {
  const v = bumpVersion();
  const lines = [];
  const ctx = {
    visited: 0, capped: false, belowFold: 0,
    viewportOnly: opts.scope === 'viewport',
    boxes: !!opts.boxes,
    seen: new Set(),
    vw: window.innerWidth || 1024, vh: window.innerHeight || 768,
  };

  function visit(el, depth, offX, offY) {
    if (ctx.visited++ > WALK_CAP) { ctx.capped = true; return; }
    const tag = el.tagName;
    if (!tag || SKIP_TAGS.has(tag)) return;
    if (el.namespaceURI && el.namespaceURI.indexOf('svg') !== -1) return;
    if (el.hasAttribute('hidden') || el.getAttribute('aria-hidden') === 'true') return;
    const st = style(el);
    // display:none and opacity:0 take the whole subtree down with them;
    // visibility:hidden hides the element itself but a child may have
    // re-enabled it, so that one only mutes the line.
    if (st && (st.display === 'none' || +st.opacity === 0)) return;
    const hiddenVis = !!(st && (st.visibility === 'hidden' || st.visibility === 'collapse'));

    let role = roleOf(el);
    if (role === null) return;
    if (role === 'presentation' || role === 'none') role = 'generic';
    const name = nameOf(el, role);
    const interactive = isInteractive(el, role, st);
    const level = role === 'heading' ? (parseInt(tag[1], 10) || null) : null;
    const prefix = docPrefix(el.ownerDocument);

    let r = null;
    if (interactive || ctx.boxes || ctx.viewportOnly) r = rect(el);
    // offX/offY are this document's offset inside the top document, accrued
    // through iframes — viewport tests and boxes are top-coordinates.
    const shown = !hiddenVis && (!ctx.viewportOnly || !r || (r.x + offX + r.w >= 0 && r.y + offY + r.h >= 0 && r.x + offX <= ctx.vw && r.y + offY <= ctx.vh));
    // Entirely below the fold: its top edge sits under the viewport bottom.
    if (interactive && r && (r.top + offY) >= ctx.vh) ctx.belowFold++;

    let emitted = false;
    if (shown && (!opts.interactive || interactive) && (role !== 'generic' || interactive)) {
      let line = '  '.repeat(depth) + '- ' + role;
      if (name) line += ' "' + esc(name) + '"';
      if (level != null) line += ' [level=' + level + ']';
      if (interactive) {
        const ref = ensureRef(el, role, name, prefix);
        ctx.seen.add(ref);
        line += (prevRefs.has(ref) ? ' [' : ' *[') + 'ref=' + ref + ']';
        line += ' [loc=css:' + cssLoc(el) + ']';
        if (name) line += ' [loc=' + roleLoc(role, name) + ']';
      }
      if (ctx.boxes && r) line += ' [box=' + Math.round(r.x + offX) + ',' + Math.round(r.y + offY) + ',' + Math.round(r.w) + ',' + Math.round(r.h) + ']';
      // ARIA checkboxes have no `.checked` — read both worlds.
      const isChecked = el.checked === true || el.getAttribute('aria-checked') === 'true';
      if (isChecked && (role === 'checkbox' || role === 'radio' || role === 'switch' || role === 'option' || role === 'menuitemcheckbox' || role === 'menuitemradio' || role === 'treeitem')) line += ' [checked]';
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' [disabled]';
      lines.push(line);
      emitted = true;
    }
    const cd = emitted ? depth + 1 : depth;

    if (tag === 'IFRAME' || tag === 'FRAME') {
      let d = null;
      try { d = el.contentDocument; } catch (e) { d = null; }
      if (d && d.documentElement) {
        const fr = r || rect(el);
        const kids = (d.body || d.documentElement).children;
        for (const c of kids) visit(c, cd, offX + fr.left, offY + fr.top);
      } else if (emitted) {
        // Rewrite the line with its flag — cheap rather than precomputing.
        lines[lines.length - 1] += ' [cross-origin]';
      }
      return;
    }

    // Text that was spent as the element's name doesn't get said twice.
    const muted = !!name && CONTENT_NAME_ROLES.has(role);
    if (!muted && shown && !opts.interactive) {
      const t = ownText(el);
      if (t) lines.push('  '.repeat(cd) + '- "' + esc(clip(t, 120)) + '"');
    }
    // A closed <select> is a popup, not children — only an open one lists.
    if (tag === 'SELECT' && !(el.multiple || parseInt(el.getAttribute('size'), 10) > 1)) return;
    for (const c of children(el)) visit(c, cd, offX, offY);
  }

  const root = opts.ref ? resolve({ ref: opts.ref }) : opts.selector ? resolve({ css: opts.selector }) : document.body || document.documentElement;
  // A pathological nesting can run the stack out before the element cap;
  // the snapshot still answers with what it had.
  try { if (root) visit(root, 0, 0, 0); } catch (e) { ctx.capped = true; }
  prevRefs = ctx.seen;
  // Dead entries out: a WeakRef whose element was collected or detached is
  // only noise in the map, and dropping it keeps stale-detection honest —
  // resolve() still answers STALE_REF between snapshots because pruning
  // only happens here.
  for (const [k, wr] of refs) {
    const el = wr && wr.deref ? wr.deref() : null;
    if (!el || !el.isConnected) refs.delete(k);
  }
  return { lines, capped: ctx.capped, belowFold: ctx.belowFold, version: v };
}

function takeSnapshot(opts) {
  opts = opts || {};
  const res = snapshotLines(opts);
  let lines = res.lines;
  let truncated = res.capped;
  const total = lines.length;
  if (opts.maxChars && opts.maxChars > 0) {
    // Largest prefix that fits, binary-searched on cumulative lengths —
    // each line costs itself plus one newline.
    const cum = new Array(total);
    let acc = 0;
    for (let i = 0; i < total; i++) { acc += lines[i].length + (i ? 1 : 0); cum[i] = acc; }
    if (acc > opts.maxChars) {
      let lo = 0, hi = total;
      while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (cum[mid - 1] <= opts.maxChars) lo = mid; else hi = mid - 1; }
      truncated = true;
      lines = lines.slice(0, lo);
      lines.push('- … ' + (total - lo) + ' more elements');
    }
  }
  if (res.belowFold > 0) lines.push('- note: ' + res.belowFold + ' interactive element' + (res.belowFold === 1 ? '' : 's') + ' below the fold (scroll for more)');
  return { snapshot: lines.join('\n'), version: res.version, url: location.href, title: document.title, truncated };
}

// ---------------------------------------------------------------- resolve

const staleError = (ref) => ({ code: 'STALE_REF', message: 'stale ref ' + ref + ' — take a new snapshot' });
const notFound = (what) => ({ code: 'NOT_FOUND', message: 'nothing matches ' + what });

// Depth-first over every element the snapshot could have emitted, including
// down through same-origin frames — this is what loc=role: and text=
// search. Returning false from fn stops the walk.
function eachElement(fn) {
  function into(root) {
    for (const el of children(root)) {
      const tag = el.tagName;
      if (!tag || SKIP_TAGS.has(tag)) continue;
      if (el.namespaceURI && el.namespaceURI.indexOf('svg') !== -1) continue;
      if (fn(el) === false) return false;
      if (tag === 'IFRAME' || tag === 'FRAME') {
        try { const d = el.contentDocument; if (d && d.documentElement && into(d.body || d.documentElement) === false) return false; } catch (e) {}
      }
      if (into(el) === false) return false;
    }
    return true;
  }
  try { if (document.documentElement) into(document.documentElement); } catch (e) { /* deep enough to burst the stack is an answer too */ }
}

function findCSS(selector) {
  let found = document.querySelector(selector);
  if (!found) eachElement((el) => {
    if (el.matches(selector)) { found = el; return false; }
  });
  return found;
}

function pointArg(v) {
  if (Array.isArray(v)) return [+v[0], +v[1]];
  if (typeof v === 'string') { const m = v.split(','); return [+m[0], +m[1]]; }
  if (v && typeof v === 'object') return [+v.x, +v.y];
  return [NaN, NaN];
}

function resolve(query) {
  if (!query || typeof query !== 'object') throw { code: 'NOT_FOUND', message: 'empty query' };

  if (query.ref != null) {
    const ref = String(query.ref);
    const el = refs.has(ref) && refs.get(ref).deref ? refs.get(ref).deref() : null;
    if (!el) {
      // A ref we minted and lost to GC or removal is stale; one we never
      // minted (a snapshot from before the last navigation) is just gone.
      if (refs.has(ref)) throw staleError(ref);
      throw { code: 'NOT_FOUND', message: 'no such ref ' + ref + ' — it may belong to a snapshot from before the last navigation' };
    }
    if (!el.isConnected || !el.__driveRef || el.__driveRef.ref !== ref) throw staleError(ref);
    return el;
  }

  if (query.at != null) {
    const [x, y] = pointArg(query.at);
    const el = document.elementFromPoint ? document.elementFromPoint(x, y) : null;
    if (!el) throw notFound('point ' + x + ',' + y);
    return el;
  }

  if (query.loc != null) {
    const loc = String(query.loc);
    if (loc.indexOf('css:') === 0) {
      let el = null;
      // A malformed selector is a NOT_FOUND, not the DOMException's
      // numeric code leaking back over the wire.
      try { el = findCSS(loc.slice(4)); } catch (e) { el = null; }
      if (!el) throw notFound(loc);
      return el;
    }
    if (loc.indexOf('role:') === 0) {
      const m = /^role:([a-zA-Z][a-zA-Z-]*)(?:\[name="((?:\\.|[^"\\])*)"\])?\s*$/.exec(loc);
      if (!m) throw { code: 'NOT_FOUND', message: 'unparseable loc ' + loc };
      const wantRole = m[1].toLowerCase();
      const wantName = m[2] !== undefined ? m[2].replace(/\\(.)/g, '$1') : null;
      let found = null;
      eachElement((el) => {
        const role = roleOf(el);
        if (role !== wantRole) return;
        if (wantName !== null && nameOf(el, role) !== wantName) return;
        found = el; return false;
      });
      if (!found) throw notFound(loc);
      return found;
    }
    if (loc.indexOf('href:') === 0) {
      const want = loc.slice(5).replace(/"/g, '\\"');
      const el = document.querySelector('a[href="' + want + '"]') || document.querySelector('a[href*="' + want + '"]');
      if (!el) throw notFound(loc);
      return el;
    }
    if (loc.indexOf('xpath:') === 0) {
      try {
        const r = document.evaluate(loc.slice(6), document, null, 9 /* FIRST_ORDERED_NODE_TYPE */, null);
        if (r && r.singleNodeValue) return r.singleNodeValue;
      } catch (e) { /* fall through to notFound */ }
      throw notFound(loc);
    }
    throw { code: 'NOT_FOUND', message: 'loc must start css:, role:, href: or xpath: — got ' + loc };
  }

  if (query.css != null) {
    let el = null;
    try { el = findCSS(String(query.css)); } catch (e) { el = null; }
    if (!el) throw notFound('css:' + query.css);
    return el;
  }

  if (query.text != null) {
    // Bench's `text=`: the exact words of a button, link or submit, case
    // folded. Then the wider net — anything whose accessible name is it.
    const want = collapse(String(query.text)).toLowerCase();
    const cand = document.querySelectorAll('button, a, [role=button], input[type=submit], [role=link], [role=tab], summary');
    for (const el of cand) {
      if (collapse(text(el) || el.value || '').toLowerCase() === want) return el;
    }
    let found = null;
    eachElement((el) => {
      const role = roleOf(el);
      if (role === null || role === 'generic') return;
      if (nameOf(el, role).toLowerCase() !== want) return;
      found = el; return false;
    });
    if (!found) throw notFound('text=' + query.text);
    return found;
  }

  throw { code: 'NOT_FOUND', message: 'query needs ref, loc, css, text or at' };
}

// ---------------------------------------------------------------- actions

// A point in an element's own document, expressed in the top document's
// viewport — the space the native event tier's coordinates live in.
// Frame offsets accrue the same way the snapshot's walk accrues them.
function topPoint(el, x, y) {
  let doc = el.ownerDocument;
  try {
    while (doc && doc.defaultView && doc.defaultView.frameElement) {
      const f = doc.defaultView.frameElement;
      const fr = rect(f);
      x += fr.left; y += fr.top;
      doc = f.ownerDocument;
    }
  } catch (e) { /* a cross-origin ancestor — the offset stops there */ }
  return [Math.round(x), Math.round(y)];
}

// A short label for errors and results: tag plus just enough identity to
// know which element answered back.
function describeEl(el) {
  if (!el || !el.tagName) return String(el);
  let s = el.tagName.toLowerCase();
  if (el.id) s += '#' + el.id;
  else { const c = (el.getAttribute('class') || '').trim().split(/\s+/)[0]; if (c) s += '.' + c; }
  return s;
}

// Would a real user's click land on this element? Exists, connected,
// painted, enabled — then the geometry half inside a retry loop: scroll it
// into view, wait for its box to hold still across two frames, and ask
// elementFromPoint who actually sits at its centre. 4s buys a settling
// animation or a dismissed overlay; after that the honest answer is the
// name of whatever is in the way.
async function actionable(el) {
  if (!el || !el.isConnected) return { error: 'element is not connected', code: 'NOT_CONNECTED' };
  const st = style(el);
  const r0 = rect(el);
  if ((st && (st.display === 'none' || st.visibility === 'hidden' || st.visibility === 'collapse' || +st.opacity === 0)) || (r0.w <= 0 && r0.h <= 0))
    return { error: 'element is not visible', code: 'NOT_VISIBLE' };
  if (el.disabled || el.getAttribute('aria-disabled') === 'true')
    return { error: 'element is disabled', code: 'DISABLED' };

  const doc = el.ownerDocument;
  const deadline = now() + 4000;
  let lastHit = null, unstable = false, x = 0, y = 0;
  for (;;) {
    try {
      if (el.scrollIntoViewIfNeeded) el.scrollIntoViewIfNeeded({ block: 'center', inline: 'nearest' });
      else if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
    } catch (e) {}
    const r1 = rect(el); await frame(); const r2 = rect(el); await frame(); const r3 = rect(el);
    const stable = r1.x === r2.x && r1.y === r2.y && r1.w === r2.w && r1.h === r2.h && r2.x === r3.x && r2.y === r3.y;
    x = Math.round(r3.left + r3.w / 2); y = Math.round(r3.top + r3.h / 2);
    unstable = !stable;
    if (stable) {
      const hit = doc.elementFromPoint ? doc.elementFromPoint(x, y) : el;
      lastHit = hit;
      // x,y are owner-document space — what the synthetic events want;
      // `at` is top-viewport space — what the native tier clicks.
      const at = topPoint(el, x, y);
      if (!hit || hit === el || el.contains(hit)) return { x, y, at, rect: r3 };
      // A label stacked over its own control is the control, for hits.
      if (hit.tagName === 'LABEL' && (hit.control === el || hit.contains(el))) return { x, y, at, rect: r3 };
    }
    if (now() >= deadline) {
      const what = lastHit ? describeEl(lastHit) : (unstable ? 'a moving layout' : 'nothing');
      return { error: 'element does not receive events — covered by ' + what + '?', code: 'COVERED', at: topPoint(el, x, y) };
    }
    await sleep(80);
  }
}

const MOD_KEYS = { cmd: 'metaKey', meta: 'metaKey', shift: 'shiftKey', ctrl: 'ctrlKey', control: 'ctrlKey', opt: 'altKey', alt: 'altKey' };
function modInit(mods) {
  const init = { metaKey: false, shiftKey: false, ctrlKey: false, altKey: false };
  for (const m of mods || []) { const k = MOD_KEYS[String(m).toLowerCase()]; if (k) init[k] = true; }
  return init;
}

function fireMouse(el, type, x, y, opts) {
  const init = Object.assign({
    bubbles: opts.bubbles !== false, cancelable: true, composed: true, view: el.ownerDocument.defaultView || window,
    button: opts.button, buttons: opts.buttons, clientX: x, clientY: y, screenX: x, screenY: y, detail: opts.detail || 0,
  }, modInit(opts.modifiers));
  const Ctor = (type.indexOf('pointer') === 0 && window.PointerEvent) ? window.PointerEvent : window.MouseEvent;
  let ev;
  try { ev = new Ctor(type, init); }
  catch (e) {
    // A `view` that isn't the same realm's Window fails to construct —
    // cross-realm frames and jsdom both — and the event still needs to fly.
    delete init.view;
    try { ev = new Ctor(type, init); } catch (e2) { ev = new window.MouseEvent(type, { bubbles: true, cancelable: true }); }
  }
  el.dispatchEvent(ev);
  return ev;
}

// The full gesture a finger or a trackpad would produce, in order. Middle
// clicks surface as `auxclick`, right clicks as `contextmenu` — a real
// `click` belongs to the primary button alone. Returns whether the last
// activating event was cancelled: the only truthful "the page heard me"
// flag a synthetic gesture gets.
function clickGesture(el, x, y, opts) {
  const b = opts.button === 'middle' ? 1 : opts.button === 'right' ? 2 : 0;
  const buttons = b === 0 ? 1 : b === 1 ? 4 : 2;
  const send = (type, detail) => fireMouse(el, type, x, y, { button: b, buttons, detail, modifiers: opts.modifiers });
  send('pointerover'); send('mouseover'); send('mousemove');
  send('pointerdown'); send('mousedown');
  if (b === 0) { try { el.focus && el.focus(); } catch (e) {} }
  send('pointerup'); send('mouseup');
  if (b === 2) { const e = send('contextmenu'); return { prevented: !!(e && e.defaultPrevented) }; }
  const ev = send(b === 1 ? 'auxclick' : 'click');
  if (opts.double) {
    send('pointerdown'); send('mousedown'); send('pointerup'); send('mouseup');
    fireMouse(el, b === 1 ? 'auxclick' : 'click', x, y, { button: b, buttons, detail: 2, modifiers: opts.modifiers });
    if (b === 0) send('dblclick');
  }
  return { prevented: !!(ev && ev.defaultPrevented) };
}

function emit(el, type, init) {
  try {
    let e;
    if (type === 'input' && window.InputEvent) e = new window.InputEvent('input', init);
    else e = new window.Event(type, init);
    el.dispatchEvent(e);
  } catch (e) {
    try { el.dispatchEvent(new window.Event(type, { bubbles: true })); } catch (e2) {}
  }
}

// Navigation announced itself by moving location or swapping the document;
// 400ms is the settle a same-page anchor or a full load both clear. For an
// element inside a same-origin frame the document that may move is the
// FRAME's: the top location never changes when it navigates, but the frame
// element's contentDocument slot swaps for a fresh document — compare it
// against the ownerDocument the gesture targeted.
async function waitNav(el) {
  const href = location.href, doc = document;
  const edoc = (el && el.ownerDocument) || doc;
  await sleep(400);
  if (location.href !== href || document !== doc) return true;
  if (edoc !== doc) {
    try {
      const f = edoc.defaultView && edoc.defaultView.frameElement;
      // Slot moved on (navigation) or the frame is gone entirely — and if
      // reading it throws, it went somewhere this realm can't follow,
      // which is navigation too. Anything beats reporting ignored and
      // re-clicking a page that's no longer there.
      if (!f || f.contentDocument !== edoc) return true;
    } catch (e) { return true; }
  }
  return false;
}

function withSnap(out, args) {
  if (args.withSnapshot) out.snapshot = takeSnapshot({}).snapshot;
  return out;
}

async function act(verb, query, args) {
  args = args || {};
  try {
    const checkGuard = () => {
      if (args.guardCheck && !args.guardCheck()) {
        const error = new Error('The action changed. Review it again before continuing.');
        error.code = 'GUARD_CHANGED';
        throw error;
      }
    };
    checkGuard();
    switch (verb) {
      case 'click': {
        const el = resolve(query);
        const a = await actionable(el);
        if (a.error) return Object.assign({ version }, a);
        checkGuard();
        if (args.tier === 'event') {
          // The trusted tier is Swift's to send — actionability and the
          // coordinates it lands at are ours.
          return { ok: true, version, navChanged: false, handoff: 'event', at: a.at, button: args.button || 'left', double: !!args.double, modifiers: args.modifiers || [] };
        }
        // A handler can succeed without changing the DOM. Never retry a
        // dispatched click based on its visible effects.
        clickGesture(el, a.x, a.y, args);
        const navChanged = await waitNav(el);
        const out = { ok: true, version, navChanged, tier: 'js', at: a.at };
        return withSnap(out, args);
      }
      case 'clickAt': {
        const [x, y] = pointArg(args.x !== undefined ? [args.x, args.y] : args.at);
        if (!document.elementFromPoint) return { error: 'no elementFromPoint here', code: 'NOT_FOUND', version };
        const el = document.elementFromPoint(x, y);
        if (!el) return { error: 'nothing at ' + x + ',' + y, code: 'NOT_FOUND', version };
        clickGesture(el, x, y, args);
        const navChanged = await waitNav(el);
        // x,y are already top-document points — that's the caller's space.
        return withSnap({ ok: true, version, navChanged, tier: 'js', at: [x, y], element: describeEl(el) }, args);
      }
      case 'fill': {
        const el = resolve(query);
        if (el.tagName === 'INPUT' && /^(checkbox|radio)$/i.test(el.getAttribute('type') || ''))
          return { error: 'use check for ' + (el.getAttribute('type') || 'this') + ' inputs', code: 'WRONG_VERB', version };
        if (el.tagName === 'SELECT')
          return { error: 'use select for a <select>', code: 'WRONG_VERB', version };
        const a = await actionable(el);
        if (a.error) return Object.assign({ version }, a);
        checkGuard();
        try { el.focus && el.focus(); } catch (e) {}
        const value = args.text !== undefined ? String(args.text) : '';
        if (el.isContentEditable || (el.hasAttribute('contenteditable') && el.getAttribute('contenteditable') !== 'false')) {
          // Prefer the editing path so beforeinput and friends see a real
          // insertion; where execCommand doesn't exist, set + input event.
          let done = false;
          try {
            const d = el.ownerDocument;
            const sel = d.defaultView && d.defaultView.getSelection && d.defaultView.getSelection();
            if (sel && d.createRange) { const rg = d.createRange(); rg.selectNodeContents(el); sel.removeAllRanges(); sel.addRange(rg); }
            done = !!(d.execCommand && d.execCommand('insertText', false, value));
          } catch (e) { done = false; }
          if (!done) {
            el.textContent = value;
            emit(el, 'input', { bubbles: true, data: value, inputType: 'insertText' });
          }
        } else {
          // The field's own setter, then the events a keystroke would have
          // fired — the password filler's trick, so frameworks that
          // decorated the setter and frameworks that listen for input both
          // see it.
          const proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          const desc = proto && Object.getOwnPropertyDescriptor(proto, 'value');
          if (desc && desc.set) desc.set.call(el, value); else el.value = value;
          emit(el, 'input', { bubbles: true, inputType: 'insertText', data: value });
          emit(el, 'change', { bubbles: true });
        }
        return withSnap({ ok: true, version, navChanged: false }, args);
      }
      case 'press': {
        const km = keymap(args.key);
        if (!km) return { error: 'no keymap for ' + args.key, code: 'NOT_FOUND', version };
        const el = query ? resolve(query) : (document.activeElement || document.body);
        const init = modInit(args.modifiers);
        const keyev = (type) => {
          const e = new window.KeyboardEvent(type, Object.assign({ key: km.key, code: km.code, bubbles: true, cancelable: true, composed: true }, init));
          // keyCode/which aren't in KeyboardEventInit anymore; the pages
          // that still read them get them anyway.
          try { Object.defineProperty(e, 'keyCode', { value: km.keyCode }); Object.defineProperty(e, 'which', { value: km.keyCode }); } catch (x) {}
          return e;
        };
        const kd = keyev('keydown');
        el.dispatchEvent(kd);
        // keypress is for keys that produce text — Enter counts ('\r');
        // Tab, Escape, the arrows and friends don't get one.
        if (!kd.defaultPrevented && km.chars) {
          el.dispatchEvent(keyev('keypress'));
          // JS synthesis can raise the events but not the insertion — text
          // that must land in a field is the native tier's job, or fill's.
          emit(el, 'input', { bubbles: true, data: km.chars, inputType: 'insertText' });
        }
        el.dispatchEvent(keyev('keyup'));
        const navChanged = km.key === 'Enter' || km.key === '\r' ? await waitNav(el) : false;
        return withSnap({ ok: true, version, navChanged }, args);
      }
      case 'scroll': {
        if (args.toText) {
          const el = resolve({ text: args.toText });
          try { if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
          const r = rect(el);
          return withSnap({ ok: true, version, navChanged: false, at: topPoint(el, r.left + r.w / 2, r.top + r.h / 2) }, args);
        }
        const dx = +args.dx || 0, dy = +args.dy || 0;
        if (query === 'page' || query == null || query.page) {
          try { window.scrollBy(dx, dy); } catch (e) { window.scrollTo((window.scrollX || 0) + dx, (window.scrollY || 0) + dy); }
          return withSnap({ ok: true, version, navChanged: false, scroll: [window.scrollX || 0, window.scrollY || 0] }, args);
        }
        const el = resolve(query);
        try { if (el.scrollBy) el.scrollBy({ left: dx, top: dy }); else { el.scrollLeft += dx; el.scrollTop += dy; } }
        catch (e) { el.scrollLeft += dx; el.scrollTop += dy; }
        return withSnap({ ok: true, version, navChanged: false, scroll: [el.scrollLeft, el.scrollTop] }, args);
      }
      case 'hover': {
        const el = resolve(query);
        const a = await actionable(el);
        if (a.error) return Object.assign({ version }, a);
        checkGuard();
        const o = { button: 0, buttons: 0, detail: 0, modifiers: args.modifiers };
        fireMouse(el, 'pointerover', a.x, a.y, o); fireMouse(el, 'mouseover', a.x, a.y, o); fireMouse(el, 'mousemove', a.x, a.y, o);
        // enter/leave don't bubble — they're separate events, not phases.
        const no = Object.assign({ bubbles: false }, o);
        fireMouse(el, 'pointerenter', a.x, a.y, no); fireMouse(el, 'mouseenter', a.x, a.y, no);
        return withSnap({ ok: true, version, navChanged: false, at: a.at }, args);
      }
      case 'select': {
        const el = resolve(query);
        if (el.tagName !== 'SELECT') return { error: 'select needs a <select>, got ' + describeEl(el), code: 'WRONG_VERB', version };
        const want = (args.values || []).map(String);
        const picked = [];
        for (const o of el.options || []) {
          const on = want.indexOf(o.value) !== -1 || want.indexOf(collapse(o.textContent)) !== -1;
          o.selected = on;
          if (on) picked.push(o.value);
        }
        emit(el, 'input', { bubbles: true });
        emit(el, 'change', { bubbles: true });
        return withSnap({ ok: true, version, navChanged: false, selected: picked }, args);
      }
      case 'check': {
        const el = resolve(query);
        const on = args.on !== false;
        if (el.checked === on) return withSnap({ ok: true, version, navChanged: false, checked: el.checked }, args);
        const a = await actionable(el);
        if (a.error) return Object.assign({ version }, a);
        checkGuard();
        // The real toggle, so handlers and indeterminate states agree —
        // with a manual flip behind it for realms whose click() can't
        // build its own activation event.
        try { el.click(); }
        catch (e) { el.checked = on; emit(el, 'input', { bubbles: true }); emit(el, 'change', { bubbles: true }); }
        return withSnap({ ok: true, version, navChanged: false, checked: el.checked }, args);
      }
      case 'submit': {
        const el = resolve(query);
        const form = el.tagName === 'FORM' ? el : (el.form || (el.closest && el.closest('form')));
        if (!form) return { error: 'no form around ' + describeEl(el), code: 'NOT_FOUND', version };
        try { if (form.requestSubmit) form.requestSubmit(); else form.submit(); } catch (e) { try { form.submit(); } catch (e2) {} }
        const navChanged = await waitNav(el);
        return withSnap({ ok: true, version, navChanged }, args);
      }
      case 'type':
        return { error: 'type is the native tier — press per key or fill atomically', code: 'UNSUPPORTED', version };
      default:
        return { error: 'unknown verb ' + verb, code: 'UNSUPPORTED', version };
    }
  } catch (e) {
    if (e && e.code) return { error: e.message || String(e), code: e.code, version };
    return { error: String((e && e.message) || e), code: 'ERROR', version };
  }
}

// ---------------------------------------------------------------- marks

// Set-of-marks for screenshots: a fixed overlay at the top of the stack,
// one outlined box per interactive element with its ref as a chip. Colours
// follow role families so a dense page still reads. Positions are viewport
// coordinates — the overlay is `fixed` and the shot happens immediately
// after, before anything can scroll.
const MARK_COLORS = {
  link: '#1a73e8', button: '#9334e6', iframe: '#5f6368',
  textbox: '#188038', checkbox: '#188038', radio: '#188038', combobox: '#188038',
  listbox: '#188038', slider: '#188038', spinbutton: '#188038', searchbox: '#188038',
  option: '#188038', switch: '#188038', tab: '#9334e6', menuitem: '#9334e6',
  menuitemcheckbox: '#9334e6', menuitemradio: '#9334e6',
};
const markColor = (role) => MARK_COLORS[role] || '#e8710a';

function unmark() {
  const old = document.getElementById('__drive-marks');
  if (old) old.remove();
}

function mark() {
  unmark();
  const overlay = document.createElement('div');
  overlay.id = '__drive-marks';
  overlay.setAttribute('style', 'position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483646;pointer-events:none;margin:0;padding:0;border:0;background:none;');
  (document.documentElement || document.body).appendChild(overlay);
  const vw = window.innerWidth || 1024, vh = window.innerHeight || 768;
  let n = 0;

  function paint(el, ax, ay, r) {
    const color = markColor(roleOf(el) || 'generic');
    const o = document.createElement('div');
    o.style.cssText = 'position:absolute;left:' + Math.round(ax) + 'px;top:' + Math.round(ay) + 'px;width:' + Math.round(r.w) + 'px;height:' + Math.round(r.h) + 'px;outline:2px solid ' + color + ';box-shadow:inset 0 0 0 1px rgba(255,255,255,.5);border-radius:2px;';
    const chip = document.createElement('div');
    chip.style.cssText = 'position:absolute;left:-2px;top:-16px;height:14px;font:600 10px/14px Menlo,monospace;color:#fff;background:' + color + ';padding:0 3px;border-radius:2px;white-space:nowrap;';
    chip.textContent = el.__driveRef ? el.__driveRef.ref : '';
    o.appendChild(chip);
    overlay.appendChild(o);
    n++;
  }

  // clipR bounds what gets painted — the top viewport at the root, the
  // frame's own rect inside a frame. Geometry comes straight from each
  // element's rect plus the offsets accrued walking down through frames.
  function walk(root, offX, offY, clipR) {
    for (const el of children(root)) {
      const tag = el.tagName;
      if (!tag || SKIP_TAGS.has(tag)) continue;
      if (el.namespaceURI && el.namespaceURI.indexOf('svg') !== -1) continue;
      if (overlay.contains(el) || el === overlay) continue;
      const st = style(el);
      if (st && st.display === 'none') continue;
      const role = roleOf(el);
      if (role === null) continue;
      const r = rect(el);
      if (isInteractive(el, role, st) && r.w > 0 && r.h > 0) {
        const ax = r.x + offX, ay = r.y + offY;
        if (ax + r.w > clipR.x && ay + r.h > clipR.y && ax < clipR.x + clipR.w && ay < clipR.y + clipR.h) {
          ensureRef(el, role, nameOf(el, role), docPrefix(el.ownerDocument));
          paint(el, ax, ay, r);
        }
      }
      if (tag === 'IFRAME' || tag === 'FRAME') {
        try {
          const d = el.contentDocument;
          if (d && d.documentElement) walk(d.body || d.documentElement, offX + r.x, offY + r.y, { x: offX + r.x, y: offY + r.y, w: r.w, h: r.h });
        } catch (e) {}
        continue;
      }
      walk(el, offX, offY, clipR);
    }
  }
  walk(document.body || document.documentElement, 0, 0, { x: 0, y: 0, w: vw, h: vh });
  return { marks: n };
}

// ---------------------------------------------------------------- run/eval

// What JSON can carry, and no more — an Element answers as its short name,
// a function as its name, cycles and depth give up politely.
function safe(v, depth, seen) {
  if (v === null || v === undefined) return v === undefined ? null : v;
  const t = typeof v;
  if (t === 'boolean' || t === 'number' || t === 'string') return v;
  if (t === 'bigint') return String(v);
  if (t === 'function') return '[function ' + (v.name || 'anonymous') + ']';
  // instanceof misses elements from another realm (iframes); nodeType is
  // the cross-realm truth.
  if (v instanceof Element || (v && v.nodeType === 1 && v.tagName)) return describeEl(v);
  depth = depth || 0; seen = seen || [];
  if (depth > 6) return '…';
  if (seen.indexOf(v) !== -1) return '[circular]';
  seen.push(v);
  try {
    if (Array.isArray(v)) return v.map((x) => safe(x, depth + 1, seen));
    const o = {};
    for (const k of Object.keys(v).slice(0, 100)) o[k] = safe(v[k], depth + 1, seen);
    return o;
  } finally { seen.pop(); }
}

async function run(code) {
  const before = consoleLines.length;
  try {
    const v = await (new Function('drive', 'return (async () => {\n' + String(code) + '\n})()'))(api);
    return { value: safe(v), consoleLines: consoleLines.length - before };
  } catch (e) {
    return { error: String((e && e.message) || e), consoleLines: consoleLines.length - before };
  }
}

// ---------------------------------------------------------------- console

// Tapped at load rather than on first use: a console line that happened
// before the agent asked is often the one that explains the page. Kept to
// the last 200 because a chatty page would otherwise fill memory with
// noise.
function pushConsole(level, args) {
  let s;
  try {
    s = Array.prototype.map.call(args, (a) => {
      if (typeof a === 'string') return a;
      if (a instanceof Error) return a.message;
      try { return JSON.stringify(a); } catch (e) { return String(a); }
    }).join(' ');
  } catch (e) { s = '(unprintable)'; }
  consoleLines.push({ level, text: clip(s, 2000), when: Date.now() });
  if (consoleLines.length > 200) consoleLines.splice(0, consoleLines.length - 200);
}
for (const lvl of ['log', 'info', 'warn', 'error', 'debug']) {
  const orig = window.console[lvl];
  window.console[lvl] = function () {
    try { pushConsole(lvl, arguments); } catch (e) {}
    return orig && orig.apply ? orig.apply(this, arguments) : undefined;
  };
}
// `window` is a proxy in some eval contexts and only a real EventTarget
// takes listeners; fall back to the bare binding when the proxy refuses.
function onWindow(type, fn) {
  try { window.addEventListener(type, fn); }
  catch (e) { try { addEventListener(type, fn); } catch (e2) {} }
}
onWindow('error', (e) => pushConsole('error', [e.message || 'error']));
onWindow('unhandledrejection', (e) => pushConsole('error', ['unhandledrejection: ' + String((e.reason && e.reason.message) || e.reason)]));

// ---------------------------------------------------------------- frames

function frames() {
  const out = [];
  for (const f of document.querySelectorAll('iframe,frame')) {
    const name = nameOf(f, 'iframe') || f.getAttribute('title') || '';
    const ref = ensureRef(f, 'iframe', name, docPrefix(document));
    let url = '', same = false;
    try { url = f.contentDocument.location.href; same = true; } catch (e) { url = f.src || f.getAttribute('src') || ''; }
    out.push({ ref, url, sameOrigin: same });
  }
  return out;
}

// ---------------------------------------------------------------- keymap

// "Enter" -> everything both tiers need: the DOM view (code, keyCode,
// chars) and the macOS view (`mac` is the virtual keycode an NSEvent
// wants, null where a US layout has no single answer).
const MAC_LETTERS = { a: 0, s: 1, d: 2, f: 3, h: 4, g: 5, z: 6, x: 7, c: 8, v: 9, b: 11, q: 12, w: 13, e: 14, r: 15, y: 16, t: 17, o: 31, u: 32, i: 34, p: 35, l: 37, j: 38, k: 40, n: 45, m: 46 };
const MAC_DIGITS = { 1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25, 0: 29 };
const NAMED_KEYS = {
  Enter: { code: 'Enter', keyCode: 13, chars: '\r', mac: 36 },
  Tab: { code: 'Tab', keyCode: 9, chars: '\t', mac: 48 },
  Escape: { code: 'Escape', keyCode: 27, chars: '', mac: 53 },
  Backspace: { code: 'Backspace', keyCode: 8, chars: '', mac: 51 },
  Delete: { code: 'Delete', keyCode: 46, chars: '', mac: 117 },
  ' ': { code: 'Space', keyCode: 32, chars: ' ', mac: 49 },
  ArrowLeft: { code: 'ArrowLeft', keyCode: 37, chars: '', mac: 123 },
  ArrowRight: { code: 'ArrowRight', keyCode: 39, chars: '', mac: 124 },
  ArrowUp: { code: 'ArrowUp', keyCode: 38, chars: '', mac: 126 },
  ArrowDown: { code: 'ArrowDown', keyCode: 40, chars: '', mac: 125 },
  Home: { code: 'Home', keyCode: 36, chars: '', mac: 115 },
  End: { code: 'End', keyCode: 35, chars: '', mac: 119 },
  PageUp: { code: 'PageUp', keyCode: 33, chars: '', mac: 116 },
  PageDown: { code: 'PageDown', keyCode: 34, chars: '', mac: 121 },
};
'F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12'.split(' ').forEach((k, i) => {
  NAMED_KEYS[k] = { code: k, keyCode: 112 + i, chars: '', mac: [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111][i] };
});
const KEY_ALIASES = { Return: 'Enter', Esc: 'Escape', Space: ' ', Spacebar: ' ', Left: 'ArrowLeft', Right: 'ArrowRight', Up: 'ArrowUp', Down: 'ArrowDown', Del: 'Delete' };
const PUNCT = { ';': 186, '=': 187, ',': 188, '-': 189, '.': 190, '/': 191, '`': 192, '[': 219, '\\': 220, ']': 221, "'": 222 };

function keymap(key) {
  if (key === undefined || key === null) return null;
  let k = String(key);
  if (KEY_ALIASES[k]) k = KEY_ALIASES[k];
  if (NAMED_KEYS[k]) return Object.assign({ key: k }, NAMED_KEYS[k]);
  if (k.length === 1) {
    const lc = k.toLowerCase();
    if (/[a-z]/.test(lc)) return { key: k, code: 'Key' + lc.toUpperCase(), keyCode: lc.toUpperCase().charCodeAt(0), chars: k, mac: MAC_LETTERS[lc] };
    if (/[0-9]/.test(k)) return { key: k, code: 'Digit' + k, keyCode: k.charCodeAt(0), chars: k, mac: MAC_DIGITS[k] };
    return { key: k, code: k, keyCode: PUNCT[k] || k.charCodeAt(0), chars: k, mac: null };
  }
  return null;
}

// ---------------------------------------------------------------- install

const api = {
  v: BUILD,
  get version() { return version; },
  refs,
  snapshot: takeSnapshot,
  resolve,
  act,
  mark,
  unmark,
  run,
  console: consoleLines,
  frames,
  keymap,
  stale(ref) {
    const wr = refs.get(String(ref));
    const el = wr && wr.deref ? wr.deref() : null;
    return !el || !el.isConnected || !el.__driveRef || el.__driveRef.ref !== String(ref);
  },
  // for the ops layer's diagnostics, and for run() users poking around
  _describe: describeEl,
};

try { Object.defineProperty(window, '__drive', { value: api, configurable: true, writable: true }); }
catch (e) { window.__drive = api; }

// The load itself is a version boundary — a snapshot taken before this
// eval belongs to another document entirely. A DOMContentLoaded arriving
// while we were still loading counts the same way: the tree just changed
// under us.
bumpVersion();
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => bumpVersion(), { once: true });
}
})();
