# Ask sidebar — the 10/10 feature set

What the rail has, what it gets wrong, and everything the finished panel
does. State lives in `Mind` (Sources/Search/Mind.swift); drawing lives in
`AskUI.swift`; the agent loop is `Runtime/ask/harness.js` behind
`Harness` (Sources/Search/Harness.swift). The rebuild target is the Fluid
Functionalism port (`Sources/Search/Fluid*.swift`) wherever it covers the
need — mapped per feature below.

Anchor image: the dark rail with the user pill, the expanded
"Worked for 4m 39s" disclosure (intermediate paragraphs → tool-summary
lines → screenshot card, per intermediate step), the final answer as plain
text *below* it at the bottom of the scroll, and the composer
("Reply, @ for context", `+`, mic, "GPT-6 Sol · High" chip, round send).

## 1. Current-state audit

### What exists

- **`AskPanel`** (AskUI.swift:60): the floating card — `head` → `Rule` →
  `middle` → `composer`, rounded-16 `Palette.wash.opacity(0.55)` card,
  hairline, shadow, 8pt edge padding. Hosted at `App.swift:333` as a
  fixed-380pt trailing rail (`rail = mind.open && browser.prefs.ask`,
  App.swift:748); the page gives ground rather than being covered.
- **Header** (AskUI.swift:110-150): title button (opens the chat list,
  chevron up/down), `ModelSelector(short:)` — a *second* model menu in the
  header — then `Door(square.and.pencil)` new-chat and `Door(xmark)` close.
- **Chat list** (166-196): replaces the middle while `listing`; `Quiet`
  "New chat" row + `ChatRow`s. Row (1007-1068): title, `ago(chat.when)`,
  `⑂` when `chat.parent != nil`, `Ring` if `running && current`, checkmark
  if current; context menu: Copy Transcript / Fork / Delete.
- **Conversation** (221-272): `ScrollViewReader` + `ScrollView` +
  `LazyVStack(spacing: 14)` of `AskLine`s, then `ApprovalCard`s for
  `mind.pendingApprovals` on this chat, then a `Ring + mind.activity`
  "working…" line while `mind.running`, else a retry pill for the last
  `.you` (`retryable`, 214-217), then `Color.clear.id("end")`.
  `proxy.scrollTo("end")` on appear, `currentID` change, and every
  `messages` change.
- **`AskLine`** (747-924): `.you` → right-aligned bubble
  (`UnevenRoundedRectangle`, ink-8% fill, `.padding(.leading, 46)`),
  "· retried ×N" caption, and the sent tabs/attachments as a right-anchored
  scrolling chip row (874-889). `.agent` → **all of `text` first, then
  every `ToolRow`/`QuestionRow` after it** (895-914). `.note` → centered
  quiet line (916-923). Hover meta chip (800-821): `CopyChip` + `ago` +
  model tail when `mixed` (200-202). Context menu (823-842): Copy,
  Retry from here, Retry with…, Fork from here.
- **`ToolRow`** (928-1003): mono name + `args → result` one-liner,
  `Ring` while live-unanswered, checkmark when ended-unanswered, red on
  failure, hover `CopyChip` of `name args\n→ result`.
- **`QuestionRow`** (1217-1372): pending → card with question, option
  `Pill`s, answer field, Skip (`mind.answer`/`mind.pass`); settled →
  `ask_user "…" → "…"` one-liner; unanswered → "went unanswered".
- **`ApprovalCard`** (1145-1211): "Wants to \(summary)" in the gate's
  words + model `why` + lazy `shotPath` thumbnail + Allow /
  Always-verb·host / Deny `Pill`s → `mind.resolve`.
- **Composer** (320-395): `Card` holding chips row (context tabs +
  attachments + dashed `+tab` suggestion), `SiteRow` when raised, the
  `@`-attach list when open, then `AttachMenu` (+) / `TextField`
  ("Ask AI a task, @ for context", Return sends, ⇧Return newline) /
  send-stop button; footer status row: `ModelSelector`, `ReasonSelector`
  (gated on `canReason`), `ModeMenu`.
- **`@` parsing** (476-501): `@` at word boundary tails the draft into a
  query; `attachable` filters open tabs ≤6; `submit()` picks the first.
