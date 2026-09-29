# Automations/Routines — frontend scope

Repository state: no Routine/Automation/schedule model or UI exists today. The only
Ask surface is the 380pt right rail (`AskPanel`). The fullscreen chat page (with a
left-nav sidebar where the Chats ↔ Routines tab lives) is a separate workstream —
this spec is written against its intended shell and re-verified once it exists.

## Architecture findings that shape the design

- **The engine is a single seat.** `Harness` runs one turn at a time; `Mind.send`
  codifies a "takeover" (sending in chat B while A runs stops A — the rail already
  has the armed-warning UX). A scheduled run firing mid-conversation would kill the
  user's interactive turn. Backend contract: routine runs need their own engine seat
  OR a queue that defers while `Harness.running` — and the UI needs a `queued` row
  state.
- **A run reuses the whole transcript stack if a run embeds an `AskChat`.**
  `AskTurns.split` → `TurnView`/`WorkedFor`/`ToolRow`/`QuestionRow`/`ErrorNote` all
  work verbatim on `run.chat.messages`; `live:` binds to `run.state == .running`.
- **Approvals/questions are global and attention-seeking.** `Mind.question` is
  one-at-a-time and `pose` pops the rail open. Routine runs must own their parked
  approvals (surfaced in the routine detail + badge), never pop the rail at 3am.
- **Persistence conventions.** One JSON per entity under `Store.file("routines")`,
  `decodeIfPresent` defaults (copy `AskChat.init(from:)`), `Store.quarantine` on
  decode failure, `Store.settings` for prefs.

## Backend contract the UI needs

```swift
struct Routine: Codable, Identifiable {
    var id = UUID()
    var name: String
    var prompt: String
    var enabled = true
    var schedule: RoutineSchedule   // structured: frequency/interval/weekdays/hour/minute (+ optional cron)
    var timezone: String            // IANA id; defaults to TimeZone.current
    var model: String?              // nil → ask.mode default
    var mode: AskMode = .guard
    var createdAt = Date()
    var updatedAt = Date()
    var nextRunAt: Date?
    var lastRunID: UUID?
}

enum RoutineTrigger: String, Codable { case scheduled, manual, retry }

struct RoutineRun: Codable, Identifiable {
    var id = UUID()
    var routineID: UUID
    var chat: AskChat               // the transcript — the whole reuse story
    var trigger: RoutineTrigger
    var state: RunState             // scheduled|running|waiting|succeeded|failed|cancelled|queued
    var startedAt: Date?
    var finishedAt: Date?
    var error: String?
    var retryOf: UUID?
    var waitingOn: WaitKind?        // .approval(AskApproval) | .question(AskQuestion)
    var acknowledged = false        // failure/waiting read-state for badging
}
```

Controller (ObservableObject mirroring Mind): `list`, `create`, `update`, `delete`,
`setEnabled`, `runNow` → runID, `stopRun`, `retryRun`, `listRuns(routineID)`,
`acknowledge(runID)`, published per-routine aggregate (`lastRunState`, `nextRunAt`,
`unacknowledgedCount`), live channel for the running run's AskEvents.
Concurrency rule: queue while `Harness.running`, detail header notes
"Runs next when Ask is free".

## Screen-by-screen spec

1. **Sidebar tab IA.** `FluidSidebarHeader` holding `FluidTabs` (tracked) "Chats" |
   "Routines"; `FluidSidebarMenuBadge` on Routines when running + unacknowledged > 0;
   "New routine" = `FluidButton` secondary compact in the header action slot.
   `selectedRoutineID` parallel to `Mind.currentID`; tab choice persisted in
   `Store.settings` like `settings.page`.

2. **Routine list rows.** `FluidSidebarMenuButton`-derived `RoutineRow`, 3 lines
   ~52pt: name (13pt medium), schedule line (11pt muted — "Every weekday · 9:00" or
   "Paused"), status line (11pt: last-run `When.said` relative time +
   `RoutineStatusBadge` sm `FluidChip`, or `Ring` + activity while running).
   Trailing `FluidSwitch` (compact) + `FluidSidebarMenuActions` hover cluster:
   Run now / Edit / Delete. `FluidSidebarMenuSkeleton(showIcon: true)` while loading.

3. **Routine detail.** Right pane `FluidScrollArea`, stacked `FluidCard`s: header
   (name inline-editable, FluidSwitch, schedule sentence, nextRunAt, Edit + "Run now"
   primary + overflow menu), Prompt card (readonly rendered, Edit), Runs card
   (FluidTable-light rows: state icon, trigger, startedAt, workedFor, error preview),
   then run transcript via `AskTurns.split(run.chat.messages)` → `TurnView`
   verbatim. Failed run: `ErrorNote` + "Retry run" button. Wide widths may do
   runs-list | transcript side-by-side (P2).

4. **Create/edit form.** Page-level form, not a dialog: `FluidInput` name (required
   + error line), prompt via `FluidInputMessage` (header slot for model/mode chips),
   `RoutineSchedulePicker` (new): `FluidSelect` presets (Hourly/Daily/Weekdays/
   Weekly/Custom), conditional `FluidChecks` weekday group + hour/minute selects,
   timezone `FluidCombobox`, live "Next run: …" preview (muted 12pt), advanced
   `FluidAccordion` raw cron. Footer Save (primary, disabled until valid) / Cancel;
   dirty-state guard → `FluidDialog` sm "Discard changes?".

