# Automations/Routines — backend scope

## Verdict up front

**Dedicated second engine seat, not a shared-seat queue.** One extra `Harness`
instance (own hidden WKWebView) that runs *one* routine run at a time, fed by a
FIFO queue in a new `Routines` controller. The interactive seat
(`Harness.shared`) and `Mind` are never touched.

Why not "queue while `Harness.running`" on the shared seat: queuing protects
the user's turn from the routine but not the routine from the user —
`Mind.send` → `engine.run` → `harness.js kill(current)` means a user send
mid-run silently kills the routine. A scheduled job that dies whenever the user
opens Ask is broken by design. Drive is already multi-session
(`sessions: [DriveOrigin: Share]`); a `.routine(id)` origin gets isolated tabs,
leases, parked approvals and remembered always-rules for free. `queued` still
exists: two routines due at once queue behind the single routine seat.

`drive.js` is the page-side agent toolkit (snapshot/resolve/act); `Drive.swift`
is the ops layer it feeds; `Bench.swift`/`AgentSocket.swift` are external
control surfaces, not schedulers. The reuse story is Harness+Drive+AskChat, not
new runtime machinery.

## 1. Data model — validated + amended

```swift
struct Routine: Codable, Identifiable {
    var id = UUID()
    var name: String
    var prompt: String
    var enabled = true
    var schedule: RoutineSchedule
    var timezone: String = TimeZone.current.identifier   // IANA id
    var model: String?            // nil → Mind.savedModel().id at dispatch
    var mode: AskMode = .guard
    var timeoutSeconds: Int = 1800          // per-run wall clock while .running
    var notify: Bool?                       // nil → global ask.routines.notify
    var createdAt = Date(); var updatedAt = Date()
    var nextRunAt: Date?
    var lastRunID: UUID?
}
```

- **`RunState` = `{queued, running, waiting, succeeded, failed, cancelled}`** —
  drop `scheduled`: a run materializes only when it enters the queue;
  "scheduled" is a routine-level display state derived from `nextRunAt`.
- `RoutineTrigger { scheduled, manual, retry }`.
- `RoutineRun.chat: AskChat` embedded — load-bearing: `AskTurns.split`/
  `TurnView`/`ToolRow`/`QuestionRow`/`ErrorNote` work verbatim.
- **`waitingOn` plural**: a run can stack several parked approvals —
  `var waitingApprovals: [AskApproval] = []` +
  `var waitingQuestion: AskQuestion? = nil`; `.waiting` ⇔ either non-empty.
- Retention: **20 runs per routine** (`Store.settings` `ask.routines.keep`,
  default 20), pruned oldest-first on each terminal save. shotPath artifacts
  under `shotsFolder()` aren't reaped today — runs inherit that gap (flag,
  don't fix).

## 2. Scheduling

```swift
struct RoutineSchedule: Codable {
    enum Frequency: String, Codable { case hourly, daily, weekdays, weekly, custom }
    var frequency: Frequency
    var interval = 1                 // every N hours/days/weeks
    var weekdays: Set<Int> = []     // Calendar.weekday (1=Sun…7=Sat)
    var hour = 9, minute = 0        // local wall-clock in `timezone`
    var cron: String?               // P1 — raw cron beside the structured fields
    func next(after date: Date, tz: TimeZone) -> Date?   // pure — testable
}
```

- `next(after:tz:)` is a pure function on `Calendar(timeZone:)` — no evaluator
  framework; `custom` (P1) may carry a 5-field cron evaluator. DST gaps: `next`
  returns the next valid wall time — a nonexistent 9:00 falls forward.
- **Scheduler**: one `DispatchSourceTimer` on `.main`, 30s repeating scan of
  `nextRunAt <= now`. Immune to sleep/relaunch/missed one-shots. Also scan on
  `NSWorkspace.didWakeNotification` and on every mutation.
