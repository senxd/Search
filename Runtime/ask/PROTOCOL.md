# Ask / Drive protocol

For engine inspection, native dialogs/uploads, tab handoff, and request receipts,
see [Browser automation and inspection](INSPECTION.md).

The ops layer `Drive` (Sources/Search/Drive.swift) speaks one op set over two
doors: the in-app harness's `webkit.messageHandlers.searchHarness` bridge, and
persistent JSON-lines sessions on `~/Library/Application Support/Search[ (world)]/agent.sock`.

Every call is `{"id": N, "op": "…", "args": {…}}` → `{"id": N, "result": {…}}`
or `{"id": N, "error": "…"}`. Between answers the session may emit
`{"event": "…", "data": {…}}`. The in-app bridge uses the same shapes through
`postMessage`. `args` must be JSON-safe — a non-finite number (`-1e999`,
`NaN`) or a non-JSON value earns `{"error": "args aren't JSON-safe…"}`, never
a crash; the same goes for a reply's `id`.

Tab ids are the first 8 lowercase hex chars of the tab's UUID (same as
`./bench` prints). Ops that name a tab take `"tab"`.

Sessions are isolated: each agent.sock connection is one session, and the
in-app harness is one logical session (`.app`). Attaches, opened tabs,
leases and pending-op counts belong to the session that made them — a second
client can't drive a tab the first attached, and disconnecting a session
closes the tabs it opened and releases its leases and attaches.

## Modes and the gate

Each session carries a **mode**: `guard` (shown as Confirm) or `full`
(design/permissions.md) — and `Drive.serve` gates every op through it
between the args check and dispatch. Ops are classified `meta < read <
write < destructive < privileged`:

- `guard` resolves the action target and applies the category switches in
  Settings > Ask > Action confirmations. Signing in defaults off; destructive
  actions, messages, sharing, payments, account changes and unverified actions
  default on. Any enabled matching category requests approval.
- `full` allows everything the door permits. Origin restrictions still apply.

Socket sessions default to `full`. A socket action needing approval returns
`NEEDS_UI`, because socket sessions have no approval UI. The in-app mode belongs
to the running chat; the model cannot change it with `agent.mode`.

An approval parks the tool and the agent loop. The card shows the action,
site, category, prepared details and a screenshot. Credential pages omit the
screenshot. Allow executes once; Cancel returns `GUARD_CANCELLED` and stops the
remaining tool batch. Legacy `always` verdicts also allow once.

Approval binds to the resolved node, document, action arguments, form values and
surrounding page context. Changed evidence requires fresh approval. Inspection
errors block execution. Classification uses DOM heuristics; unknown actions
fall into Unverified actions. Disabling a category removes that category's
confirmation requirement.

The browser driver runs in an isolated WebKit content world. Page scripts cannot
replace it. `page.code` intentionally runs in the page world; its driver refs
have a `code-` prefix. Refs are local to their world: use CSS/locators across
worlds, or obtain refs inside the same `page.code` call that uses them.

Downloads from tabs a session holds are gated by the holder's mode but
never asked: anything but `full` is cancelled outright — the file is
already moving when the download lands and there is no parked `finish` a
card could settle.

Mutating ops accept an optional `why: "…"` — the model's one-line reason,
shown on the card. The gate reads it and strips it before dispatch; it
never reaches the page.

`ask.user` (the `ask_user` tool) is the one tool that isn't an op here —
Harness intercepts it on the bridge and parks it on a question card;
results are `{answer:"…"}` or `{declined:"dismissed"|"timeout"|"busy"|"unavailable"}`.

## Ops

### tabs

