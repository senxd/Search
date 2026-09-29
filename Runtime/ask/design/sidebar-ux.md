# Ask rail — UX & visual spec (v2, "Worked for Xs" design)

> Scope: the floating chat rail in `Sources/Search/AskUI.swift` (`AskPanel`,
> `AskLine`, `ToolRow`, `ChatRow`, `ApprovalCard`, `QuestionRow`), drawn with
> the Fluid Functionalism kit (`Fluid.swift`, `FluidChat`, `FluidAccordion`,
> `FluidThinkingSteps`, `FluidScrollArea`, `FluidInputMessage`, `FluidMenu`,
> `FluidTooltip`) over the existing `Palette` primitives where the kit has no
> equivalent. Intent docs honored: `Runtime/ask/design/chatux.md`,
> `interaction.md`, `permissions.md`.
>
> Reference: the target mock — a dark rail whose stream shows a right-aligned
> user pill, an expanded "Worked for 4m 39s ⌄" section of nested working
> blocks, a final answer in plain text, inline artifact/screenshot cards, and
> a two-row composer pinned at the bottom.

## 0. The one structural change this design requires

Resolved in `sidebar-features.md` §4: **ordered `blocks` on `AskMessage`**
(`case text(String) / tool(AskMessage.Tool) / artifact(path, tab)`), stamped
by both the harness's final `message` emit and Mind's live fold. That doc's
model is the one to build — a turn stays one message; `blocks` records the
order the work happened in. Old chats decode `blocks: nil` and derive
`[text]+[tools]` — they render correctly with zero migration.

## 1. Layout anatomy

The rail is the window's whole right column (`App.swift:333-338`). The card
keeps **8 pt of air on every side** — top, trailing, bottom, and leading
where it meets the page.

| Element | Value |
|---|---|
| Rail width | **380 pt** fixed (today). Resizable variant: drag rail on the leading edge, **min 340 / default 380 / max 480**, collapse slop 56 pt per `FluidSidebar`'s pattern — phase 2, not blocking. |
| Card corner radius | **16 pt** continuous (unchanged) |
| Card fill | `FluidTone.surface(1)` — near-solid; the rail is a work surface, not glass. (Today: `Palette.wash.opacity(0.55)`.) |
| Card edge | 1 pt `FluidTone.border` stroke inside the clip |
| Card shadow | `black` 10%, radius 16, y 4 (unchanged) |
| Panel open/close | slide-from-trailing + fade on `Motion.glide` (spring .34/.82); the page gives ground, it is never covered |

Inside the card, top to bottom, one `VStack(spacing: 0)`:

```
┌────────────────────────────────────────┐
│  header              h: 9v, 12l / 9r   │
│ ── hairline (FluidTone.border 60%) ──  │
│  stream (scrolls)    h: 14, v: 16      │
│  [jump-to-latest pill — floats]        │
│  approvals zone (only while pending)   │
│ ── hairline ──                         │
│  composer card       h: 10, top 8, b 10│
└────────────────────────────────────────┘
```

**Header** — height driven by content: `.padding(.leading, 12)
.padding(.trailing, 9) .padding(.vertical, 9)` (unchanged). One
`HStack(spacing: 6)`.

**Stream** — `LazyVStack(alignment: .leading, spacing: 14)`,
`.padding(.horizontal, 14) .padding(.vertical, 16)`. The 14 pt unit is the
*turn-level* gap; spacing inside a turn block uses the 4-pt scale below.

**Spacing scale** (all on a 4-pt grid): 4 within a row · 6 between chip/row
internals · 8 paragraph→cluster and block-internal gaps · 12 between blocks
inside the accordion · 14 between stream items (messages, notes, turn
groups) · 16 stream outer padding.

**Hairlines**: `FluidTone.border` (white 10% / neutral-200 ~#EBEBEB),
always 1 pt, never doubled. The only full-bleed rules: header/stream
separator and the composer card's own top edge (the composer is a card —
its border *is* the separator).