5. **Run states** — `RoutineStatusBadge`, never color-only:

   | state | badge | glyph |
   |---|---|---|
   | scheduled | gray "Scheduled" | calendar |
   | queued | gray "Queued" | clock (tip: "waiting for Ask to be free") |
   | running | blue + `Ring`/`FluidSpinner` | elapsed ticks |
   | waiting | amber "Needs you" | exclamationmark.bubble → opens detail |
   | succeeded | green "Ran" | duration shown |
   | failed | red "Failed" | error preview + retry |
   | paused | muted "Paused" | switch off, nextRun hidden |
   | cancelled | gray "Stopped" | — |

6. **Empty states** — three, on the Ask empty-state pattern (circled 20pt icon,
   14pt semibold title, 11.5pt muted subtitle, starter pills): no-routines
   ("Ask can do this on a schedule…" + "New routine" + template pills), no-runs-yet
   on detail ("first run on {nextRunAt}" + "Run now"), no-search-matches
   ("Nothing matches").

7. **New-tab routine cards.** `FluidCardGroup` grid of `FluidCard`s: name +
   schedule sentence + status badge + last-run ago. Click → fullscreen routine
   detail route. Cards stay metadata-only.

8. **Badging.** `FluidSidebarMenuBadge` on the Routines tab (running + waiting +
   unack-failed). Don't double-signal the rail's AskButton dot unless the rail is
   the routines entry point. P2: UNUserNotificationCenter on terminal transitions
   (failed, waiting), gated by a Settings toggle.

9. **Keyboard & a11y.** SidebarMenu ↑↓/Home/End/Return/Space inherited. Suggest
   ⌘⌥N for New Routine (⌘⇧N taken); sidebar-tab switch ⌘⇧1/2 or unbound.
   Esc cascade: menu → form-cancel-confirm → back to list. VoiceOver composed row
   labels ("{name}, {schedule}, {state}, last ran {ago}, {on/off} switch").
   Reduce-motion: `FluidSpinner` self-disables; `Ring` does not — flag/swap; keep
   elapsed text as the liveness signal.

10. **Non-regression.** Routine observations scoped to the routine pane — no
    `@Published` deltas touching `Mind.chats`/`AskPanel`. No `TimelineView` ticking
    in hidden panes. Lazy lists + skeletons. Run chats never appear in `Mind.chats`
    (a `routine` flag or separate store). Run approvals never hijack
    `Mind.question`'s seat. `tabs.ungrantAll` semantics for routine-held consent is
    an open question for the backend.

## Fluid reuse map (verified to exist)

- Shell/nav: `FluidSidebar`, `FluidSidebarGroup`, `FluidSidebarHeader`,
  `FluidSidebarInput`, `FluidSidebarMenuButton/Actions/Badge/Skeleton`
- Tabs: `FluidTabs` (tracked) / `FluidTabsSubtle`
- Status/buttons: `FluidChip` (gray/red/amber/green/blue/violet, sm), `FluidButton`
  (36/28/icon, `loading:`), `FluidSwitch`, `FluidSpinner`, `Ring`
- Forms: `FluidInput`, `FluidInputGroup`, `FluidInputMessage`, `FluidSelect`,
  `FluidCombobox`, `FluidMenu`, `FluidChecks` (merged weekday chips)
- Surfaces: `FluidCard`/`FluidCardGroup`/`FluidCardHeader/Title/Description`,
  `FluidTable`, `FluidDialog`, `FluidTooltip`, `FluidScrollArea`,
  `FluidScrollFadeState` top fade
- Transcript: `TurnView`, `WorkedFor`, `ToolRow`, `QuestionRow`, `ApprovalCard`,
  `ErrorNote`, `AskTurns.split/worked(_:)`
- Formatting: `When.said/clock/day` (Recall.swift) relative-time formatter

New components needed: `RoutineRow`, `RoutineStatusBadge`,
`RoutineSchedulePicker`, `RunHistoryRow`, `RoutineDetail` scaffold, `RoutineForm`,
`RoutineCard` (new-tab), routine empty-state.

## Priorities

- **P0** — Routines sidebar tab + RoutineRow list + RoutineDetail with TurnView
  transcript reuse + RoutineForm (name/prompt/preset-schedule/enabled) + run-state
  badges + all three empty states + backend contract (model + ops + the
  single-engine queue decision) + non-regression guardrails.
- **P1** — Run history with retry/acknowledge, hover action clusters,
  search/filter, waiting-state inline approval reuse, unsaved-changes guard,
  advanced cron disclosure, timezone picker, VoiceOver composed labels, new-tab
  cards wired to the detail route.
- **P2** — `FluidTabsSubtle` icon-collapse variant, macOS notifications on terminal
  transitions, schedule templates, wide side-by-side layout, Settings additions.

## Reviewer checklist

- [ ] Routines never mutate `Mind.chats`/`runningChatID`/`pendingApprovals`/
      `question` — separate store; transcript reuse by `AskChat`-embedding.
- [ ] Single-engine constraint resolved explicitly (queue vs dedicated seat) and
      `queued` renders.
- [ ] A routine's waiting/question/approval never pops the Ask rail or steals the
      composer's answer path.
- [ ] `FluidSidebarMenu` keyboard nav intact; no shortcut collisions (⌘⇧N, ⌘S,
      ⌘⇧S, ⌘K, ⌃1-9 all taken).
- [ ] Statuses distinguishable without color/animation; reduce-motion leaves
      text-based elapsed/duration.
- [ ] Schedule = structured data + human preview; timezone explicit; next-run
      computed store-side.
- [ ] Chat list, rail width, takeover warning, unread dots, `lastSeen` unchanged.
- [ ] Lazy lists + skeleton-first; no ticking TimelineView in hidden panes.
- [ ] Destructive actions via `FluidDialog`; nothing else modal.
- [ ] `decodeIfPresent` defaults + `Store.quarantine` everywhere.
- [ ] `tabs.ungrantAll` semantics resolved for routine-held tab consent.
