# Fullscreen Chat ("Ask page") — UX & Visual Spec

## Presentation decision

**A dedicated `Window` scene** — `Window("Ask", id: "ask")` in `SearchApp.body`,
beside the existing browser/fluid registrations. It is the established
full-window pattern, gets real macOS fullscreen, survives the browser window
closing, and maps to the rail's "pop-out" affordance. `Mind.shared` is a
singleton and `Browser` is passed as a parameter (`AskPage(browser: browser)`)
— page and rail are two live views on one truth; the same chat open in both is
correct, not a bug.

Window dressing (port the relevant bits of `dress(_:)`):
`titlebarAppearsTransparent = true`, `titleVisibility = .hidden`,
`backgroundColor` = resolved `FluidTone.background`,
`isMovableByWindowBackground = true`, `setFrameAutosaveName("search-ask")`,
min **720×480**, default **980×700**.

Fallback (in-window takeover): a `mind.page: Bool` full-cover overlay with
`.transition(.scale(0.98).combined(with: .opacity))` on `Motion.glide`, Esc/⌘W
close, `chevron.left` "Back to browsing" door. Only deltas noted below.

## 1. Layout — two columns

`FluidSidebarProvider` wrapping `HStack(spacing: 0) { nav; conversation }` —
`FluidSidebar(side: .left, variant: .sidebar, bordered: true, rail: true,
peek: .hover)`. No third column in v1 (phase-2 option in §3.6).