- **Missed-run policy**: any overdue enabled routine fires **once** on
  catch-up, then `nextRunAt` recomputes strictly after now — a week closed =
  one run, not N. Per-routine `.skip` policy is P2.
- `nextRunAt` persisted on the Routine; recomputed on save/enable/launch/each
  scheduled run's completion.

## 3. Execution engine — the mechanics

### Harness parameterization (the only engine work)

```swift
var origin: DriveOrigin = .app                       // routine seat: .routine(routineID)
var sink: (AskEvent) -> Void = { Mind.shared.hear($0) }
var onAsk: ((String, [String], UUID) -> Void)?       // nil → Mind.shared.pose
init(registering: Bool = true) { …; if registering { attach() } }
```

Touchpoints: `run()`/`stop()`/crash handler → `denyPending(for: origin, …)`;
`event()`/`run()` error paths → `sink(…)`; `poseAsk` → `onAsk` if set.
`attach()` stays interactive-only; `Drive.ask` op unchanged.
`static let routine = Harness(registering: false)` — `Mind.engine`,
`Mind.running`, `runningChatID` never see runs. Second webview boots lazily on
first `run()`.

### Drive changes

- `DriveOrigin` += `case routine(UUID)` (the *routine* id — session scope is
  the routine, not the run). `tag` += `"routine-\(uuid.prefix(8))"`;
  `mode(for:)` default `.guard`, overridable via `setMode` at dispatch.
- `parkApproval`: today `guard origin == .app` → `NEEDS_UI`. Add a registered
  `approvalSink: ((AskApproval, DriveOrigin) -> Bool)?` — `.routine` → sink
  parks the card on `run.waitingApprovals`; no sink → existing `NEEDS_UI`.
  `settleApproval(id, verdict)` works as-is; `AskApproval.chat` carries
  `run.chat.id` — the detail resolves it from the run, not `Mind.chats`.
- New `Drive.endRun(_ origin:)` — `leave()`-like cleanup minus
  remembered/modes death: `denyPending(origin, "the run ended")`, close
  `sessions[origin].mine` bench tabs, drop attaches/leases. **Keep
  `remembered[origin]`** — an "Always: submit · acme.com" on a routine must
  persist across runs; per-routine remembered rules = "consent is the
  routine's".
- `open()`: `agentName` for `.routine` → the routine's name (lookup hook).
- Downloads: `.guard` routine tabs get downloads cancelled (never asked);
  `.full` routines download freely. Document.

### Dispatch flow (in `Routines` controller)

```swift
func dispatch(_ run: RoutineRun, routine: Routine) {
    var chat = AskChat(id: UUID(), title: "\(routine.name) — \(run.trigger.rawValue)")
    chat.model = routine.model ?? Mind.savedModel().id
    chat.mode = routine.mode
    chat.turn = UUID(); chat.turnStartedAt = Date()
    chat.messages.append(AskMessage(role: .you, text: routine.prompt))
    drive.setMode(routine.mode, for: .routine(routine.id))
    seat.run(AskJob(chat: chat, tabs: [], attachments: [], text: routine.prompt))
}
```