- **`Mind`** (Mind.swift:213-696): `open` (persisted `ask.open`), `chats`,
  `currentID`, `context`, `attachments`, `model`, `activity`,
  `pendingApprovals`, `question` + 300s `questionClock`; `send` (creates
  chat lazily, stamps `chat.model`/`chat.turn`, appends `.you`, runs
  engine), `steer` (mid-turn; answers an open question instead of queueing,
  350-354), `stop`, `newChat`, `select`, `remove`, `rename`, `hear`,
  `raise`/`resolve` (approvals + audit `.note`), `pose`/`answer`/`pass`
  (ask_user), `retry(from:with:)`, `fork(from:)`, `setMode`, `setEffort`.
- **Persistence**: `AskStore` → `chats/<id>.json`, sorted by `when` desc.
  `AskMessage` (29-83) and `AskChat` (88-136) both decode missing keys to
  defaults — the forgiving pattern new fields must follow.
- **Engine**: `AskEvent` = `.delta` / `.message` / `.tool` / `.activity` /
  `.done` (178-189), all chat-scoped and turn-stamped (Harness.swift:
  363-368 drops stale stamps). `hear(.delta)`/`.tool` append to *the last
  `.agent` message*, creating one if needed; `hear(.message)` replaces or
  appends (410-438). harness.js emits `delta` as text streams, `tool`
  cards per call via `cardSink` (harness.js:819-827), and **one `message`
  at turn end** carrying the concatenation of *all* steps' text plus *all*
  tool cards flattened (893-898).

### What's broken or missing (verified)

1. **The answer is not last.** `.agent` renders `text` above `tools`
   (AskUI.swift:895-914), and `hear`/harness flatten a turn into *one*
   message — all paragraphs concatenated into `text`, all calls into
   `tools`. The turn's intermediate text ↔ tool-call ordering is
   unrecoverable from `AskMessage` as stored; the final answer sits on top
   of a pile of tool cards instead of pinned at the bottom.
2. **No "Worked for X" grouping or duration.** No turn grouping, no
   accordion, and no field anywhere that could feed the duration.
3. **No per-step structure to accordion.** Even UI-side grouping can't be
   derived today: `AskMessage` has no ordered block model (see §4).
4. **Scroll behavior is naive.** `onChange(of: messages)` → unconditional
   `scrollTo("end")` (AskUI.swift:270) yanks to the bottom on *every* delta
   even when the user scrolled up to read; no at-bottom detection, no
   jump-to-latest affordance, no scrollbar (`showsIndicators: false`), no
   edge fades/dividers. Short conversations also sit at the *top* rather
   than resting at the bottom (no `defaultScrollAnchor`/top spacer).
5. **`mind.running` is global, not per-chat.** The "working…" line and
   live tool rows render in *whatever* chat is open while *any* turn runs
   (237-245, `live: mind.running` at 228). Worse: `Mind.steer`
   (Mind.swift:342-355) appends the `.you` to the *current* chat but calls
   `engine?.steer` which feeds the *running* chat's turn — type in chat B
   during chat A's turn and A reads words drawn in B. And `send` in B
   silently kills A's turn (harness.js:918 `if (current) kill(current)`;
   Harness.run:103-109).
6. **`done` leaks as a tool card.** `runCalls` cardSinks the `done` call
   too (harness.js:788-802), so a `done` ToolRow renders — loop machinery,
   not work.
7. **Chat list is thin.** Ordered by `chat.when` = *creation* date —
   `Mind.store`/`hear` never bump it, so an active old chat never bubbles
   up. No search/filter, no rename UI (`Mind.rename` exists unused), no
   badges for awaiting-question (`mind.question.chat`) or pending
   approvals (`pendingApprovals[].chat`), ring only for the current chat,
   no unread marker.
8. **Notes are one flavor.** Provider errors (`hear(.done error)` →
   `.note`, Mind.swift:451-453) draw identically to quiet audit lines
   ("✓ allowed…", 484) — raw `openrouter 400 — {json}` pastes in muted
   gray with no retry affordance.
9. **Screenshot/artifact results aren't surfaced.** `page.screenshot`'s
   reply carries `path` (+ a `data` base64 blob that `slim` doesn't strip —
   `card.result` is a 500-char-trimmed JSON string that happens to keep
   `path` only because key order puts it first). Nothing renders the shot;
   the design's in-stream screenshot cards don't exist. Same for
   `tabs.surface` results — no "handed you the tab" card.
