# Fullscreen Ask Page — Feature-Set Scope

Companion to `fullscreen-ux.md` (visuals). This covers features and wiring.

## 0. Corrections to the UX spec

- `AttachMenu` is already file-scope public (`AskAttach.swift:200`), as are
  `AttachChip` and `SiteRow`. The private types to lift are `ModelSelector`,
  `ModelChip`, `ModeMenu`, `StatusChip` (nested inside `AskPanel`), plus
  file-private `Chip`, `AttachRow` → new `AskChips.swift`.
- `Mind.rename` is not entirely unused — `send()` auto-titles through it; it's
  just unwired to UI.
- The `(queued: …)` steer echo is already fixed — harness.js emits it as
  `activity`, not `delta`.
- Stray `print("SBDBG …")` at `FluidSidebar.swift:168` — flag for removal.

## 1. Hosting & lifecycle — P0

- `Window("Ask", id: "ask")` beside the two existing scenes. `AskPage(browser:
  browser)` takes the shared `@StateObject`. Single-window scene — `Mind` is a
  singleton, one cursor.
- Dress via `WindowSetup` (Stage.swift:241 pattern): `titlebarAppearsTransparent`,
  `titleVisibility = .hidden`, `backgroundColor` = resolved
  `FluidTone.background` (NOT `Palette.NS.ground`),
  `isMovableByWindowBackground = true`, `setFrameAutosaveName("search-ask")` —
  **namespaced per test world** like `dress` does (`Store.world.map {
  "search-ask (\($0))" } ?? "search-ask"`) or probe runs fight over the frame.
  Min 720×480, `.defaultSize(width: 980, height: 700)`.
- Deep-link: `mind.select(chat)` + `openWindow(id: "ask")`. No `Window(for:)`.
- Entry points: rail header door (third door beside new-chat/close —
  `arrow.up.right.square`/`macwindow`), menu command `Button("Ask Window")` on
  the browser scene (precedent: `openWindow(id: "fluid")`). `mind.open` stays
  the rail's flag; ⌘⇧A toggles the rail only.

## 2. Feature parity — extraction, not copying

Everything in `AskPanel` is private state + private views. The parity path is
**extraction** — otherwise takeover warning, accordion fold state, and pin
behavior drift between surfaces.

| Feature | Port |
|---|---|
| Turn stream (AskTurns.split → TurnView family) | Reuse verbatim + `AskDensity` env (rail default) threaded through literals |
| Scroll: pin, atBottom, New-activity pill, pinToEnd, top fade | Extract shared `AskStream`/`AskTranscript` (spacing/fade via density) |
| `openTurns`/`foldedTurns` + settle-keeps-open + new-.you-folds | Owned by the shared view |
| Composer (FluidInputMessage + history + send⇄stop + per-chat draft) | Extract `AskComposer` |
| @-attach list, chips row, +tab suggestion, SiteRow, AttachMenu | Inside `AskComposer`'s header slot verbatim |
| Takeover warning + 6s armed clock | In `AskComposer` — identical semantics |
| send/steer/stop/retry/fork/select | Mind-level — free |
| ModelChip/ModeMenu/StatusChip | Lift → `AskChips.swift`; Settings… opens `browser.tuning` + `settings.page="ask"` (sheet draws on the browser window — it activates itself) |
| parked zone (ApprovalCard + QuestionCard) | Shared; page may restyle QuestionCard → `FluidAskUserQuestions(embedded:)` |
| Empty state | New hero per UX spec; pills wire `mind.hand(browser.active)` + `send` |
| `Harness.shared.attach()` + DEBUG hooks | On `AskPage.onAppear` — hoist to `Mind.demoHooks(browser)`/`AskSurface.wake` shared by both appears |
| `openURL` → `browser.open` | Same env override at `AskPage` root |
| Chat CRUD, unread dots, lastSeen, ⑂, badges | Rebuild as `FluidChatRow` on `FluidSidebarMenuButton` (custom `label:` VStack, `size: .large` = 48pt) |
| Context menus on rows/cards | Free — ride shared views |
| Retry pill / error card | Shared stream |

**Extraction shape**: `AskPage.swift` holds `AskPage`, `AskNavRail`,
`FluidChatRow`, `AskTitleField`, `AskTranscriptFind`, share menu, Automations
placeholder. Shared `AskParts.swift` (or grow `AskUI.swift`) holds `AskStream`
(scrollBody + pin + pill + fade + orphans/turns + retryable) and `AskComposer`
(FluidInputMessage + header slot + `send()` + `at`/`attachable`/`attach`/
`suggested`/`siteDraft`/`drafts` dict). `AskPanel` becomes `head +
(listing|empty|AskStream) + parked + AskComposer` — rail behavior provably
unchanged because the same code draws it.

## 3. Fullscreen-only additions