**Type ramp**: title 13 semibold · message text 12.5 regular · block
paragraph 12.5 · cluster header 11 medium · tool detail 10.5/9.5 monospaced
· meta 9.5 · status chips 10 medium · caption/ago 10.5. (All `.system`;
monospaced via `design: .monospaced` as today.)

## 2. The "Worked for Xs" accordion — semantics

### 2.1 Turn grouping

A **turn group** = a `.you` message plus the run of `.agent` messages (and
interleaved `.note`s) that follows it, up to the next `.you` or stream end.
Within a turn group:

- The **final block** is the turn's last `.text` block — the text emitted
  just before `done` (or still streaming at stream tail). Its text renders
  **outside** the accordion, plain, full-width — the resting position of
  the whole stream.
- Every earlier `.text` block and every `.tool`/`.artifact` block is an
  **intermediate** block and lives inside the accordion.
- The final block's *tools and step lines* still live **inside** the
  accordion as its last section — only its text and its artifacts come
  outside.
- `.note` lines render at chronological position: between intermediate
  blocks → inside the accordion; after the final message → outside, as
  today (centered, 11 pt, muted).
- A `.you` mid-turn (steer) closes the current turn group and opens a new
  one — the first turn's accordion freezes at its elapsed time; the new
  turn starts a fresh accordion.

### 2.2 Block anatomy

Each intermediate section (a text block + the tool/artifact run that
follows it, up to the next text block), in order:

1. **Paragraph** — the iteration's text, if any. 12.5 pt
   `FluidTone.foreground`, `textSelection(.enabled)`,
   `fixedSize(horizontal: false, vertical: true)`. Skipped entirely when
   empty — a section may be tools-only.
2. **Tool cluster** — a *nested* accordion, one per section, summarizing
   that section's tool calls:

   - **Header row** (always one line, 24 pt tall): a 12-pt-wide icon slot +
     7-pt gap + 11 pt medium summary + trailing mini-chevron
     (`chevron.right` 6.5 pt → rotates 90° open, `FluidSpring.fast`).
   - **Icon by dominant op class** of the cluster: read-class (`snapshot`,
     `read_text`, `console`, `frames`, `tabs_list`, `search`-like) →
     `magnifyingglass`; write/act-class (`act.*`, `tabs.*`, `page.go`,
     `run_code`, `eval`) → `chevron.left.forwardslash.chevron.right`;
     `ask_user` → `questionmark.bubble`; mixed clusters take the heaviest
     class's icon.
   - **Summary text** — comma-joined verb phrases in call order, deduped,
     capped at 3 items then `+N more`. Verb table lives in
     `sidebar-features.md` §2.1 ("read the page", "browsed acme.com",
     "ran N actions", "asked you", …). `done` is never listed — it's the
     turn boundary, not work.
   - **Step caption variant** — when the cluster's dominant act call
     carries a `why`, or `mind.activity` supplied a named phase for that
     stretch: the header reads `</>` + the model's gerund phrase verbatim
     ("Reviewing the shipping quote", "Ruling out cheaper imports")
     instead of the verb list. These are the mock's `</>` lines. The same
     row still expands.
   - **Expanded body** — the block's `ToolRow`s verbatim (today's card:
     9-pt icon slot, mono name + middle-truncated `args → result`, 8-pt
     radius, `ground` fill, hairline; failed → red ink + red 25% border;
     running → `Ring(9)`), indented 19 pt to align under the header text,
     6-pt row spacing. The `ask_user` row keeps its `QuestionRow`
     special-casing.
3. **Artifact cards** — inline, in call order, after the cluster (§2.4).

### 2.3 Accordion header — "Worked for Xs"

One row, full stream width, 24 pt effective height, hit area the full row:

```
[Ring 9 | nothing]  "Working for 12s" / "Worked for 4m 39s"   chevron.right→90°
```