10. **Composer gaps.** The `@` list has no ↑/↓ navigation or Esc dismissal
    (Return takes row 1 — 458-463). `draft` is panel-level — switching
    chats destroys an unsent draft. Placeholder ignores pending-question
    state (the composer *is* the answer box per interaction.md §1, but
    doesn't say so). No sent-history recall (↑ through your messages —
    `FluidInputMessage.history` exists for exactly this). No mic input.
    `siteDraft`/`@` rows can't be dismissed by Escape or outside click.
11. **Zero accessibility.** No `.accessibilityLabel`/hint/trait anywhere in
    AskUI.swift; no `accessibilityReduceMotion` checks on its animations;
    all type at fixed point sizes; the disclosure-to-be needs header trait
    + expanded state.
12. **Header doesn't match the design.** `ModelSelector(short:)` sits in
    the header where the target shows only title + trailing doors
    (pop-out/new/close). No pop-out/detach affordance at all (optional
    feature, see below).
13. **`AskButton` carries no state.** It's lit only while open — a running
    turn, a parked question, or a pending approval while the rail is shut
    is invisible in the chrome (AskUI.swift:14-55).
14. **`steer`'s `.you` renders but the queued-steer path can double-show**
    — `run()` emits `(queued: …)` *deltas* into agent text (harness.js:
    921-925), which the UI renders as agent prose.
15. **Fluid/Palette split.** Rebuilding rows on Fluid components mixes
    `FluidTone.background` (#171717 dark) with `Palette.ground` (~#1C1C1C
    dark) — a visible seam unless one maps onto the other (see §2.11).
16. `FluidScrollArea` has **no programmatic scroll API** — adopting it for
    stick-to-bottom needs `pinsToBottom`/`atBottom` additions first
    (FluidScrollArea.swift: `FluidScrollView`/`Coordinator` already own
    bounds notifications; that's where the API belongs).

## 2. The 10/10 feature set

### 2.1 Turn structure — the "Worked for" disclosure

Every turn (a `.you` and the agent content until the next `.you` or end of
list) renders as:

```
[you bubble, right]
[Worked for 4m 39s  ⌄]            ← disclosure header, spring panel
   │ intermediate agent paragraph (plain prose, muted-normal ink)
   │ ▸ Searched the web, read a page, browsed +1 more   ← tool-group row
   │   (expanded: one row per call — icon, verb phrase, status)
   │ [screenshot card]                                 ← artifact block
   │ intermediate agent paragraph
   │ </> Ruling out cheaper imports                    ← code-ish call
[FINAL answer text — outside the accordion, last in the scroll]
```

- **Derivation**: split `chat.messages` into turns at `.you` boundaries.
  Within a turn, all agent *blocks* except the trailing `.text` run go in
  the accordion; the trailing `.text` run is the answer, rendered below as
  ordinary agent text. A turn with no tools and a single text run draws no
  accordion at all.
- **Header states**: while the turn runs → shimmer/ring + "Working for
  M:SS…" live timer (`TimelineView(.periodic)`), **open by default** so the
  work streams in view; on `.done` → "Worked for 4m 39s" (persisted, see
  §4). Collapsed-by-default once done; the user toggle wins per turn and
  shouldn't be overridden on stream updates.
- **Component**: `FluidThinkingSteps`/`FluidStepsTrigger` +
  `FluidStepsPanel` is the closest match (measured-height collapse,
  dual-layer label, chevron 0→90°, hover fade — FluidThinkingSteps.swift:
  33-149). One `FluidAccordion` also works (FluidAccordion.swift:57) but
  carries group machinery a lone disclosure doesn't need. Strip the fixed
  `frame(width: 320)` in `FluidThinkingSteps.body` (line 35) for rail use.
- **Tool-group row**: consecutive `.tool` blocks collapse to one line —
  small kind icon + "Verb, verb, verb +N more" (past tense when settled,
  present while live: "Searching the web…"). Expanding (nested
  `FluidStepsTrigger`/`FluidThinkingStepDetails` pattern, 251-276) lists
  each call as today's `ToolRow` (name, args→result, status icon, hover
  copy).