- `tabs.list` → `{tabs:[{id,url,title,name,group,loading,bench,active,asleep}]}` — every tab, user and agent. Metadata only: listing never wakes a sleeping tab and never reads page content.
- `tabs.open {url, foreground?, fresh?}` → `{id}` — opens an **agent tab** (the bench kind: ⚗, signed in as the user, out of history/session, offscreen when not selected). `foreground` selects it (allowed — the agent asked for the user's attention deliberately). `fresh:true` opens it signed in as **nobody** — a nonPersistent store, no extensions, no history (`Tab(shy:)`).
- `tabs.attach {id}` → `{id,attached:true}` — give the session read+drive rights over a tab. Agent/bench tabs attach freely. A **user tab** must be consented first: the composer's @ chips are the consent, and they arrive only through `tabs.grant` — Drive records the tab in its `grantedTabs` registry. A socket session may then attach that tab by name — but the wire can't grant one: `granted:true` on `tabs.attach` is refused on every door (`granted isn't an attach argument — grants come through the grant door`), and attaching an unconsented user tab fails `… needs its chip in Ask — the wire can't grant it` (the in-app door's own wording is `… needs its chip in Ask — consent isn't an attach argument`).
- `tabs.grant {id}` → `{id,attached:true}` — **in-app only; the socket is refused** (`tabs.grant is the in-app door — the wire can't grant a tab`). The chip's own op: writes the `grantedTabs` consent registry and attaches the tab to the app's session in one step. The harness reaches it through `{kind:"grant"}`, a bridge message the model's `tool` calls can never produce — `granted` is stripped from tool args and `tabs.grant` named as a tool is refused. Consent lasts the chat that made it: a new or removed chat clears every grant.
- `tabs.ungrantAll` → `{ungranted: N}` — **in-app only; the socket is refused** (`tabs.ungrantAll is the in-app door — the wire can't end a grant`). Ends every chip's consent at once: `grantedTabs` empties and each session's attach — and any lease, announced as `lease.lost` — on a granted user tab lets go. Tabs a session opened and agent tabs stay held; they were never the registry's. Mind calls it when a chat starts fresh or is deleted.
- `tabs.detach {id}` — release *this session's* hold: its attach and its leases on the tab end; every other session keeps its own. The consent in `grantedTabs` lapses when the last session holding the tab lets go (also on the tab closing, the chat ending — `tabs.ungrantAll` — and with the app) — one session's detach can't burn the chip's grant or detach a tab out from under another session.
- `tabs.close {id}` — agent/bench tabs only (same rule as `bench close`).
- `tabs.select {id}` — bring a tab to the front. On the real browser allowed only for tabs this session opened or attached.

Settings > Ask has independent switches for agent tab switching and page highlights, both on by default. They apply to Ask, routines, and socket/MCP agents. Disabled actions return `ATTENTION_DISABLED`. Tab switching covers `tabs.select`, `tabs.open` with `foreground:true`, and `tabs.surface` with its default `foreground:true`. The latter two must use `foreground:false` for background work when switching is disabled. Disabled foreground requests fail before creating or keeping a tab. Agents must respect these settings rather than simulate attention through JavaScript.

### page

- `page.go {tab,url}` → `{id,url}` — navigate; the URL is normalized like `bench open` (Address.url).
- `page.back|page.forward|page.reload {tab}` → `{id}`
- `page.wait {tab, seconds?}` → `{id,url,title,loading:false,timeout?}` — polls like `bench wait`.
- `page.text {tab}` → `{text,truncated,url,title}` — `document.body.innerText`, 120k cap.
- `page.highlight {tab, ref?|loc?|css?|text?, duration?:number, scroll?:bool}` → `{highlighted:true,duration,target}`. Exactly one nonempty target is required. The outline follows the element, allows clicks through, and expires after 8 seconds by default, bounded to 1..30 seconds. `scroll` defaults to true; the tab is never selected implicitly. Escape, `page.clearHighlight`, detach, consent revocation, session/run completion, navigation, or disabling highlights removes it. One outline per page; another session gets `BUSY` while it is in use.
- `page.clearHighlight {tab}` → `{cleared:bool}`. Removes only this session's outline, including when highlights are disabled. Both highlight operations require an owned or attached tab and are write-class operations.
- `page.snapshot {tab, scope?:"full"|"viewport", boxes?:bool, textColors?:bool, maxChars?:int, cssLocators?:bool}` →
  `{snapshot, version, url, title, truncated}` — the semantic tree from
  `window.__drive.snapshot()` (Runtime/ask/drive.js): YAML-ish indented lines,
  interactive elements carry `[ref=eN]` and `loc=` handles, text lines unmarked.
  `boxes:true` adds `[box=x,y,w,h]`. `textColors:true` adds computed CSS `[color=…]` to direct rendered text, using solid fill for simple SVG text. This is opt-in and does not identify visibility or 3D depth. ARIA-only names, aggregate SVG labels and non-solid SVG fills receive no color annotation. Use a full snapshot for nested HTML text; interactive-only snapshots omit noninteractive text runs. `cssLocators:false` omits CSS paths while retaining refs and named role locators; the SDK default keeps CSS paths. Refs are opaque strings, remain stable across driver replacement, and die on navigation.
- `page.screenshot {tab, path?, width?, marks?:bool}` → `{path,width,height}` —
  PNG via `WKSnapshotConfiguration`; `marks` asks drive.js to draw index boxes
  onto the page before the shot and remove them after.
- `page.eval {tab, js}` → `{value}` — raw evaluateJavaScript, result JSON-safe
  (`Bench.plain`). The escape hatch; privileged.
- `page.code {tab, js}` → `{value}` — like eval but the script runs with
  `__drive` in scope guaranteed installed; for multi-step agent programs
  (ego-lite's heredoc model — prefer this over many tiny calls).
- `page.console {tab}` → `{messages:[{level,text,when}]}` — recent console
  lines collected by drive.js. The tap is part of the standard `__drive`
  preamble, so it begins collecting at the tab's first page op — anything
  the page logged before that is gone.
- `page.frames {tab}` → `{frames:[{ref,url,sameOrigin}]}`.

A commit mid-call settles whatever the page still owed: an `act.*` action
answers `{ok:true, navChanged:true}` — the action may well be what
navigated — while anything else (`snapshot`, `console`, `frames`,
`page.code`, …) answers `{error:"navigated mid-call", code:"NAVIGATED"}`
because a call torn down before it returned produced nothing.

### actions

All take `{tab, ref?|loc?|css?|text?…}`. Resolution order in drive.js:
`ref` → `loc` (`css:`/`role:`/`href:`/`xpath:`) → `css` → `text=…`. A stale ref
returns `{error:"stale ref e3 — take a new snapshot", code:"STALE_REF"}`.
Mutating actions return `{ok:true, version, navChanged}` and accept
`withSnapshot:true` to include a fresh `{snapshot, snapshotTruncated, snapshotVersion}`. Optional `snapshotMaxChars` bounds that snapshot, and `cssLocators:false` omits its CSS paths. Both options retain the SDK default when omitted.

- `act.click {…, button?:"left"|"middle"|"right", double?:bool, modifiers?:["cmd","shift","ctrl","opt"], tier?:"auto"|"js"|"event"}`
- `act.fill {…, text}` — atomic set via the element's own setter + input/change (React-aware; contenteditable too).
- `act.type {…, text, delay?}` — real per-character key events (NSEvent tier). Each character is paced — `delay` ms between keys, with a 16ms floor, because a burst inside one run-loop turn loses keys to WebKit's input handling.
- `act.press {tab, key, modifiers?}` supports named keys such as `Enter`, `ArrowDown`, or `a`, and chords such as `cmd+a`. Search runs on macOS, so editing shortcuts use `cmd`. Modifier names and aliases are case-insensitive; unsupported keys or modifiers return `INVALID_ARGUMENT` without dispatching input. NSEvent tier.
- `act.hover {…}` — hover events without clicking. Use a locator, or top-document CSS viewport `x,y` coordinates. Coordinates must be finite and in bounds; do not combine them with a locator. `withSnapshot:true` returns updated visible feedback.
- `act.scroll {tab, ref?|"page", dx?, dy?, toText?}` 
- `act.select {…, values[]}` — `<select>` options.
- `act.check {…, on:bool}` — checkbox/radio.
- `act.submit {…}` — `requestSubmit()`.
- `act.clickAt {tab,x,y}` — coordinate tier, for canvas/SVG.
- `act.drag {tab, source, to, steps?:1..64, path?:[[x,y],…], holdMs?:0..2000}` — native mouse-down, paced movement, optional stationary hold, then mouse-up. Coordinates are CSS viewport pixels; `path` accepts at most 128 intermediate points, paced at least 8ms apart. `holdMs` is an integer duration in milliseconds, default 0, measured from the final movement with a monotonic clock. The asynchronous hold sends no extra movement events, checks cancellation, dialogs and tab ownership, and releases the mouse on interruption. It can reduce momentum; verify page feedback after release. `steps` applies only when `path` is absent.

Trusted tier ("event") = real `NSEvent`s delivered to the view in the
offscreen room window (Bench `tap`/`key` machinery) — isTrusted, no focus
theft. "auto" uses one native event after actionability checks. Covered elements
are refused. `tier:"js"` explicitly selects synthetic input; a dispatched click
is never retried based on missing DOM changes.

### window / meta

- `agent.tabs` → agent tabs only.
- `agent.probe` → window/panel state (Bench `probe` fields the agent needs: active tab id, open panels) plus `spacesOn`, `space` (the current space's name) and `spaces` (all their names).
- `agent.lease {tab, on}` — foreground-action lease: while held, the user's own input on that tab releases it and emits `event:"lease.lost"`.
- `agent.mode {to?:"guard"|"full"}` → `{mode}` — sets this socket session's own leash (see "Modes and the gate"); with no `to`, just answers the current one. Refused for the in-app session — the app's mode is its chat's, so the model can't lift its own leash. `subscribe {events, mode}` takes the same arg at sign-on.
- `ui.ask {open?, new?, send?, steer?, stop?}` → `{open: bool}` — open/close the Ask rail (socket only; used by tests). `new:true` starts a fresh chat (`Mind.newChat` — the chips' grants end with the old one) and answers `newChat:true`. `send:"text"` additionally posts the text as the user's own message to the in-app agent — `Mind.send`, the composer's return key — starting a real turn behind whatever the rail shows; the answer then carries `{open, ok:true, chat:<uuid>}` (blank text earns `{open, error:"ui.ask send needs a non-empty text"}` instead). `steer:"text"` is the follow-up box's equivalent — `Mind.steer`, which sends when no chat is open — and `stop:true` ends the running turn (`Mind.stop`); both answer `{open, ok:true}` (+ `chat` when the steer fell back to send). `open` and `send` may ride in one call — open the rail and send into it. In `guard` mode `send`/`steer`/`new` are privileged-class — posting text as the user into the agent that holds the grants, or wiping its consent registry outright — and a socket gets `NEEDS_UI`.

  What `send` hands the in-app agent is the job `{chat, tabs, attachments, text}` over the `searchHarness` bridge (`Harness.run` → `__h.run`). `chat` is the whole chat — messages and the chat-scoped settings the turn reads: `chat.model` picks the wire, `chat.turn` stamps the turn's events, and `chat.effort` (absent = auto, the provider's own default) becomes `reasoning:{effort:…}` on the wires that take one — openrouter and codex — mapped per model. Codex `gpt-6-luna` takes `none`, `low`, `medium`, `high`, `xhigh`, `max` (`off` sends `none`; a stored `minimal` sends `low`, since luna rejects `minimal`). OpenRouter `z-ai/glm-5.3-flash` takes only `low`, `high`, and `max` (`off` / `none` / `minimal` send `low`, `medium` sends `high`, `xhigh` sends `max`). Any other OpenRouter model is sent OpenRouter's ladder (`off` → `none`; `minimal` through `max` unchanged). Other Codex models use luna's ladder. Devin and echo ignore the field. `attachments` is the composer's typed pieces — `[{kind:"image"|"file"|"site", label, path?, url?, mime?, text?, data?}]`, filled at send (`AskAttach.filled`: a file's UTF-8 text under the cap, an image's base64 bytes under its own, else just the path/url). They are payloads, not grants: a `site` becomes a `[site: <url> — <label>]` reference line and never resolves to a tab; a `file` with `text` becomes a `[file: <label>]` fenced block, without it `[file: <label> at <path> — contents not attached]`; an `image` with `data` rides as a real image part on wires that take them (openrouter's `image_url` parts, codex's `input_image`) and degrades to `[image: <label> at <path>]` on devin/echo. All of it lands ahead of the user text in the same turn — and a `.you` message persists its pieces as `message.attachments`, replayed the same way when the chat's history feeds a later turn. (`tabs` stays the consent chips — the renamed field that "attachments" used to carry on messages.)

### events (server → session)

Delivered to sessions that `subscribe`d — `{"events":["*"]}` or a name list —
from the moment they subscribe, not the first op after.

- `tab.navigated {id,url,title}`, `tab.closed {id}`, `tab.added {id}`, `tab.title {id,title}` — **broadcast**: every subscribed session watches the same row of agent and attached tabs, so a tab one session holds is news for all of them.
- `lease.lost {id}` — the user took the tab back. Scoped: only the session that held the lease hears it.
- `done` — the session's own pending count reached zero. Scoped likewise.

## Refs (drive.js contract)

`window.__drive` holds: `version` (bumps on navigation + each snapshot),
`refs` (ref → WeakRef), `snapshot(opts)`, `resolve(query)` → Element,
`act(verb, query, args)` → result object, `mark()/unmark()`, `run(code)`.
Refs persist on elements (`el.__driveRef = {ref,role,name}`) so unchanged
elements keep refs across snapshots — playwright's scheme.