| Element | Value |
|---|---|
| Nav sidebar | default **232** (`Metrics.side`), min 200, max 320, collapseSlop 56, persisted |
| Nav fill | `FluidTone.surface(0)` |
| Center pane | `FluidTone.surface(1)` flat full-bleed — **all FluidTone inside the page**, one palette per surface |
| Conversation column | `.frame(maxWidth: 760)` centered, `.padding(.horizontal, 24)` → measure ≤ 712pt (~80 chars at 14pt) |
| Composer column | same 760 box |
| Turn spacing | `LazyVStack(spacing: 28)` (2× the rail's 14), `.padding(.vertical, 32)` |
| Header band | **52pt** (`Metrics.strip`), padding h16 |

Spacing scale 4pt: 4 within a row · 6 chip/row internals · 8 paragraph→cluster ·
12 between accordion sections · **28 between turns** · 32 stream outer vertical.

## 2. Header — fixed 52pt band

`HStack(spacing: 8)`, `.leading 16 .trailing 12`:

```
[sidebar.left trigger]  [title — click edits in place] [Ring 9 if runningHere]  ···  [share ⌄] [magnifyingglass ⌘F] [square.and.pencil ⌘N]
```

- **Sidebar toggle**: `FluidSidebarTrigger` verbatim.
- **Title — editable in place** (new `AskTitleField`): 15 semibold foreground,
  tail truncation; hover → pencil 9pt muted + r7 hover wash. Click → TextField,
  Return commits `Mind.rename(_:to:)` (exists, unused), Esc reverts,
  empty→"New chat". `Ring(9)` trails while `runningHere`.
- **Right cluster** — three `FluidButton(variant: .ghost, size: .iconCompact)`:
  `square.and.arrow.up` → `FluidMenuPanel` menu: Copy Transcript (existing
  `AskUI.transcript`), **Copy as Markdown** (new formatter), **Share…**
  (NSSharingServicePicker bridge); `magnifyingglass` → transcript find (§10);
  `square.and.pencil` → `mind.newChat()` "New chat ⌘N".
- **No model chip** (composer owns it), **no live-activity reporting**
  (anti-goal).
- **Scroll behavior**: doesn't shrink. Hairline under the band fades in once
  the stream is scrolled (`fadeState.topAlpha < 1`). Header solid `surface(1)`,
  never glass.

In-window fallback adds `chevron.left` "Back to browsing" leftmost.

## 3. Left sidebar

```
FluidSidebarHeader:
  FluidTabs ["Chats", "Automations"]   ← segmented, compact
  (Chats) FluidSidebarInput "Search chats…" magnifyingglass
FluidSidebarContent (FluidScrollArea, fades+dividers built in):
  FluidSidebarMenu { rows }
FluidSidebarFooter:
  Quiet row: gear "Ask Settings" → browser.tuning = true + settings.page="ask"
```

- **Tabs**: `FluidTabs(…, size: .compact)` — muted track r12, surface-4 pill on
  `FluidSpring.moderate`. Automations pane placeholder: `clock.badge` 20pt in a
  48pt `surface(2)` circle, "Automations" 13 semibold, "Scheduled tasks the
  agent runs for you will live here." 12pt muted — honest empty state.
- **New chat**: first menu row = `FluidSidebarMenuButton(variant: .outline,
  size: .regular, icon: "square.and.pencil")` + the header door — both
  affordances survive.
- **Chat rows — `FluidChatRow`, new**: `ChatRow` is `Palette`-painted — the
  one-palette-per-surface rule requires a FluidTone rebuild.
  `FluidSidebarMenuButton(index:, size: .large)` (48pt fits two lines) with
  custom `label:` VStack: title 13pt (ghost-weight embolden via
  FluidSidebarMenuRowLabel) + ago 11pt muted. Active = menu `activeIndex`
  traveling block on `FluidSpring.moderate`. Badges as ChatRow: leading
  `.unread` dot, trailing Ring/questionmark.bubble/`FluidSidebarMenuBadge(n)`
  approvals/`⑂` fork mark. Hover actions: `xmark` delete (immediate) +
  `ellipsis` → Copy Transcript / Rename / Fork / Delete. Select →
  `mind.select(chat)` (stamps `lastSeen`), stream jumps unanimated to end,
  composer focuses. Empty: "No chats yet" 12pt muted.
- **Search field**: always visible — `FluidSidebarInput("Search chats…",
  icon: "magnifyingglass")`; filters title + last message case-insensitive;
  Esc clears.
- **Collapse**: rail click → closed on `FluidSpring.slow`; `peek: .hover` edge
  strip; `[` key toggle built in; `persist: true`.

## 4. Transcript — same components, one density rung up

Introduce **`AskDensity` env** (`rail` | `page`) read by
AskLine/TurnView/WorkedFor/ToolCluster/ShotCard — every size today is a
literal; cheaper than forking the files.

| Element | Rail | Page |
|---|---|---|
| Agent/answer text | 12.5 | **14 regular, lineSpacing 4**, `.textSelection(.enabled)`, AskMarkdown verbatim |
| Accordion paragraph | 12.5 | **13** |
| "Worked for" header | 12 | **13** — ring, label, chevron.right 8 bold, hover wash r8, focusRing 1pt/2pt outset/r10 |
| Cluster header | 11 | **12** — `</>` mono 9.5 bold when `why` |
| ToolRow | mono 10.5/9.5 | **11/10** |
| Meta hover chip | 9.5 | **10.5**, capsule h20 `surface(2)`+hairline, floats in the 28pt gap |
| Notes | 10.5 | **11** centered muted |
| User pill | active fill + border, r14, h10 v7 | **r16 continuous, h14 v9**, max width **560**, trailing, chips strip beneath, "· retried ×N" 10pt faint |
| ShotCard | maxW 132 r8 | **maxW 240 r12**, `muted` placeholder + `FluidRingSpinner(18)`, hairline, tap → `browser.open(fileURL)`, menu: Open in Tab / Copy Image / Reveal in Finder |
| Wide artifact | banner 100–140 | full column r12 `surface(2)`, banner 160, title 14 medium + host 11 muted |
| Accordion indent | unchanged | unchanged — the rhythm scales |

Accordion semantics verbatim from sidebar-ux: live open + ticking (1s
TimelineView), settle keeps user state, new `.you` folds priors, cold open
closed, nested clusters closed by default, folded-live line,
"Waiting on you — Ns".

## 5. Composer

`FluidInputMessage(size: .default)` — 14pt/20pt lines, 1–8 lines, card pad 8,
r12 `FluidShape.rounded.container`, `surface(2)` fill, edge-ring states.
Centered in the 760 column, `.padding(.top, 12) .padding(.bottom, 16)`.

- **header slot**: takeover warning verbatim, chips row (context Chips +
  AttachChips + dashed `+tab`), SiteRow, @-list ↑↓/Esc.
- **Editor**: "Reply, @ for context" / "Answer the agent…" while `asked`;
  `history:` = chat's `.you` texts; optional ghost suggestion
  "Attach {activeTab.title} to give context".
- **Footer**: leading `AttachMenu` + `ModeMenu`; trailing `ModelChip`
  ("provider/model · effort ⌄" — StatusChip scaled to 11 medium / icon 8.5 /
  chevron 7 / h8 v4); send⇄stop morph `FluidSpring.fast`.
  ⚠️ `ModelChip`/`ModeMenu`/`StatusChip`/`AttachMenu` are `private` inside
  `AskPanel` — lift to file scope or a new `AskChips.swift`.
- **Queue strip**: `FluidInputMessage.queue:` exists unused — optional v2 to
  make a send-while-running queue visibly (needs Mind-side queue state).
- **Approvals/question zone**: `parked` pattern verbatim inside the column.
  Restyle `QuestionCard` onto `FluidAskUserQuestions(embedded:)`.

## 6. Scroll & pin — rail semantics at page scale

- `ScrollViewReader` + `ScrollView(showsIndicators:false)` +
  `LazyVStack{Spacer(minLength:0);…}.defaultScrollAnchor(.bottom)` — pinned
  within 24pt of the bottom.
- **"New activity" pill**: bottom-center of the *conversation column*, 16pt
  above the composer — arrow.down 9 bold + "New activity" 11 medium,
  `surface(3)` capsule + hairline + shadow(10%, r6, y2), entrance scale .9+fade
  on `FluidSpring.fast`.
- Re-pin on pill tap (`Motion.settle`)/send; chat switch → unanimated jump.
- Accordion toggle while unpinned anchors on the toggled row's id.
- **Fades**: top **40pt** (scaled from rail's 32), bottom crisp. The
  `FluidScrollFadeState` + mask pattern ports directly. `FluidScrollArea`
  adoption still blocked on the pin API — don't take it for the transcript yet.

## 7. States

- **Empty**: hero centered — `sparkles` 24 medium muted in a **64pt** circle
  (`surface(2)`+hairline), "Ask Search" **20 semibold**, "Ask about anything,
  or hand the agent a task.\n@ attaches a tab — it can read and drive what you
  give it." **13** muted, three default `Pill`s in a row (`ViewThatFits`→V):
  "Summarize this page" (chips `browser.active` + sends), "What's open?",
  "Open example.com". Pad h40.
- **Streaming / awaiting / error / no-engine**: rail patterns verbatim at page
  type. Error card ports `Color.red.opacity` → `FluidTone.destructive`/
  `destructiveLight`. ModelChip label `destructive`-tinted while
  `mind.engine == nil`. Page must call `Harness.shared.attach()` on appear +
  the DEBUG `demoCards/demoAttach/demoStream` hooks.

## 8. Motion table

| Motion | Animation |
|---|---|
| Message/section entrance | `FluidSpring.moderate` — y+8, scale .96→1 |
| Accordion/cluster toggle | `FluidSpring.fast` chevron, `FluidSpring.moderate` height |
| Streaming text | none — deltas append, new section fades 120ms |
| Ring | `linear(0.85)` repeat |
| "Working" shimmer | `fluidShimmerSweep` 1.5s — off when quiet/reduce-motion |
| Hover/pressed | `easeOut 0.08` |
| Send⇄stop | `FluidSpring.fast` morph |
| New-activity pill | `FluidSpring.fast` scale .9+opacity |
| Menus/tooltips | `FluidSpring.fast` |
| Chat switch | `Motion.quick` crossfade |
| Sidebar width | `FluidSpring.slow` open / 0.16 close (built in) |
| Approvals zone | `FluidSpring.moderate` |

## 9. Light/dark risks

- Big `surface(1)` field: dark fine; **light is the risk** — nav `surface(0)`
  (#FAFAFA) vs center `surface(1)` (#FCFCFC) separated by one `border`
  hairline — the Settings panel's two-tone recipe.
- Shot placeholder: consider `surface(2)` for parity.
- `.you` pill: `active` = 7% black — correct on light (documented choice).
- No shadows in stream except the jump pill's.
- Error card → `FluidTone.destructive`/`destructiveLight`.
- Appearance via `FluidTone.dynamic` + `Look.apply()` — free agreement.

## 10. Keyboard

`.commands` are app-global on the browser scene — the Ask window needs its own
`AskKeys` layer / `CommandMenu("Chats")` gated on key-window.

| Key | Action |
|---|---|
| `⌘N`/`⌘⇧N` | New chat |
| `⌘W` | Close window |
| `⌘F` | Transcript find — `AskTranscriptFind` capsule (FindBar-shaped, FluidTone reskin) pinned top-trailing; "n of m" + chevrons + ×; v1 jumps turn-to-turn |
| `⌘K` | Chat switcher — `FluidCommandMenu` (exists, unused) |
| `⌘.` | `mind.stop()` while `runningHere` |
| `[` | sidebar toggle (free) |
| Esc cascade | find → @-list → siteDraft → composer blur; **never closes the window** |
| Return/⇧Return/↑/Tab | composer contract verbatim |
| `⌘⇧A` | rail toggle stays global — no-op visually in the Ask window |

## 11. Accessibility

- Focus order: sidebar trigger → search → New-chat → chat rows (roving focus) →
  header (title, share, find, new) → transcript region → accordion/cluster
  headers (`.isHeader`+value — exists) → approvals zone → composer editor →
  attach/mode/model chips → send/stop.
- VoiceOver: Ring "Working"; accordion live→"Working"/"Worked" + value (exists);
  user pill "You said"; answer "Search answered"; shot "Screenshot, opens in a
  tab"; pill "New activity — jump to latest"; row actions labeled.
- Reduce motion: shimmer off; chevrons crossfade; entrances fade-only;
  highlight travel off; sidebar instant; Ring stays (it is status).
- `textSelection` everywhere including accordion contents.
- Fixed point sizes are app convention — flagged, not solved.

## 12. Reuse map

**Verbatim**: `FluidSidebar`+Provider+Trigger+State+peek; `FluidSidebarMenu`/
MenuButton/Badge/Actions/Skeleton; `FluidSidebarContent/Input/Header/Footer`;
`FluidTabs`; `FluidInputMessage(.default)` + `FluidComposerEditor`; `FluidMenu`/
MenuPanel/MenuSearch; `FluidTooltip`; `FluidCommandMenu`;
`FluidAskUserQuestions(embedded:)`; `FluidChatMessage` entrance; all of
AskTurn internals (`TurnView`/`WorkedFor`/`ToolCluster`/`WorkSection`/
`ShotCard`/`AnswerLine`/`ErrorNote`/`AskMarkdown`/`AskTurns`); `AskLine`;
`ApprovalCard`/`QuestionCard`/`QuestionRow`; `Chip`/`AttachChip`/`AttachMenu`/
`SiteRow`; `AskUI.transcript`/`ago`/`copy`/`oneline`; all of `Mind`.

**New components**:
1. `AskPage` root + `Window("Ask", id:"ask")` + dress-lite.
2. `AskNavRail` — sidebar composition.
3. `FluidChatRow` — FluidTone two-line row.
4. `AskTitleField` — inline rename (plumbs `Mind.rename`).
5. `AskTranscriptFind` — find capsule + scrollTo plumbing.
6. `AskDensity` env + threading through the literals.
7. "Copy as Markdown" formatter + NSSharingServicePicker bridge.
8. Lift `ModelChip`/`ModeMenu`/`StatusChip`/`AttachMenu` out of `AskPanel`'s
   private scope → `AskChips.swift`.
9. Automations pane placeholder.
10. Page-scoped command layer + key-window tracking.

**Watch items**: `FluidSidebarState` persistence keys are global — a second
persisted `FluidSidebar` would collide; `Mind` is a singleton — page and rail
share `currentID` (the design: two surfaces, one cursor); move the DEBUG demo
hooks somewhere both surfaces share.

## 13. Reviewer checklist

- [ ] Own `Window` scene; ⌘W closes, green-light fullscreen, "search-ask" autosave
- [ ] Nav FluidSidebar 232/200/320, rail+`[`+hover-peek+persisted, surface(0)/surface(1) + hairline
- [ ] FluidTabs Chats/Automations + honest Automations empty state
- [ ] Chat search filters title + last message
- [ ] `FluidChatRow` two-line: traveling active block, ring/question/approval-count/unread/fork badges, hover delete + menu
- [ ] Header 52pt: trigger, editable title (Return→rename, Esc reverts), Ring while runningHere, share menu, find, new chat; hairline only when scrolled; no model chip
- [ ] Transcript 760 centered pad 24, turns 28, page type ramp (14/13/12/11-10/10.5)
- [ ] User pill r16 h14v9 active+border max 560; accordion/shot semantics identical to rail
- [ ] Shot cards maxW 240 r12; wide artifacts full-column r12 surface(2)
- [ ] Composer `FluidInputMessage(.default)` centered, pad t12 b16; all slots wired
- [ ] Scroll: defaultScrollAnchor(.bottom), 24pt pin, New-activity pill on column, top fade 40, bottom crisp, no indicators
- [ ] Empty hero; destructive/destructiveLight error card; engine-missing chip tint
- [ ] Motion table honored; reduce-motion variants
- [ ] Keys: ⌘N/⌘F/⌘K/⌘./[/Esc cascade stops at blur
- [ ] Focus order; `.isHeader`+expanded; icon-only controls labeled
- [ ] No `Palette.*` inside the page; `FluidChatRow` replaces transplant
- [ ] `Harness.shared.attach()` + DEBUG hooks fire on appear
- [ ] `AskDensity` env threads both ramps; no forked internals
- [ ] Anti-goals hold: no boxed accordion, no markdown on .you, no avatars,
      no typing dots, no accent color (focusRing excepted), no stream shadows