- **Verb table** (model-facing names, harness.js:221-328):
  `tabs_list`→"Listed tabs" · `tab_open`→"Opened a tab" ·
  `surface_tab`→"Surfaced a tab" · `tab_attach`→"Attached a tab" ·
  `navigate`→"Browsed to {host}" · `back`/`forward`/`reload`→
  "Went back/forward" · "Reloaded" · `wait`→"Waited for the page" ·
  `snapshot`→"Read the page" · `screenshot`→"Took a screenshot" ·
  `read_text`→"Read the page text" · `run_code`/`eval`→"Ran code" ·
  `click`/`click_at`→"Clicked" · `fill`→"Filled a field" · `type`→"Typed" ·
  `press`→"Pressed {key}" · `hover`→"Hovered" · `scroll`→"Scrolled" ·
  `select`/`check`→"Selected"/"Checked" · `submit`→"Submitted the form" ·
  `inspector_*`→"Inspected the page" · `console`→"Read the console" ·
  `frames`→"Listed frames" · `dialogs`/`answer_dialog`/`choose_files`→
  "Handled a dialog" · `close_tab`→"Closed a tab" · `ask_user`→"Asked you"
  · `done`→**never rendered** (filter at display; ideally stop cardSink
  emitting it, harness.js:788).
- **Group icon** per kind: magnifyingglass (reads: snapshot/read_text/
  console/frames/tabs_list), globe (nav/tabs), cursorarrow.rays (act.*),
  `</>` (run_code/eval/inspector_*), photo (screenshot) — matches the
  design's per-line glyphs.
- **`why` as the line's label**: mutating tools carry a one-line `why`
  (harness.js WHY param, Drive strips it via `Policy.gateKeys`) — when a
  block's tool args decode to `{why}`, render *it* ("Reviewing the shipping
  quote") under a `</>` instead of the verb+args dump. This is exactly the
  design's code-tagged lines.
- **Notes inside a turn** (approval verdicts, errors) keep their position
  inside the accordion stream as quiet steps; errors get the error card
  style (§2.8).
- **Pending items surface outside the accordion**: a live `QuestionRow`
  (tool.result == nil && question open) and `ApprovalCard`s render *below*
  the accordion at stream tail, not buried inside collapsed work. Settled
  `ask_user` collapses into its tool group as "Asked you '…' → '…'".

### 2.2 Message rows