- **Label**: 12 pt medium. While `mind.runningChatID == chat.id` for this
  turn: leading `Ring(size: 9)` (the existing 0.85 s trim-rotation) +
  "Working for \(elapsed)". Blocked on a question or approval for this
  chat: "Waiting on you — \(elapsed)". Settled, stopped, or errored:
  "Worked for \(elapsed)".
- **Elapsed format** — floor to whole seconds, `monospacedDigit()`:
  - `< 60 s` → `"12s"`
  - `< 60 m` → `"4m 39s"`
  - `≥ 60 m` → `"1h 4m"`
  - under 1 s → `"<1s"`.
- **Chevron**: `chevron.right` 7 pt bold `FluidTone.mutedForeground`,
  rotates to 90° while open (`FluidSpring.fast`).
- **Colors**: label `FluidTone.mutedForeground` at rest →
  `FluidTone.foreground` on hover/open (the dual-layer label trick from
  `FluidStepsTrigger` — invisible semibold twin reserves width, open
  emboldens without reflow).
- **Hover**: 8-pt-radius `FluidTone.hover` wash behind the row.
- **Focus**: `FluidTone.focusRing` 1 pt stroke, 2 pt outset, radius 10 —
  keyboard-focus only.

### 2.4 Artifacts and screenshots

- **Shot card** (a `Tool.shot`): inline thumbnail inside its section — max
  width **132 pt**, aspect-fit, `RoundedRectangle` radius 8 continuous,
  1-pt `FluidTone.border`, `Palette.ground` behind while loading, lazy
  `NSImage(contentsOfFile:)` on appear exactly like `ApprovalCard`
  (`AskUI.swift:1205-1209`). Click → opens the image in a `Peek`-style
  float or the tab it came from when the tool args name a live tab;
  context menu: Copy Image, Open in Tab, Reveal in Finder.