- `tabs: []` — routines hold no chips; the grant door is never reached.
- Events fold via injected `sink` → `controller.hear(event, into: runID)`.
- `.done` → `.succeeded` (error nil) / `.failed` + `endRun` + dequeue.
- **Timeout**: `Task` deadline = `timeoutSeconds`, ticking only while
  `.running`; `.waiting` suspends it (parked asks are first-class — "a
  deny-on-timer is a lie"). A waiting run holds the seat — honest queuing.
- `stopRun`: queued → `.cancelled`; running/waiting → `seat.stop()` → JS kill
  flushes pending tools; trailing `.done` seals `.cancelled`.
- `retryRun`: new run `{trigger: .retry, retryOf: old.id}`, front of queue.
  `runNow`: front of queue / immediate if seat free.
- Queue order: scheduled FIFO; manual/retry jump ahead of scheduled.

### Transcript folding — one refactor, flagged

Run chats need the same fold `Mind.hear` implements (delta→block mirror,
`.message` supersede+`trim(committedBy:)`, `workedFor` stamp, error `.note`).
**Recommended (P0)**: extract the chat-mutation half into a shared
`AskFold.apply(_ event:, to chat: inout AskChat, folds: inout [UUID:Set<UUID>])`
used by `Mind.hear` and the controller. Seats (`question`, `pendingApprovals`,
`runningChatID`, `activity`) stay in `Mind`; the fold is pure per-chat work.
Fallback: scoped copy + "keep in lockstep" comment — worse.

## 4. Permissions

- `routine.mode` defaults to `.guard`, shown as Confirm; `.full`
  selectable with a warning. `Policy.check` escalation applies identically.
- Dangerous ops while unattended: **park, not auto-deny** — `.waiting` + badge
  + notification. Full is the only mode that bypasses confirmations.
- `ask.user`: `onAsk` injection → `run.waitingQuestion` — never `Mind.pose`,
  never pops the rail, no 300s clock; second `ask_user` per run → `busy`
  decline.
- `tabs.grant` unreachable — `kind:"grant"` only from `attachTabs`, job.tabs
  empty anyway.
- **`tabs.ungrantAll` — resolved**: it already revokes attaches on ended grants
  for all origins — a routine mid-run loses a user tab when its chip's chat
  dies. Correct lifetime; document. Routine bench tabs (`mine`) unaffected.
- v1 limitation: a routine can attach a *user* tab only while a live chat chip
  covers it (registry is global). Per-routine pinned-tab grants = P2.

## 5. Persistence

- `RoutineStore` mirroring `AskStore`: `Store.file("routines")/<id>.json`,
  `Store.file("runs")/<id>.json` — one JSON per entity, atomic write,
  `decodeIfPresent` defaults, `Store.quarantine` on failure.
- Runs persist on `.message`/`.done` and state transitions only (delta/tool
  mutate in memory — same as `Mind.store`).
- Separate folder, **no flag on `AskChat`**: `AskStore.list` reads `chats/`
  only — run chats can never surface in the chat list.
- World isolation free via `Store.testing`/`world`.

## 6. Lifecycle

`scheduled` (routine.nextRunAt) → `.queued` → `.running` (seat free) →
`.waiting` (parked ask/approval) ⇄ `.running` → `.succeeded` / `.failed` /
`.cancelled`. Terminal writes: `finishedAt`, `error`, `acknowledged=false`,
`routine.lastRunID`, `routine.nextRunAt` recompute, `endRun` cleanup, dequeue,
retention prune. Auto-retry: none (manual `retryRun` only; P2 adds backoff).

## 7. Surface

- Controller `@Published`: `routines`, `runs` per routine, aggregates
  (`lastRunState`, `nextRunAt`, `unacknowledgedCount`) — scoped so no delta
  touches `Mind.chats`/`AskPanel`.
- P2 notifications: `UNUserNotificationCenter.current()` precedent in
  ExtensionShims (requestAuthorization([.alert,.sound]) +
  UNMutableNotificationContent) on `.failed`/`.waiting`, gated by
  `Store.settings` `ask.routines.notify`.

## 8. Integration seams — audit

| Seat | Protection |
|---|---|
| `Mind.currentID` | run chats aren't in `Mind.chats` — `select` can't reach them |
| `AskStore.list` | reads `chats/` only — runs live in `runs/` |
| `Mind.question`/`pendingApprovals` | run asks park on `run.waiting*` via `onAsk` + `approvalSink` — `pose`'s rail-pop never fires |
| `runningChatID`/`Mind.running` | set only by send/retry/hear(.done) — run events never call `Mind.hear` |
| takeover kill | `harness.js kill(current)` is per-page — the routine webview is a different JS context |
| `tabs.ungrantAll` | revokes `.routine` attaches on ended grants only |
| `ui.ask` op / `appChat` | `.app`-only door — untouched |

## 9. Testability

- `ask.demoroutine` defaults lever (mirroring `demoStream`): `Store.testing`-
  gated, seeds one echo-model routine + fabricated run history incl. a
  `.waiting` run.
- Headless exercise: `echo` provider needs no network — a probe-world routine
  on a 1-minute schedule does a real end-to-end run with zero keys.
- `RoutineSchedule.next(after:tz:)` is pure — exercise via probe levers.

## 10. Priorities

- **P0**: models + `RoutineStore` + `Routines` controller (queue, scan timer,
  catch-up) + Harness seat parameterization + `DriveOrigin.routine` +
  `approvalSink` + `Drive.endRun` + `AskFold` extraction + retention + `.guard`
  default + non-regression audit.
- **P1**: `waitingApprovals`/`waitingQuestion` settle paths + audit-note
  mirror, `retryRun`, `acknowledge`, `timeoutSeconds`, `runNow` queue-jump,
  per-routine `agentName`, notifications plumbing.
- **P2**: raw cron, notification delivery + Settings toggle, `.skip`
  missed-run policy, per-routine pinned user-tab grants, auto-retry backoff.

## 11. Files

**New**: `Sources/Search/Routines.swift` — models, `RoutineStore`, `Routines`
controller+scheduler (one file per concern precedent).
**Modified**: `Harness.swift` (origin/sink/onAsk/registering ~30 lines),
`Drive.swift` (DriveOrigin case + tag, mode default, parkApproval sink, endRun,
agentName ~60 lines), `Browser.swift` (start `Routines.shared` after
`AskRuntime.drive`), `Mind.swift` (`AskFold` extraction — mechanical),
`PROTOCOL.md` (one paragraph on routine origins).
**Reuse**: drive.js/harness.js unchanged; AskChat/AskBlock/AskApproval/
AskQuestion verbatim; Store conventions verbatim.

## 12. Risks / open questions

- Second WKWebView memory — lazily booted, bounded by seat=1.
- Two agent loops could contend on the same user tab (lease/attach) — Drive's
  per-session isolation makes this safe; document that a routine and the user
  can drive different tabs at once.
- `agent.lease` user-touch release still works for routine tabs.
- App killed mid-run: on relaunch, mark persisted `.running`/`.queued` runs
  `.failed` ("the app stopped mid-run") — recovery sweep in `RoutineStore.list`
  on first load.

## Reviewer checklist

- [ ] Runs never touch `Mind.engine`/`chats`/`currentID`/`runningChatID`/
      `question`/`pendingApprovals`/`activity` — every run-side path through
      `origin`/`sink`/`onAsk`.
- [ ] Seat decision explicit: one routine Harness, seat depth 1, FIFO queue; a
      user send mid-run cannot kill it.
- [ ] `denyPending`/`settleApproval`/`parkApproval` scope to `.routine(id)`; no
      run card reaches `Mind.raise`; `NEEDS_UI` remains the fallback.
- [ ] `endRun` closes run bench tabs + pending asks but preserves
      `remembered`+`modes` for the routine.
- [ ] Scheduler recomputes `nextRunAt` strictly forward; catch-up fires once.
- [ ] `decodeIfPresent` + `Store.quarantine` on every persisted type; runs
      folder separate from `chats/`.
- [ ] `.guard` default; danger-lexicon escalation applies; downloads cancel
      under `.guard` on routine tabs.
- [ ] `tabs.ungrantAll` behavior on routine-attached user tabs documented.
- [ ] `waiting` suspends the run timeout; parked asks never time out.
- [ ] Probe lever (`ask.demoroutine`) + echo end-to-end run demonstrated;
      `next(after:)` pure.
- [ ] Badging aggregates only — no `@Published` deltas reaching Mind.chats/
      AskPanel.