- `.you`: right-aligned pill (the design's flat dark pill —
  `FluidChatMessage(from: .user)` gives bubble fill + entrance spring +
  hover meta row, FluidChat.swift:12-74). Keep tabs/attachment chip strip
  under the bubble (current 874-889), "· retried ×N" caption, context menu
  (Copy / Retry from here / Retry with… / Fork from here). Meta row mounts
  always but hidden until hover (the Fluid pattern — no layout jump, same
  as today's offset chip).
- `.agent` final text: flush-left plain prose, `.textSelection(.enabled)`,
  hover meta (copy · ago · model tail when `mixed`). **Render as markdown**
  — the design shows inline blue links ("Your Playmat 48 × 24 in custom
  mouse pad", "vivo.com"): `Text(LocalizedStringKey(text))` or a parsed
  `AttributedString(markdown:)` with `.tint` for links, bold, lists, code
  spans; links open via `browser.open(_:)`/new tab, not in-place. `.you`
  stays literal.
- `.note`: centered quiet line (current). Errors: distinct card — red-tint
  hairline, triangle icon, one-line clean summary ("OpenRouter 400 — model
  not found"), "Retry" pill bound to `retryable`. Needs an `isError` flag
  on the note (§4) rather than string-sniffing.
- Steer-attribution: `.you` messages sent mid-turn are already appended
  live — no change needed once §4's `runningChatID` fix lands.

### 2.3 Streaming states

- While running: the current turn's accordion reads "Working for M:SS…"
  and stays open; inside it, the in-flight text block streams and the
  live tool group updates in place (the `Ring` per unsettled call,
  existing `ToolRow.running`).
- `mind.activity` (the engine's "thinking…"/tool-name line) renders as the
  accordion's live status line inside the panel — or swap the whole idle
  tail for `FluidThinkingIndicator` (morph glyph + shimmer word,
  FluidThinking.swift:15-79) while no blocks exist yet (pre-first-delta).
- Stop: composer's send button morphs send ⇄ stop (use
  `FluidInputMessage`'s `buttonMode` morph, FluidInputMessage.swift:
  319-342) — replace today's `arrow.up.circle.fill`/`stop.circle.fill`.
- On stop, the partial turn seals: accordion shows "Stopped after M:SS"
  (or "Worked for" + "— stopped"), settled tools stay, the running one
  reads "ended".
- Queued steers render as `.you` bubbles (current) — drop the
  `(queued: …)` delta text the harness emits into agent prose
  (harness.js:924); if kept for the model, mark it out of band instead.

### 2.4 Composer

Rebuild on `FluidInputMessage` (FluidInputMessage.swift:25-436) — it
already has the growing NSTextView editor (`FluidComposerEditor`,
Enter sends / ⇧Enter newline / Tab ghost / ↑↓ suggestion+history contract
/ Esc), the edge ring that recolors focus > hover > drag, the file strip
with hover-×, a queued-message strip, drag-drop, and the morphing
send/stop. The `trailing:` slot takes the model/effort/mode chips.

- **Header slot** (`header:` in FluidInputMessage): today's `chips`
  (context `Chip`s + `AttachChip`s + dashed `+tab` suggestion, AskUI:
  401-450) + `siteDraft` row + the `@` list. In the design the `+` sits
  *inside* the field leading edge and a mic trails it — wire `AttachMenu`
  into a leading accessory and a mic button (§2.9, optional) trailing;
  placeholder becomes "Reply, @ for context" ("Answer the question…" while
  a question is open — `asked != nil`).
- **`@` list upgrades**: ↑/↓ move a lit row, Return/Tab attaches the lit
  row, Esc closes, click-away closes; keep the ≤6 filter and the
  Return-picks-first fallback. `FluidMenu`'s fluid-hover rows match.
- **Drafts are per-chat**: `@State drafts: [UUID: String]` (or on Mind —
  session scope is enough); switching chats restores the chat's draft.
- **History recall**: feed `history:` the current chat's `.you` texts —
  ↑ on the first line walks them (already implemented in the editor).
- **Footer**: `[+ attach]  …  [ModelSelector][ReasonSelector][ModeMenu]
  [send/stop]` — the design's "⚙ GPT-6 Sol · High" is the model chip +
  effort chip reading together; keep three capsule menus (they're already
  `StatusChip`s, 713-740) or fold model+effort into one sectioned menu.
  Remove the header's `ModelSelector` — the composer owns model display
  per the target.
- **Stop semantics**: send button's stop fires `mind.stop()` for the
  *running chat's* turn — with `runningChatID` (§4), disable/hide the stop
  morph when the open chat isn't the running one, and show "Working in
  another chat" state subtly instead (a steer into a non-running current
  chat must never feed another chat's turn — see defect 5).
- Attach parity keeps: `AttachMenu` Image…/File…/Website…; `AskAttach`
  caps (3MB pick / 2MB send / 50k text) and `browser.announce` overflow
  notice.

### 2.5 Chat list

- Filter field at top ("Search chats…") — title + message-text match,
  case-insensitive; `Quiet`-style rows for results.
- Rows: title, last-activity `ago` (**fix `chat.when` to bump on every
  `store`**, §4), badges: `Ring` while that chat's turn runs
  (`runningChatID`), a question-dot while `mind.question?.chat == chat.id`,
  a small count/dot for `pendingApprovals` on it, `⑂` fork mark, unread
  dot (`lastSeen` marker §4). Hover actions: rename (double-click or
  context "Rename…" → inline field calling `Mind.rename`), fork, copy
  transcript, delete — matching today's context menu + visible affordances.
- Components: `FluidSidebar`'s menu-item vocabulary (fluid-hover rows,
  status dots, count badges, hover-revealed actions — FluidSidebar.swift
  header comment) is the visual source; `FluidMenu` rows for context menus.
- New-chat row stays at top; Esc or re-clicking the title closes the list.

### 2.6 Approvals & ask_user

- Pending approval cards pin to the stream tail *outside* the accordion
  (they already render after messages — keep, but inside the turn's card
  flow above the composer, always visible). Unchanged semantics: Allow /
  Always-verb·host / Deny, `why`, lazy `shotPath` thumbnail, verdict writes
  the audit `.note`. Persisted chat replays notes; pendings stay
  in-memory (they're session objects — correct).
- `QuestionRow`: restyle onto `FluidAskUserQuestions` —
  `FluidAskQuestion(title: question.text, options:…, allowOther: true,
  skippable: true)` gives numbered options (1-9 keys), Other row, Skip —
  `onComplete` → `mind.answer`, `onSkip` → `mind.pass`. Its `embedded`
  mode is *the* design's answer-box pattern: option rows in the composer's
  header slot, the editor as free text. Settled: collapses into the tool
  group's "Asked you '…' → '…'" line; "went unanswered" keeps the honest
  ended state.
- Both surfaces must honor the 300s `questionClock` (Mind.swift:497-503)
  with a visible countdown hint (subtle "no answer in M:SS is a decline").

### 2.7 Artifacts & screenshots

- **Screenshot card**: a `screenshot`/`page.screenshot` block whose result
  carries `path` renders the PNG as a card — rounded-8, hairline, ~160pt
  wide thumbnail lazy-loaded (`NSImage(contentsOfFile:)`, the
  `ApprovalCard` pattern at 1205-1209), click → open in a tab or
  QuickLook, hover → copy path/reveal-in-Finder menu. Needs `shot` on the
  tool model (§4) — do not re-parse the 500-char-trimmed result JSON for
  it (fragile: `data` base64 can push `path` past the trim; also strip
  `data` in `slim`, harness.js:755-760).
- **Surfaced-tab card**: `tabs.surface` result `{id, surfaced:true}` → a
  small card "Handed you {tab title}" with the tab's mark; click selects
  it (`browser.tabs` lookup by `Bench.short` prefix).
- Both render inside the accordion at their block position — the design's
  screenshot cards — and a surfaced card may also render under the final
  answer (the "Your Playmat" card in the target).

### 2.8 Errors & notes

- `AskMessage` `.note` gains `isError` (or `.error` role — prefer flag,
  decode-missing→false): errors draw the tinted card + Retry; audit notes
  stay quiet centered. Parse the harness's `"openrouter 400 — …"` prefix
  once at `hear(.done)` into a short line + full text in `.help`/copy.
- Rate-limit/timeout surfaces: keep text honest, attach "Retry with…" to
  error cards via the existing `retry(from:with:)` + model submenu.

### 2.9 Keyboard & shortcuts

- **⌘⇧A (or ⌘J) toggles the rail** — add a menu command `Toggle Ask`
  → `mind.toggle()`; opening focuses the composer (existing
  `DispatchQueue.main.async { typing = true }`, AskUI.swift:101).
- In-panel: Return send / ⇧Return newline (exists); ↑/↓ @-list + history;
  Esc closes @-list → then siteDraft → then clears focus → then closes
  panel (cascading); ⌘N new chat while panel focused; ⌘Return could force
  send even while `@` open.
- Question card: digit keys pick options, ⌘↵ submits (FluidAskUser's
  contract, verbatim).
- Accordion headers are buttons — Space/Return toggles; add
  `.accessibilityAddTraits(.isHeader)` + expanded state.

### 2.10 Scrolling

- **Stick-to-bottom**: `ScrollView { LazyVStack { Spacer(minLength:0); … }
  }.defaultScrollAnchor(.bottom)` — short conversations rest at the bottom
  (the design's pinned answer), long ones pin during streaming.
- **Scroll-away detection**: track at-bottom via `scrollGeometry`/bounds
  notifications; while unpinned, stop auto-scrolling and float a
  "↓ Jump to latest" capsule at the bottom edge (with unread-since count
  optional); scrolling back to bottom re-arms the pin.
- If `FluidScrollArea` is adopted for the overlay scrollbar + edge fades +
  dividers (FluidScrollArea.swift), first add to `FluidScrollView`/
  `Coordinator`: a `pinsToBottom` flag (re-scroll on document growth while
  pinned) and an `atBottom: Binding<Bool>`/`onAtBottomChange` report —
  all inputs already exist in `didScroll`/`sizeDocument`.
- Keep `id("end")` anchor for jump-to-latest and `currentID` changes.

### 2.11 Visual fidelity & theming

- The target is dark-first; both palettes must resolve right. **Do not mix
  `Palette` and `FluidTone` on one card**: either rebuild the rail fully on
  FluidTone (surfaces/borders/hover) or bridge the handful of FluidTone
  tokens onto Palette values. Pick one per surface; the rail's card is the
  boundary.
- Header: title+chevron left; trailing `Door`s — pop-out (optional, opens
  the chat in a small standalone window), `square.and.pencil` new chat,
  `xmark` close. No model chip in the header.
- Hover states everywhere rows exist (existing pattern); entrance springs
  on messages (`FluidChatMessage` gives y+8/scale-0.96 anchored entry);
  `Motion.quick`/`FluidSpring.fast` consistently — new code uses the Fluid
  tiers per component, not ad-hoc eases.
- `accessibilityReduceMotion` respected on every animated affordance the
  way Fluid components already check it; VoiceOver labels on every
  icon-only control (Ring→"working", doors, chips' ×, mic, send/stop);
  text at Dynamic-Type-scaled sizes or at minimum consistently derived
  `system(size:)` tiers.
- `AskButton` state: lit while open (current) **+ a status dot** while any
  turn runs / a question or approval waits and the rail is shut — the
  chrome's only ambient signal that the panel wants attention.
- `Mind.raise`/`pose` already force `open = true` — keep; add the same
  pull-to-front for a completed turn while closed (optional, subtle).

### 2.12 Empty state & polish

- Keep the sparkle/empty card; align visuals to the rail (title, hint "@
  attaches a tab", the three starter `Pill`s). Optionally surface the
  active page's chip suggestion in the empty state too.
- 380pt stays fixed (App.swift:335). Optional stretch: drag-resize rail
  via `FluidSidebar`'s rail-drag pattern (160–360 clamps); persisted width.
- Multi-window note: `Mind` is a singleton — two windows share one panel
  state; acceptable now, document it.

## 3. Prioritized fix list

Ranked by defect severity × how much of the target design they block.

| # | Defect | Where | Fix sketch |
|---|--------|-------|-----------|
| P0 | Turn flattening — text/tool order destroyed, answer not last | harness.js:893-898, Mind.hear (Mind.swift:410-438), AskLine.agent (AskUI.swift:895-914) | Ordered blocks on `AskMessage` (§4); accordion + trailing answer |
| P0 | Cross-chat running: `steer` feeds another chat's turn; UI shows live state on the wrong chat; `send` silently kills a live turn | Mind.swift:342-355, 257-262, 316; harness.js:918 | `runningChatID` tracking; composer state per current chat; refuse/confirm takeover |
| P0 | Scroll yanking — no stick-to-bottom detection | AskUI.swift:268-270 | `defaultScrollAnchor(.bottom)` + at-bottom tracking + jump pill |
| P1 | "Worked for" accordion absent; no duration anywhere | AskUI conversation | Turn grouping + `workedFor`/`turnStartedAt` (§4) + live timer |
| P1 | No per-block nested disclosures; tools one card each, mono-dump style | AskUI.swift:904-911, ToolRow | Tool-group summary rows + expandable detail; verb table; `why` labels |
| P1 | Screenshot/artifact cards missing; `path` only survives in trimmed JSON | harness.js:755-760, 800-802 | `tool.shot` field + card renderer; strip `data` in `slim` |
| P1 | `done` renders as a tool row | harness.js:788-802 | Filter `done` (and `grant`-kind) from display |
| P2 | Errors indistinguishable from notes; ugly raw provider dumps | Mind.swift:451-453, AskUI.swift:916-923 | `isError` flag, error card + Retry |
| P2 | Chat list: ordering by creation, no search/rename/badges/unread | AskUI.swift:168-196, ChatRow; Mind.store | bump `when` on activity, filter field, rename UI, status badges, `lastSeen` |
| P2 | Composer: @-list no ↑↓/Esc; drafts lost on switch; no history recall; placeholder ignores open question | AskUI.swift:336-395, 458-463 | rebuild on `FluidInputMessage`; per-chat drafts; `history:`; question placeholder |
| P2 | No keyboard shortcut to toggle Ask | App.swift commands (29-208) | Add `Toggle Ask` ⌘⇧A/⌘J + focus composer on open |
| P3 | Zero accessibility; no reduce-motion | all of AskUI | labels/traits, reduce-motion checks |
| P3 | No scrollbar/fades; Fixed palette split FluidTone vs Palette | AskUI.swift:223; Fluid.swift:25-92 | `FluidScrollArea` (after scroll API) or native fades; one palette per surface |
| P3 | `AskButton` shows no activity state; no mic; no pop-out | AskUI.swift:14-55 | status dot; optional mic; optional detach-window |
| P3 | `(queued: …)` steer text lands in agent prose | harness.js:924 | emit as activity/note, not delta |

## 4. Data-model additions

All fields follow the file's existing forgiving decode (`decodeIfPresent ??
default`) — old chats must load clean.

```swift
struct AskMessage {
    /// Ordered render blocks: what the turn did, in the order it did it.
    /// nil on old files → derive [text]-then-[tools] in the accessor.
    var blocks: [AskBlock]?          // nil → legacy
    /// How long the turn this message closes worked — stamped by Mind on
    /// `.done`, feeds "Worked for 4m 39s".
    var workedFor: TimeInterval?     // nil → live/unknown
}
enum AskBlock: Codable, Equatable, Identifiable {
    case text(String)                // one streamed paragraph run
    case tool(AskMessage.Tool)       // one call
    case artifact(path: String, tab: String?)   // screenshot / surfaced tab
}
struct AskMessage.Tool {
    var shot: String?   // absolute path when the result was an image file
    var why:  String?   // the model's own one-liner, if it gave one
}
struct AskChat {
    /// When the live turn began — set in send/retry beside `turn`; drives
    /// the running "Working for M:SS" timer and `workedFor` on done.
    var turnStartedAt: Date?
    /// Last-read message id → unread dot in the chat list; select() stamps.
    var lastSeen: UUID?
}
final class Mind {
    /// The chat the engine's turn belongs to — set on send/retry, cleared
    /// on `.done` for that chat. Replaces the global `running` for all
    /// per-chat UI (badges, live flags, steer targeting, composer state).
    @Published private(set) var runningChatID: UUID?
    /// Which agent message is currently absorbing deltas per chat —
    /// ephemeral, nil after relaunch (persisted messages never reopen).
    private var openAgent: [UUID: UUID] = [:]
}
```

**Emit-side (harness.js)**: build `blocks` alongside the existing
`text`/`tools` — each provider step's text pushes a `{kind:'text'}`
block at iteration end (or first delta of the step), each `cardSink` push
appends `{kind:'tool'}`; attach `shot: result.path` when the result names
an image file (and strip `data` from `slim` — it base64s megabytes into
the trimmed card text); emit the final `message` with `blocks` populated.
Keep `text`/`tools` in the emit — `toHistory` and old builds keep working.

**Fold-side (Mind.hear)**: `.delta` → append to the last block if it's
`.text`, else push `.text("")`; `.tool` → push/update a `.tool` block;
`.message` → replace text/tools/blocks wholesale (authoritative snapshot);
`.done` → stamp `workedFor = now − chat.turnStartedAt` on the tail agent
message, clear `turnStartedAt`/`runningChatID`/`openAgent[chat]`. `send`/
`retry` set `turnStartedAt = Date()` and `runningChatID = chat.id`.
Derived for old files: `var orderedBlocks: [AskBlock] { blocks ??
([.text(text)] unless empty) + tools.map(.tool) }` — used by the renderer
exclusively, never by `toHistory` (history keeps `text`+`tools`).

**Turn/accordion derivation** (pure, testable):

```swift
struct Turn { let you: AskMessage; var work: [AskBlock]   // accordion body
              var answer: String                          // trailing text
              var approvals: [AskApproval]; var duration: TimeInterval? }
func turns(of chat: AskChat) -> [Turn]  // split at .you; last text run → answer
```

**Chat list ordering**: `store(_:)` bumps `chat.when = Date()` (it already
sorts `AskStore.list` by `when` and feeds `ChatRow`'s subtitle — one line
makes ordering = recency and subtitle = last activity).

Also considered and rejected: per-step `.agent` *messages* (sealing via
`.message` events) — workable but changes `hear` semantics, persistence
shape and `toHistory`'s 30-message window for zero rendering gain over
ordered blocks.
