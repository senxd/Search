# New-tab start page — chats & automations on the blank tab

Repository state: a blank tab renders `WebStage(page: nil)` over bare
`Palette.ground` (Stage.swift:24 — the `tab.isBlank || tab.asleep ||
tab.floating` gate), and the only thing on it is the Omnibox — mounted by
`ContentView.field` (App.swift:507-518) into `.overlay { field }`
(App.swift:577). `browser.fieldShowing` is `editing || active?.isBlank`
(Browser.swift:130), so on a blank tab the field is always there, raised
60pt above centre (Omnibox.swift:50), 560 wide (Metrics.fieldWidth,
Design.swift:136), with the suggestions list hanging under it at
`offset(y: fieldHeight + 8)` (Omnibox.swift:37-46).

This spec adds the two Ask content types — recent chats and routines —
as card sections under the field, wired to the Ask window. It is WS4;
the rail (AskPanel, AskUI.swift:75), the Ask window (AskPage +
`Window("Ask", id: "ask")`, App.swift:239-244), and the routines board
(AskRoutines.swift) already exist. automation-frontend §7 names the
RoutineCard half of this; this file is the whole of it.

## Facts that shape it

- **`fieldShowing` vs `over`.** `Omnibox(browser:over:)` draws in two
  modes: `over == true` (⌘L raised above a real page — dimmer +
  tap-to-dismiss, Omnibox.swift:23-30) and `over == false` (the blank
  tab's standing field). The shelf belongs to the second mode only —
  `over` is already the right gate (`!(browser.active?.isBlank ?? true)`
  at App.swift:510).
- **The offers list owns the anchor.** `browser.offers` is non-empty
  whenever typing produced suggestions (`guess()`, Browser.swift:1932)
  and for the whole of a ⌘K summon (`summon()` fills `offers` from
  `openPages`, Browser.swift:1923-1930 + 1971-1992). On a blank tab at
  rest `typed == ""` → `offers == []` (Browser.swift:1942-1947). The
  shelf shows exactly while `offers` is empty — same value the list's
  animation already keys on (Omnibox.swift:56), so list-in and
  shelf-out ride one `Motion.quick`.
- **Typing already lands in the field.** `newTab()` clears `typed`,
  leaves `editing = false`, bumps `focusRequest` (Browser.swift:1115-1117,
  1126-1128); `AddressField.updateNSView` turns the bump into first
  responder + select-all (Omnibox.swift:302-316). Cards never take key
  focus: plain Buttons, no keyboard nav in v1.
- **Esc on a blank tab is already a no-op.** The cascade ends at
  `guard browser.editing, browser.active?.isBlank == false` (App.swift:995).
  The shelf adds no Esc rung.
- **The deep-link recipe exists.** fullscreen-features §1: `mind.select(chat)`
  + `openWindow(id: "ask")`. `openWindow` is reachable inside the browser
  scene — the rail's pop-out door does it (AskUI.swift:88, 170), and the
  shelf mounts inside that scene.
- **`RoutinesUI.select` is half a route.** It is `{ _ in }` until
  `AskPage.bindKeys()` assigns it at dress (AskRoutines.swift:345-347,
  AskPage.swift:290-295), it goes through the dirty-form guard
  (`requestRoutine`, AskPage.swift:301-309), and it does **not** flip the
  sidebar tab or raise the window. `ask.page.tab` is the persisted tab
  (AskPage.swift:58 init, :184 write-through `onChange`). Both are real
  but neither alone deep-links a routine from outside.
- **One cursor.** `mind.select` stamps `lastSeen` on both surfaces
  (Mind.swift:722-729 via markSeen :702-707); a card click *is* a look —
  the unread dot clearing on open is the nav row's own contract.
- **Data is already in memory.** `Mind.init` reads `AskStore.list()`
  (Mind.swift:545-548); `Routines.shared.start()` runs from `Browser.init`
  (Browser.swift:782). No I/O per ⌘T.
- **Observing the singletons from the browser layer is the house
  pattern** — `ContentView` observes `Mind.shared` (App.swift:311),
  `AskPage` observes both (AskPage.swift:52-53). Rule for this feature:
  only the leaf card/section views observe `Mind`/`Routines` — never
  `Omnibox` or `ContentView` — or every streamed token (chats mutate per
  delta, Mind.swift:781-787) redraws the whole field overlay.

## 1. Feature set

Two sections under the field, same 560 column:

**CHATS** — `mind.chats.prefix(cap)`, order as stored (`when` desc is
maintained by `store()`, Mind.swift:1133-1141). Card anatomy
(~62pt, `FluidCard` inside a 2-col `FluidCardGroup`):

- Line 1: unread dot (leading, the `FluidChatRow` rule — `chat.id !=
  mind.currentID && !chat.messages.isEmpty && chat.lastSeen !=
  chat.messages.last?.id`, AskPage.swift:756-759), title 13pt medium
  tail-truncated, `AskUI.ago(chat.when)` 10pt muted trailing.
- Line 2: last substantive line — `AskUI.oneline` of the last message
  with `role != .note` (notes are verdict chrome, not content),
  11.5pt muted, `lineLimit(1)`.
- State, trailing of line 1 or end of line 2: `Ring(size: 9)` while
  `chat.id == mind.runningChatID`; `questionmark.bubble` while
  `mind.question?.chat == chat.id`; parked-approval count capsule
  (the AskPage badge idiom, AskPage.swift:325-336 — not
  `FluidSidebarMenuBadge`, which reads `fluidMenuRow` env and is sized
  to `MenuGutter.slot`, FluidSidebarMenu.swift:892-909); `⑂` when
  `chat.parent != nil`.

**AUTOMATIONS** — routines, attention-first (the new tab is a glance
surface, not the createdAt-asc list `Routines.routines` keeps,
Routines.swift:394-395): runs needing a person first (`running`/`waiting`/
`queued`, newest `queuedAt` first), then unacknowledged-terminal, then
enabled by soonest `nextRunAt`, paused last. Cap `cap`. Card anatomy:

- Line 1: name 13pt medium + state glyph — `Ring(9)` running/queued,
  amber `exclamationmark.circle.fill` waiting (RoutineUI.amber,
  AskRoutines.swift:39), `RunStateChip(.sm)` is the alternative for
  terminal state (AskRoutines.swift:74-91); pick the glyph for live,
  chip for failed ("Failed" + ago).
- Line 2: `routine.schedule.sentence` 11pt muted (AskRoutines.swift:16-32).
- Line 3 (or merged into 2): the `RoutineRow.statusLine` equivalent —
  live `run.activity`/"Waiting on you"/"Queued", else `Failed {ago}`,
  else `RoutineUI.nextLine(routine)` ("Next in 3h"/"Paused"/"Not
  scheduled", AskRoutines.swift:58-62). Lift `RoutineRow`'s private
  `liveRun`/`unacknowledged`/`statusLine`/`statusColor`
  (AskRoutines.swift:220-339) into a small `RoutineStatus` helper both
  views share — do not fork them.
- Unacknowledged count capsule, trailing (same idiom as chats).

Counts: `cap = 4` (2×2) at full height; collapse rules in §2. "See all"
on each section header, trailing — 11pt muted label ("All chats ⌄" /
"All routines ⌄") that opens the Ask window on that tab without a
forced selection (landing on Automations with nil selection already
picks the first routine — AskPage.swift:179-181, 191-193 — so nil is
the right argument).

Empty-state behaviour — deliberately sparse:

- No chats AND no routines → **nothing mounts.** The blank tab is
  byte-identical to today; its emptiness is a feature, and Ask
  discovery already lives in the Ask button (AskUI.swift:14-68) and the
  Welcome sheet.
- One kind empty → only that section shows (a chat-less install with
  routines shows just AUTOMATIONS, and vice versa).
- No per-section dismiss in v1 — sections exist only when they have
  content, so they are self-justifying. P1 adds Settings › "Show Ask
  and Automations on new tabs" (`prefs.newTabCards`, read
  `store.object(forKey: "newtab.cards") as? Bool ?? true` — the
  `sleepsTabs` default-true idiom, Prefs.swift:246).

Hard gates, all four: `!over` (blank tab, not ⌘L-over-page) ·
`browser.offers.isEmpty` (no list/summon) · `!(browser.active?.shy ??
false)` — a private tab keeps nothing and shouldn't surface profile
content (chat titles, routine names) on its stage. *Flag for review:*
`guess()` still offers history on a shy tab, so precedent cuts the other
way; hiding is the conservative default. · `browser.prefs.ask` — the
feature's off switch (Prefs.swift:215-217); cards are its content.

## 2. Layout

```
                    ┌────────────────────────┐
                    │  AddressField          │  ← field, centre −30pt
                    └────────────────────────┘       (Omnibox.swift:50)
   CHATS                                                All chats ⌄
   ┌──────────────┐ ┌──────────────┐
   │ · Title   4m │ │ ◌ Title   1h │    cap 4 → 2×2
   │ last line…   │ │ last line…   │
   └──────────────┘ └──────────────┘
   AUTOMATIONS                                          All routines ⌄
   ┌──────────────┐ ┌──────────────┐
   │ Digest   ⟳   │ │ Report  Paused│
   │ Daily · 9:00 │ │ Weekly · Mon │
   │ Next in 3h   │ │ Failed 2d ago │
   └──────────────┘ └──────────────┘
```

- **Mount**: inside `Omnibox`, a second `.overlay(alignment: .top)` on
  `field` beside the existing `list` one (Omnibox.swift:37-46) —
  `NewTabShelf(browser:)` at `offset(y: Self.fieldHeight + 28)`,
  `frame(width: Metrics.fieldWidth)`. Anchoring to the field shares its
  centering and its `sidebar ? sideWidth : 0` / `rail ? 380 : 0` pads
  (App.swift:514-515) for free, and never moves the field — the list's
  own bargain.
- **Section**: 10pt semibold muted header (the PROMPT/RUNS idiom,
  AskRoutines.swift:579, :604), gap 6, then
  `FluidCardGroup(columns: 2, separated: true, outlined: true,
  count: n)` — separated+outlined makes each card its own hairline tile
  (FluidCard.swift:197-202); the group's `fluidHover` glides the
  highlight across cards (xy axis comes free, FluidCard.swift:74).
- **Vertical budget.** Field bottom ≈ H/2 − 5; shelf top ≈ H/2 + 23;
  `avail` = the shelf container's own measured height
  (`onGeometryChange` on the overlay — the Fluid.swift:330 idiom, no
  GeometryReader). Tiers on `avail`:

  | avail | chats | routines |
  |---|---|---|
  | ≥ 360 | 4 (2 rows) | 4 (2 rows) |
  | 200–359 | 2 | 2 |
  | 100–199 | 2 | hidden — Automations yields first: chats answer "what was I saying", the field's own mode; routines are ambient and stay reachable via the Ask window |
  | < 100 | shelf off | — |

  Section ≈ header 16 + gap 6 + row 62 (+ row 62 + gap 8); section gap
  18. Defaults check: H=780 → avail ≈ 337 → 2+2 rows fits (330).
  H=420 min → avail ≈ 187 → chats one row only. Numbers are tuned
  constants — collect them at the top of the view.
- **Narrow windows**: none — min width 640 > 560 (App.swift:25), and
  sidebar-mode left padding rides the field's.
- **While typing**: the shelf is gone the moment `offers` is non-empty
  (gate §1), so cards never sit under the list. The swap animates on
  `browser.offers.isEmpty` — the same animation Omnibox already runs
  (Omnibox.swift:56) — one ~140ms crossfade at the shared anchor.
- **Keyboard**: unchanged. Field holds first responder; typing, arrows,
  Return, Tab-accept all route through `AddressField.Coordinator` and
  `take()` untouched. Esc stays a no-op on blank tabs. v1 gives cards no
  key path (↓-into-cards is P2 at most).
- **Entry motion**: the shelf is inside `field`'s overlay → it rides the
  `.scale(0.97)+opacity` appear on `Motion.settle` (App.swift:516, 582).
  Content swaps (chat activity, run state) fade on `Motion.quick`, no
  travel.

## 3. Routing — the contract

Both card kinds land on the **Ask window**, not the rail — decided, and
why:

- Routine cards have no choice — Automations lives only there.
- Uniform destination: every card means "open the Ask surface", one
  window, one cursor. The rail is the ambient companion; the new tab is
  a launchpad.
- The recipe is already written down (fullscreen-features §1
  `mind.select` + `openWindow(id:"ask")`), and the rail's chat list is
  private `@State listing` (AskUI.swift:86) — not a route.
- Cheap to flip if review prefers the rail for chats: `mind.select` +
  `mind.open = true` (persists `ask.open`, Mind.swift:470-472). The rail
  needs no `hand(browser.active)` — a blank tab fails its own guard
  (Mind.swift:627).

New controller surface on the existing `AskWindow` enum
(AskPage.swift:15-45 — it is already the window's static-closure
registry: `find`, `switcher`, `newChat`, `stop`, `escape`):

```swift
enum AskWindow {
    /// Cold-open intent — set before `openWindow`, consumed once by
    /// bindKeys at dress. Reopen builds a fresh AskPage, so the same
    /// consume path serves a closed window every time.
    static var pending: Pending?
    struct Pending {
        var tab = 0                 // 0 Chats, 1 Automations — ask.page.tab
        var routine: UUID? = nil    // Automations selection
        var newRoutine = false      // land on the create form
    }
    /// Warm path — AskPage registers it in bindKeys like the key
    /// closures. Flips the tab (which self-persists via the existing
    /// onChange, AskPage.swift:183-184) and routes the selection through
    /// the dirty-form guard.
    static var show: (_ tab: Int, _ routine: UUID?, _ newRoutine: Bool) -> Void = { _, _, _ in }
}
```

In `bindKeys()` (AskPage.swift:204-296), beside the existing
`RoutinesUI.select` assignment (:290-295):

```swift
AskWindow.show = { tabID, routine, makeNew in
    tab.wrappedValue = tabID
    if makeNew { self.requestRoutine { routineDraft.wrappedValue = RoutineDraft() } }
    else if let routine { RoutinesUI.select(routine) }
}
if let pending = AskWindow.pending {
    AskWindow.pending = nil
    AskWindow.show(pending.tab, pending.routine, pending.newRoutine)
}
```

(Pending consumed in `bindKeys`, not `onAppear`: `WindowSetup.ready`
fires after `viewDidMoveToWindow` via async (Stage.swift:264-270), so it
runs after onAppear's first-routine pick and overrides it cleanly —
`requestRoutine` won't ask, nothing is dirty yet.)

The card-side helper (in the new view file), taking the scene's
`@Environment(\.openWindow)`:

```swift
func openAsk(tab: Int, routine: UUID? = nil, newRoutine: Bool = false,
             openWindow: OpenWindowAction) {
    if AskWindow.window != nil {
        AskWindow.show(tab, routine, newRoutine)
    } else {
        Store.settings.set(tab, forKey: "ask.page.tab")   // cold dress reads it (AskPage.swift:58)
        AskWindow.pending = .init(tab: tab, routine: routine, newRoutine: newRoutine)
    }
    openWindow(id: "ask")
    AskWindow.window?.makeKeyAndOrderFront(nil)   // belt; openWindow raises an existing window — the bench's own trick (Bench.swift:1460)
}
```

Call sites:

| Affordance | Call |
|---|---|
| Chat card | `mind.select(chat)`; `openAsk(tab: 0)` — selection rides `mind.currentID` (one cursor); AskPage's `onChange(currentID)` focuses the composer (:197) |
| Routine card | `openAsk(tab: 1, routine: routine.id)` |
| All chats ⌄ | `openAsk(tab: 0)` |
| All routines ⌄ | `openAsk(tab: 1)` — nil selection → first-routine pick already handled |
| "+ New routine" door (P1, on the Automations header) | `openAsk(tab: 1, newRoutine: true)` |

`mind.select` side effects are all wanted: `markSeen` on both chats,
`pushMode` re-leash — identical to a nav-row click.

## 4. Backend needs

- **New**: only the `AskWindow.pending` + `AskWindow.show` pair above,
  plus ~10 lines in `bindKeys`. No model, store, or schema changes.
  `Mind`/`Routines` need nothing — every read is existing published
  state (`chats`, `currentID`, `runningChatID`, `question`,
  `pendingApprovals`; `routines`, `runs(of:)`, `lastRun(of:)`, `badge`).
- **Lift (small)**: `RoutineRow`'s status computation → shared
  `RoutineStatus` helper (`liveRun`, `unacknowledged`, `statusLine`,
  `statusColor`), so the card can't drift from the row.
- **Verify at build**: `openWindow` inside `Omnibox`'s subtree — proven
  pattern (AskPanel's door), but confirm the env resolves on the
  overlay path the same way.
- **Observation rule** (repeated because it's the whole perf story):
  `@ObservedObject Mind.shared`/`Routines.shared` on the card views
  only. `Omnibox`/`ContentView` must not gain them.

## 5. Fluid reuse map

- **Cards/grid**: `FluidCardGroup(columns:separated:outlined:count:)`,
  `FluidCard(index:onClick:)` + custom VStack content
  (`FluidCardHeader`/`FluidCardContent` optional — the anatomy is custom
  enough to lay out directly inside `FluidCard`).
- **Status**: `RunStateChip` (exists verbatim), `Ring(size: 9)`,
  `RoutineUI.amber`, count capsule built like AskPage.swift:325-336.
- **Section chrome**: 10pt-semibold-muted header + a plain ghost text
  button for "All ⌄" (not `Pill` — it's `Palette`-painted,
  Settings.swift:802; not `FluidSidebarMenuBadge` — menu-scoped).
- **Text**: `AskUI.ago`, `AskUI.oneline`, `When.said`,
  `RoutineUI.nextLine`, `schedule.sentence`.
- **Routing**: `RoutinesUI.select`, `Store.settings` `ask.page.tab`,
  `openWindow(id: "ask")`, `AskWindow` statics.
- **New file**: `Sources/Search/NewTab.swift` — `NewTabShelf`,
  `NewTabSection` (header + group), `ChatCard`, `RoutineCard`
  (the name automation-frontend.md:159 already reserves),
  `openAsk(...)`. Mounted from `Omnibox` — one line plus the gate.
- **Tones**: cards draw `FluidTone` (card fill/hairline/foreground)
  over the `Palette.ground` stage — same mix the rail already makes
  (`surface(1)` over the stage, AskUI.swift:103). Dark: ground 0.11 vs
  `FluidTone.background` #17 are a half-step apart; the card hairline +
  `FluidTone.card` lift carry the separation. `Ring` strokes
  `Palette.muted` — shared chrome, fine.

## 6. Risks

- **⌘T cost**: nil at rest — both lists are in-memory, `prefix(cap)` +
  `oneline` is text work on ≤8 items. `Ring` spins only while something
  runs (and only on the cards that show it). **No `TimelineView` in
  cards** — `RoutineRow` carries `run.activity` text, not an elapsed
  clock; keep `ElapsedLine` on the detail page (AskRoutines.swift:727).
  `Breath` continues underneath, untouched.
- **Stale "Next in 3h"**: computed at draw; `Routines`' 30s `scan()`
  republishes on schedule changes, and any run mutation redraws the
  card. A card on a blank tab left open an hour stales by minutes —
  same contract `RoutineRow` keeps; acceptable.
- **Live previews**: a streaming chat's last line updates its card live
  (published `chats`) — free and wanted; it's also why the leaf-observing
  rule matters.
- **First run**: nothing to show → identical blank tab. No hero, no
  teaching moment — the Ask button and Welcome own that.
- **Shy tabs**: shelf hidden (§1 gate 3). Flagged — history suggestions
  still complete on shy tabs, so the inconsistency is already in the
  app; this spec takes the conservative side, reviewer may flip.
- **Crossfade at the anchor**: shelf-out/list-in share one 140ms
  `Motion.quick` on `offers.isEmpty` — brief overlap at offset +28 vs
  +8; acceptable, keep both on the same value.
- **`RoutinesUI.select` dead until dress** — the reason `pending`
  exists; test the cold path (quit Ask window, click routine card).
- **`ask.page.tab` writes**: a card click writes the pref — the same
  write a real tab tap makes (:184); intended, not a leak.
- **Asleep/floating/immersed tabs**: not blank → no shelf; `Bench` tabs
  (`tab.bench`) are never the user-facing blank either — no gate needed,
  but note `Tab.bench` exists if a probe shows bench blanks.
- **Extension new-tab pages**: `Extensions.shared.newTabPage` /
  `offerNewTabPage` replace the blank (Browser.swift:1096-1102, 1130,
  `replaceBlank` :1136) — the tab stops being `isBlank`, the shelf
  never mounts; no conflict.

## 7. Priorities

- **P0** — `NewTabShelf` mounted on `field` with the four gates
  (`!over`, offers empty, `!shy`, `prefs.ask`); `ChatCard` with
  title/preview/ago + unread·running·question·approvals·⑂ badges;
  `RoutineCard` via the lifted `RoutineStatus`; ordering + cap tiers;
  routing: `AskWindow.pending`/`show` + `bindKeys` wiring + `openAsk`
  helper; chat click → Chats tab selected; routine click → Automations
  tab + routine; identical blank tab when both empty.
- **P1** — "All chats ⌄"/"All routines ⌄"; "+ New routine" header door
  (`pending.newRoutine`/`show`'s third param); Settings toggle
  `newtab.cards` (default on, `object(forKey:) as? Bool ?? true`);
  VoiceOver composed labels (RoutineRow's `:323-324` pattern); reduce-
  motion — Ring stays (it is status), entry fades only.
- **P2** — ⌥-click / context menu "Open in rail" (`mind.open = true`);
  dashed "New routine" starter tile when the section would be empty but
  chats exist; ↓-from-field into the card grid; elapsed ticking on a
  running card; per-section collapse persistence (if anyone asks — skip
  until they do).

## Reviewer checklist

- [ ] Shelf mounts only on a real blank tab: `!over && offers.isEmpty
      && !tab.shy && prefs.ask` — ⌘L-over-page, ⌘K summon, shy blank,
      Ask-off all bare.
- [ ] Field unchanged: 60pt lift, 560 wide, refusal shake, list at +8.
- [ ] Chat card → `mind.select` + Ask window on Chats; routine card →
      Automations + that routine — **both verified warm and cold**
      (closed window path consumes `pending` in `bindKeys`).
- [ ] Dirty routine form still gets "Discard changes?" — selection goes
      through `requestRoutine`, never a bare `routineID` write.
- [ ] `ask.page.tab` pref only written when a card flips it — and only
      on the cold path (warm path self-persists via `onChange`).
- [ ] `RoutinesUI.select` not called before first dress (pending
      covers it); `AskWindow.show` noop-safe.
- [ ] No `@ObservedObject Mind/Routines` on `Omnibox` or `ContentView`;
      ⌘T + streaming-turn cost is leaf-deep.
- [ ] Badge parity with `FluidChatRow`/`RoutineRow`: unread dot, Ring,
      questionmark.bubble, approval count, ⑂; running/waiting/
      unack/failed/paused; `RoutineStatus` shared, not forked.
- [ ] Height tiers honoured at 640×420 (chats one row, automations
      hidden) and at default 980+ (2×2 both).
- [ ] Esc/Tab/Return/tab-keys untouched; cards never take first
      responder; cards out of Full-Keyboard-Access order is acceptable,
      labelled if reachable.
- [ ] No `TimelineView` in cards; `ElapsedLine` stays on the detail page.
- [ ] Probe path: `bench routine demo` (Routines.swift:978) +
      `ask.demostream` seed both sections; `bench ui askwindow`
      (Bench.swift:1452) still dresses/keys; `AskWindow.take` gains no
      rungs.
- [ ] No `Palette.*` inside card bodies (FluidTone only); `Ring`/`⑂`
      shared-chrome exception noted.
- [ ] First launch on a fresh world: identical blank tab.