| Feature | Mechanics | Priority |
|---|---|---|
| Transcript find (⌘F) | `AskTranscriptFind` capsule top-trailing of column (FindBar shape, FluidTone). v1: match turns by blocks/you/notes → scrollTo(turn.id) chevrons + "n of m"; Esc closes (first Esc rung). Needs stream's proxy or a coordinator. | P1 |
| Chat switcher (⌘K) | `FluidCommandMenu` hosted in `.fluidDialog(position: .top, showCloseButton: false)` — items per chat (title + ago + last-message keywords + state icon) + "New Chat". | P1 |
| Inline rename | `AskTitleField`: tap → TextField, Return → `Mind.rename`, Esc reverts, empty → "New chat". | P0 |
| Row rename | menu "Rename…" → inline field or `Ask.name` helper (Spaces.swift precedent). | P1 |
| Share/export | ghost iconCompact + `.fluidMenuPopup`: Copy Transcript / **Copy as Markdown** (new `AskUI.markdown(_:)`: `#` title, `.you` blockquote, agent verbatim, tools bulleted, notes italic) / Share… (`NSSharingServicePicker` via FluidAnchorResolver pattern). | P1 |
| Chat search | `FluidSidebarInput("Search chats…")` in `FluidSidebarHeader`; filter title + last message, case-insensitive; Esc clears. | P1 |
| Sidebar persist | `FluidSidebarProvider(persist: true, …)` — **collision fix first**: persist keys are global statics (`fluid.sidebar.state`/`width`) and write `UserDefaults.standard`, not `Store.settings` — add a `persistKey` prefix (`ask.nav`) so worlds don't share and a second sidebar doesn't collide. | P0 (with namespacing) |
| ⌘-keys | Scene commands + `take()` window gate (§6). | P0 |
| Queue strip | `FluidInputMessage.queue:` unused; needs Mind-side queue state — v2. | P2 |
| FluidTabs | `["Chats","Automations"]` compact; see §5. | P1 |
| Delete confirm | Keep parity — immediate delete, no dialog. | n/a |
| Shot-card Peek float | Unbuilt everywhere; `browser.open(fileURL)` suffices. | skip |

## 4. Chat management

- Rename: `Mind.rename(_:to:)` exists → header field (P0) + row menu (P1).
- Delete: `mind.remove(chat)` — running-stop, currentID fallback, grant
  revocation, pending-ask cleanup all handled. Hover-`xmark` + menu item.
- Fork: `mind.fork(from:)` — rail does select-then-fork; port verbatim.
  `chat.parent != nil` → `⑂`.
- Duplicate: fork IS the clone — don't add.
- Sorting: `store()` bumps `chat.when`; `mind.chats` arrives sorted.
- Unread: `select()` stamps `lastSeen`; shared cursor → selecting in one
  surface marks read in both (intended).
- `FluidChatRow` badges: Ring/questionmark.bubble/`FluidSidebarMenuBadge(n)`/
  leading `.unread` dot/`⑂`. Hover: `FluidSidebarMenuActions` with
  `popupOpen:` pinning.
- `activeIndex`: map `mind.chats.firstIndex { $0.id == mind.currentID }`;
  outline New-chat button index 0, `isActive: false`.

## 5. Automations tab IA slot