- **Wide artifact card** (a tool result carrying `{url, image, title}` —
  e.g. the mock's "Your Playmat" product card): full content width, radius
  12 (`FluidShape.rounded.container`), hairline border,
  `FluidTone.surface(2)` fill; top: cover-fit banner image 100–140 pt tall;
  below: title 12.5 medium + host 10.5 muted in a 10-pt-padded row; a link
  glyph trailing. Click → `tabs.open`-equivalent for the user (open in a
  real tab); context menu: Open, Copy Link, Copy Image.
- Artifacts attach to the **section that produced them**: inside the
  accordion for intermediate sections; outside, beneath the final text,
  for the final section.

### 2.5 Default open/closed, live vs. settled

| Context | Default |
|---|---|
| Turn in flight | **Open** — the live block is the thing happening; user may collapse freely (a user-set state always wins) |
| Turn ends while accordion open | **Stays open** (the mock's settled state) |
| A new `.you` lands | All prior turns' accordions **collapse** (`FluidSpring.fast`); the live one opens |
| Chat opened from the list / panel reopened / app relaunch | Every accordion **closed** — settled history reads as question → "Worked for Xm" → answer |
| Nested clusters | Always **closed** by default, live or settled; opening is per-cluster, per-session (no cross-launch state) |

State identity: accordion open-state keyed by turn (`chat.turn` stamp or
the `.you` message id) + chat id; nested clusters keyed by section index +
message id. Per-session `@State`/dictionary — never persisted.

### 2.6 Live behavior while streaming

- The header ticks once per second (`TimelineView(.periodic(1))` — only
  while running; stop the clock at `done`/`stop`).
- The in-flight section streams at the tail: paragraph text appends
  verbatim (no per-token animation; a `.transition(.opacity)` on each *new
  section*, not on glyphs).
- A tool in flight shows `Ring(9)` inside its cluster row;
  `mind.activity` feeds the step caption when it's a named phase, else the
  header stays the verb summary.
- While running **and accordion collapsed by the user**, a compact live
  line renders under the header anyway — `Ring(9)` + `mind.activity` 11 pt
  muted — so the stream never looks dead mid-turn.
- `done` → Ring fades (140 ms), label swaps "Working"→"Worked" with the
  frozen time.
- `stop`/error → same settle; the error `.note` lands after, outside.

### 2.7 Fallbacks

- Turn with **no tools and one agent message** → no accordion at all;
  plain text, today's rendering.
- Turn with tools but **no intermediate text** → accordion exists
  (sections are tools-only), final text outside.
- Old single-message chats → derive `blocks` from `[text]+[tools]`; if
  tools exist the accordion wraps them, text outside. Renders correctly
  with zero migration.
- `retries > 0` badge stays on the `.you` bubble (unchanged, 9.5 pt faint
  "· retried ×N").

## 3. Scroll & pin behavior

Today's `ScrollViewReader` + `scrollTo("end")` on every `messages` change
is *always pinned* (`AskUI.swift:268-270`) — replace with a follow-model:

- **Pinned** state: the stream's bottom is within **24 pt** of the viewport
  bottom, or the user has never scrolled. `ScrollView` +
  `LazyVStack { Spacer(minLength: 0); … }.defaultScrollAnchor(.bottom)`
  gives both the short-conversation bottom rest and the live pin. While
  pinned, every content change re-anchors to `"end"` — **no animation** on
  deltas (per-token animation is judder), `Motion.settle` on discrete
  arrivals (a whole message, a card, an accordion collapse).
- **Un-pin**: any user scroll that lifts the bottom edge more than 24 pt.
  Respected absolutely — streaming never drags the user back.
- **Jump-to-latest pill**: when unpinned **and** new content arrived since
  un-pin — a capsule floating at bottom-center of the stream, 16 pt above
  the approvals zone/composer: `arrow.down` 9 pt + "New activity" 11 pt
  medium, `FluidTone.surface(3)` fill, 1-pt border, shadow (black 10%, r6,
  y2). Entrance: scale 0.9 + fade, `FluidSpring.fast`; tap →
  `scrollTo("end")` on `Motion.settle` + re-pin + pill exits.
- **Re-pin**: user scrolls to bottom, taps the pill, **or sends a
  message**.
- **Accordion toggled by the user while pinned**: expand → content grows
  downward, stay pinned; collapse → stay pinned. While **unpinned**, a
  toggle must hold the *toggled row's* position — anchor on the row id so
  the header doesn't leap.
- **Chat switch** (`mind.currentID` change) → jump to end unanimated,
  pinned.
- **Scrollbar**: keep `showsIndicators: false` (the mock shows none).
  Optional upgrade path: `FluidScrollArea` once it has a pin API
  (`sidebar-features.md` §2.10).
- **Scroll fades**: top edge only, 32 pt (`fluidScrollFade`,
  `Fluid.swift:565`). Bottom edge stays crisp (the composer is the
  boundary).

## 4. Every interactive element

| Element | Rest | Hover | Pressed | Focus | Transition |
|---|---|---|---|---|---|
| **Title button** | 13 semibold, 7-pt chevron faint, radius-7 clear bg | `FluidTone.hover` bg | `FluidTone.active` bg | focusRing | `easeOut 0.08` hover, `Motion.quick` list swap |
| **Header Doors** (26×26, radius 8) | icon 11 pt medium mutedForeground | `hover` bg | `active` bg | focusRing | `Motion.quick` |
| **User pill** | `FluidTone.bubble` fill, radius **14** symmetric continuous, pad h12 v7 | — | — | — | — |
| **Hover meta chip** | hidden; floats in the 14-pt gap, edge-matched; capsule h18, ground + hairline, `doc.on.doc` 9 pt + ago + model-tail | appears `Motion.quick`; chip holds own hover | copy → `checkmark` 0.8 s | — | opacity 140 ms |
| **Accordion header** | muted label, chevron right | hover wash r8, embolden if open | — | focusRing r10 | `FluidSpring.fast` |
| **Nested cluster header** | 11 pt medium muted + mini chevron | hover wash r8 | — | focusRing | `FluidSpring.fast` |
| **ToolRow** | ground r8 hairline, mono 10.5/9.5 | reveals `CopyChip` | — | — | `Motion.quick` |
| **Chat list row** | clear | `Palette.hover` r9 | live: `ground` + 3-pt shadow | — | `Motion.quick` |
| **Pill** | ground capsule + hairline, 11.5 | `hover` fill | `active` | focusRing | `Motion.quick`; filled variant ink/ground |
| **Chips** | `Palette.wash` capsule, 10.5, hairline; × = 7 pt bold muted | ×→ink; chip → `hover` | — | — | `Motion.quick`; suggestion stays **dashed** `[3,2]` |
| **Status chips** | capsule 10 medium muted, `ground`60% fill, hairline, chevron 6.5 | `hover` fill bump | menu open → `active` pinned | focusRing | `Motion.quick` |
| **Send/stop** | 22-pt circle, hairline, `arrow.up` 11 pt; disabled → `faint` | flat | `FluidMix.fgOverBg(80)` filled | focusRing | arrow ⇄ stop square morphs `scale(0.6)+opacity`, `FluidSpring.fast` (`FluidInputMessage` morph verbatim) |
| **Jump pill** | surface(3) capsule | `hover` | `active` | focusRing | scale+opacity fast |

**Menus** — every menu draws as `FluidMenuPanel`: surface+2 elevated,
radius 12, `FluidMenuItem` rows h28 compact (icon slot 14, label 12, check
slot), fluid-hover gliding highlight, popup entrance y−4+scaleY 0.96 on
`FluidSpring.fast`, dismiss on outside-click/Escape/pick.

**Context menus** — unchanged semantics, Fluid skin:
- `.you` line: Copy · Retry from here · Retry with… · Fork from here
- `.agent` line: Copy · Fork from here
- `ChatRow`: Copy Transcript · Fork · — · Delete (destructive)
- Tool cluster row: Copy (`"name args → result"` verbatim)
- Artifact/shot card: Open · Copy Image/Link · Reveal in Finder

**Keyboard contract**:
- `Return` sends · `⇧Return` newline · `@…` list: `↑/↓` move, `Return`
  picks, `Esc` drops · `Esc` empty/nothing-open → closes panel
- `⌘C` copies selection (`textSelection` everywhere incl. accordion)
- `⌘⇧N` new chat (advertise in the new-chat Door's tooltip)
- `Tab` reaches: title, doors, accordion headers (Space toggles), cluster
  headers, pills, chips' ×, status chips, send
- `⌘.` or the stop button stops a turn

**Tooltips** — `.fluidTooltip(..., delay: 0.2)` on every Door, attach +,
send/stop, jump pill, status chips.

## 5. States

**Empty** (no chat / no messages): sparkle 20 pt medium muted in a 54-pt
circle (ground + hairline), "Ask Search" 14 semibold, "Ask about this
page, or give it a task.\n@ attaches a tab." 11.5 muted centered, three
`Pill`s (`Summarize this page` hands `browser.active` over then sends;
`What's open?`; `Open example.com`) — `ViewThatFits` H→V fallback stays.
`FluidTone` colors.

**Streaming**: accordion open, live section at tail, header ticking, live
line under a collapsed header, send morphs to stop, status chips stay
scoped to the *next* turn.

**Awaiting-answer (`ask_user`)**: the tool's in-stream row collapses to
its one-line `ask_user — waiting` form; the *live surface* pins into the
**approvals zone** above the composer: `QuestionRow.open` verbatim —
`questionmark.bubble` + question 11.5, option Pills, field + send + Skip.
Header reads "Waiting on you — Ns". On answer: zone card fades+slides out
(`FluidSpring.moderate`), stream row lands settled. The composer stays the
answer box — `Mind.steer` already routes; placeholder swaps to "Answer the
agent…".

**Approvals**: pending `ApprovalCard`s for the current chat pin in the
approvals zone — pause.circle card with `Policy.describe` summary,
model's `why` in quotes, evidence shot, Allow / Always-verb·host / Deny
pills. Audit `.note` lands in-stream on resolve (unchanged).

**Error**: `.note` with `isError` draws the tinted card — red hairline,
triangle icon, one clean line ("OpenRouter 400 — model not found"),
"Retry" pill bound to `retryable`.

**Offline / no engine**: composer stays live; first send produces the
existing "(no engine yet…)" note. Model·effort chip draws
`FluidTone.destructive`-tinted label while `mind.engine == nil`.

**Long conversations**: `LazyVStack`; closed accordions don't pay for
their sections (measured-height panels render lazily while settled).

**Narrow width** (< 340, only if the resize rail lands): title truncates
`.tail`; model·effort chip truncates `.middle` (tighten cap to 120);
`.you` leading inset 46→24; chips scroll horizontally.

## 6. Composer — full spec

One `Card` — `FluidTone.surface(2)` fill, radius **12**, 1-pt edge ring
that recolors per state (**contrast never thickness**,
`FluidInputMessage.edgeColor` verbatim): rest → `border`60% · hover →
`border` · focused → `foreground`20% · drag-over → `focusRing` · 80 ms
`easeOut` between states.

Internal padding: rows separated by `FluidTone.border`60% hairlines,
full-bleed.

**Row 1 — chips** (only while non-empty): horizontal `ScrollView`,
`HStack(spacing: 6)`, pad h10 v8. `Chip`, `AttachChip`, then the **dashed
suggestion** `+ <label>`.

**Row 2 — `@`-completion** (only while `at != nil`): `AttachRow`s — `Mark`
14, label 12, host 10.5 muted, hover `Palette.hover` r7, max 6 rows, "No
tab matches" empty line; ↑/↓ moves a lit row, Return/Tab picks, Esc drops.

**Row 3 — site entry** (only while `siteDraft != nil`): `SiteRow` — globe
+ field + send + ×, autofocused.

**Row 4 — input**: `HStack(alignment: .bottom, spacing: 8)`, pad h12 v9.
`+` AttachMenu (20-pt circle, ground fill, hairline, `plus` 9.5 bold);
`FluidComposerEditor` field, 12.5 pt, 1–6 lines, placeholder **"Reply, @
for context"** (or "Answer the agent…" while a question is open);
dictation `mic` at the field's trailing edge (hide when unavailable).

**Row 5 — status**: hairline above, `HStack(spacing: 6)`, pad h12 v7.
Left: icon-only chips for **mode** and **effort** (only while
`canReason`). Spacer. **Model·effort chip** ("gpt-6-luna · high ⌄" —
truncates middle, effort word dropped when `canReason` false). **Send/stop
22-pt circle at the status row's far right** (the mock's placement).
File-drop target: the whole card.

**Focus**: `typing` FocusState on open; click in the card's dead space
focuses the field; focus leaves only on Esc-empty-close or deliberate
outside click.

## 7. Header & chat list

**Header** (`HStack(spacing: 6)`, pad l12 r9 v9): title cluster (13
semibold + `chevron.down`/`up` 7 pt bold faint, radius-7 hover wash; a
9-pt `Ring` after the chevron while `runningChatID == currentID`), Spacer,
trailing Doors: `list.bullet` "Chats" · `square.and.pencil` "New chat
⌘⇧N" · `xmark` "Close Ask". **No model chip in the header** — it moved to
the composer.

**Chat list** (replaces the stream, `.transition(.opacity)` on
`Motion.quick`): `ScrollView` + `VStack(spacing: 2)`, pad 6; `Quiet`
new-chat row first; `ChatRow` two-line (title 12.5 / `ago` 10.5 — bump on
every `store`, per §4 of the features doc), trailing `⑂` fork mark, `Ring`
for that chat's live turn (`runningChatID`), `checkmark` for current,
`questionmark.bubble` when `mind.question?.chat == chat.id`,
approval-count dot for `pendingApprovals`, unread dot from `lastSeen`,
hover-revealed `xmark` delete. Row h~46 r9; live → `ground` + 3-pt shadow;
hover → `hover`. Select → `mind.select(chat)`, list closes, stream jumps
to end unanimated. >8 chats: `Hunt`-style filter field at top (phase 2).

## 8. Motion spec

| Motion | Animation | Notes |
|---|---|---|
| Rail in/out | `Motion.glide` | `.move(edge: .trailing) + .opacity` |
| Message/section entrance | `FluidSpring.moderate` | y+8, scale .96 → 1, fade; anchor bottom-matched |
| Accordion/cluster toggle | `FluidSpring.fast` | measured-height + opacity leading; chevron on same spring |
| Streaming text | **none** | deltas append silently; a new section fades in 120 ms |
| Working ring | `linear(0.85)` repeat | existing `Ring` |
| Shimmer on "Working" label | `fluidShimmerSweep` 1.5 s | off when `FluidPerf.quiet` or reduce-motion |
| Hover | `easeOut 0.08` | every highlight |
| Send⇄stop morph | `FluidSpring.fast` | scale .6 + opacity crossfade |
| Jump pill | `FluidSpring.fast` | scale .9 + opacity |
| Menus/tooltips | `FluidSpring.fast` | y−4 + scaleY .96 / 4-pt slide |
| Chat-list swap | `Motion.quick` | opacity |
| Approvals zone | `FluidSpring.moderate` | `.move(edge: .bottom) + .opacity`, height included |
| Press | `easeOut 0.08` in / `timingCurve(0.23,1,0.32,1, 0.18)` out | `FluidButton`'s press trick |

## 9. Dark / light & reduced motion

- **Every color is a pair** — `FluidTone`/`Palette` resolve against the
  window's appearance; the panel never reads `colorScheme` itself except
  where a recipe already encapsulates it (`fluidSurface`).
- **One palette per surface** — no `FluidTone`/`Palette` mix on one card
  (`sidebar-features.md` §2.11).
- **Reduced motion**: shimmer off; morph glyph static; chevrons crossfade
  not rotate; springs → `easeOut 0.12` fades; entrances keep fade, drop
  offset+scale; `Ring` stays (it *is* the status); re-anchoring stays
  instant.
- **Contrast**: text ≥ muted-foreground on its surface; tool summaries are
  `mutedForeground` not `faint`; `faint` is reserved for timestamps, meta,
  suggestions.

## 10. Anti-goals

- **No boxed accordion** — "Worked for Xs" is a bare collapsible section
  in the flow, not a card around the working.
- **No markdown on `.you`**; `.agent` text gets a markdown pass per
  `sidebar-features.md` §2.2 (the design's inline links).
- **No per-tool cards at rest** — the collapsed cluster is one honest
  line.
- **No avatars, no "AI:" labels, no always-on timestamps** — meta is
  hover-revealed.
- **No typing dots** — the Ring + ticking elapsed time is the whole
  liveness story.
- **No accent color in the stream** — the only blue is `focusRing` on
  keyboard focus.
- **No shadows inside the stream** — shadow belongs to the rail's edge and
  the jump pill.
- **No auto-collapse of a finished turn while you watch.**
- **No blocking modal** for approvals/questions — they pin to the zone.
- **No emoji, no gradients** (scroll-fade mask excepted).
- **No "copy" on `note` rows.**
- **The header never reports the live turn's activity** — chips stay
  scoped to the next turn; the stream says what's happening.