- `FluidTabs(["Chats","Automations"], selection: $tab, size: .compact)` in the
  sidebar header (automation-frontend spec'd the same control). Persist choice
  → `Store.settings` key `"ask.page.tab"`.
- v1 content: honest empty state (icon-in-circle + title + 12pt line) — no
  fake rows.
- Forward-compat: `FluidTabs` takes `[String]` — a badge on "Automations" needs
  a custom label closure or dot inside the string ("Automations •"). Run
  transcripts embed `AskChat` → `TurnView` reuse makes the `AskDensity`
  extraction pay off twice.

## 6. State-sharing subtleties — the real wiring risks

1. **P0 — `ContentView.take()` is app-global.** `watchKeys()` installs one
   NSEvent local monitor firing for keyDowns in EVERY window — only Little
   windows early-out. In the Ask window today: ⌘W closes the browser's active
   tab, ⌘K opens tab summon, ⌘F page find, Esc runs the dismissal cascade,
   ⌘1-9 select tabs. **Fix**: `guard event.window === window` on the captured
   @State window (or an owning-window check like `LittleWindow.owning`). Keep
   Little-window check first; bench `keyHook` events (nil window) must still
   pass — `guard event.window == window || event.window == nil`.
2. **P0 — Scene `.commands` + key-window.** Ask scene gets
   `CommandMenu("Chats")` with ⌘N etc. Verify whether browser CommandGroups
   stay enabled while Ask is key — if ⌘W "Close Tab" remains live, replace
   `.newItem` inside the Ask scene's commands and/or gate browser commands on
   a key-window flag. The `take()` gate covers the monitor path.
3. **P1 — `raise`/`pose` pop the rail unconditionally** (`open = true`). With
   Ask frontmost, a question still slides the browser's rail open — the card
   renders in the page's parked zone too so nothing breaks, but it's
   attention-seeking in the wrong window. Options: leave it (attention-seeking
   is the design) or a non-persisted `Mind.pageVisible` flag swapping
   `open = true` for `askWindow.makeKeyAndOrderFront`. Decide at review.
4. **P1 — Drafts are per-surface.** `drafts: [UUID: String]` is @State in
   AskPanel — same chat shows two drafts. Lift the dict into `Mind`
   (session-only).
5. **P0 — `runningHere`/`otherRunning`** — chat-scoped via `runningChatID`;
   shared composer owns them. Page ⌘. fires `mind.stop()` only `if
   runningHere`. Takeover warning ports verbatim.
6. **P0 — `attach()` + demo hooks** — `attach()` idempotent; DEBUG hooks are
   flag-gated self-resetting, safe to call from both onAppears. Cleaner: hoist
   into a shared `Mind.demoHooks(browser)`.
7. `Mind.select` pushes mode via `pushMode` — selection in the page re-leashes
   the gate, same as rail. Keep.
8. `FluidSidebarMenu`'s key monitor + `FluidSidebarCore`'s `[` monitor are
   already window-scoped (`event.window === self.window`) — no collision.
9. `browser.active` from the page reads the shared Browser — the composer's
   "+tab" offers whatever is frontmost in the browser window. Intended (the
   consent model).
10. `Browser.front` is only written by ContentView's key observer — the Ask
    window going key doesn't disturb link routing.

## 7. Persistence

- Chat data: nothing new — `AskStore` + forgiving decode covers it. No schema
  change.
- Per-window UI: sidebar open/width via namespaced `FluidSidebarState.persist`;
  `FluidTabs` selection → `Store.settings` `ask.page.tab`; window frame
  autosave (world-namespaced).
- Do NOT persist: find query, accordion state, `atBottom`. Drafts (if lifted
  to Mind): session-only.

## 8. Non-regression checklist

- Rail byte-identical after extraction — `AskDensity` defaults `.rail`, all
  literals move behind it, no forked internals.
- `take()` gate must not break: Little windows first, Omnibox, Peek,
  flagsChanged `landSummon`, bench `keyHook` synthetic events (nil window must
  pass).
- `mind.open`/`prefs.ask` semantics unchanged; `prefs.ask=false` hides the
  rail mid-open; the Ask window itself stays open (it's a window, not chrome).
- ⌘⇧A still toggles the rail globally.
- Model/harness/AskStore/Drive: zero diffs required.
- `demoCards`/`demoAttach`/`demoStream` fire identically from either surface.

## 9. Model/harness delta: **none**

Everything reads/writes existing `Mind` API. `harness.js`, `Harness.swift`,
`Drive.swift`, `AskStore`: zero changes. Only model-adjacent additions are
optional pure-state: `Mind.drafts` dict lift, `Mind.pageVisible` attention
routing.

## Priority summary

- **P0**: Window scene + dressing + world-namespaced autosave; `take()`
  window gate + Ask command layer (⌘N/⌘⇧N/⌘W/⌘.); rail door + menu entry;
  shared `AskStream` + `AskComposer` extraction; nav sidebar with
  `FluidChatRow` CRUD/badges/new-chat (persist namespaced); `AskTitleField`;
  parked zone; empty hero; attach() + demo hooks; openURL env.
- **P1**: ⌘F find; ⌘K switcher; share menu (Copy Transcript / Copy as
  Markdown / Share…); chat search; FluidTabs + Automations placeholder +
  `ask.page.tab`; row rename; `Mind.drafts` lift; `pageVisible` decision;
  Esc cascade.
- **P2**: queue strip; "Open in Window" row item; shot Peek float; delete
  confirm (if desired).

## Reviewer checklist

- [ ] `Window("Ask", id:"ask")` opens from rail Door + menu; ⌘W closes only
      the window; autosave world-namespaced
- [ ] Ask window key: ⌘W doesn't close a browser tab; ⌘K → switcher not
      summon; ⌘F → transcript find not page find; Esc → page cascade, never
      `browser.dismiss`
- [ ] `take()` serves the browser window fully (⌘T/⌘K/⌘[/digits/space);
      Little windows unchanged; bench keyHook (nil window) still reaches take
- [ ] Send/steer/stop/retry/takeover identical from page and rail — including
      the armed two-send takeover
- [ ] `runningChatID` correctness: ring + ticking accordion on the right chat
      in both surfaces; background settle doesn't touch open accordions
- [ ] Selecting in either surface moves both (one cursor) + stamps lastSeen —
      unread dots agree
- [ ] `Mind.rename` wired (header field Return/Esc/empty→"New chat") + row menu
- [ ] Delete via `mind.remove` only — running stop, file drop, grant clear
- [ ] Sidebar persist keys namespaced; `[`/hover-peek only in Ask window
- [ ] Chat search filters title + last message; Esc clears
- [ ] `ask.page.tab` persists; Automations placeholder honest-empty
- [ ] `Harness.shared.attach()` + DEBUG hooks fire on `AskPage.onAppear`
- [ ] `AskUI.transcript` + `markdown` produce identical coverage; Share…
      anchors in the Ask window
- [ ] Question/approval cards in the page's parked zone; 300s clock intact;
      `pageVisible` decision recorded
- [ ] Zero diff in Mind event handling, AskStore, harness.js, Drive; rail
      pixel-identical post-extraction (`AskDensity` defaults `.rail`)
- [ ] No `Palette.*` inside the page; `FluidChatRow` replaces `ChatRow`
