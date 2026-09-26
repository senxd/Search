# Ask permissions — modes, classes, the gate

The unit of consent today is the tab (grantedTabs, in-app chips). What's missing
is a second axis: *what the session may do* once it holds a tab. This adds a
per-session **mode**, an op **classification**, and a **gate** in `Drive.serve`
that turns some ops into approval cards.

## 1. Modes

Three, matching Aside's recon names mapped to this codebase's vocabulary:

```swift
enum AskMode: String, Codable { case read, guard, full }
```

| mode | meaning | analog |
|---|---|---|
| `read` | read-class ops only; everything else is refused, not asked | Aside `read-only`, Codex `--sandbox read-only` |
| `guard` | reads+writes free; destructive and privileged ops ask | Aside `guard`, Codex `on-request` × `workspace-write` |
| `full` | everything allowed (the grant door stays a door) | `danger-full-access` |

Where stored:

- **Chat**: `var mode: AskMode = .guard` on `AskChat` (Mind.swift:50) — persisted
  in `chats/<id>.json` (`AskStore`). Consent is already chat-scoped
  (`tabs.ungrantAll` on newChat/remove, Mind.swift:191/206); mode rides the same
  lifetime. `Codable` default via `decodeIfPresent` so old chats decode as `guard`.
- **Socket session**: on `Drive.Share`/`[DriveOrigin: AskMode]`, default `full`.
  agent.sock peers are same-uid, chmod 600, getpeereid-checked
  (AgentSocket.swift:90-97) — already the app's trust level. Settable via an
  `agent.mode {to}` op or a `mode` arg on `subscribe`.
- **Global default**: `Store.settings["ask.mode"] = "guard"`, a segmented picker
  in Settings › Ask beside the model picker (Settings.swift:403).

UI: a capsule in the composer's bottom row next to ModelMenu (AskUI.swift:313)
— shield icon + mode name, menu of three. The `.app` session's mode is *the
current chat's*: `Mind.select/send/newChat` push it into Drive
(`drive.setMode(chat.mode, for: .app)`), the same push pattern `hear` uses.

## 2. Op classes

```swift
enum OpClass { case meta, read, write, destructive, privileged }
```

`privileged` = capability beyond the page the tab holds — arbitrary JS,
filesystem writes, the consent registry, cross-door message injection.
`destructive` = irreversible or spend/identity consequence. The *target* adjusts
consequence: the same verb on a granted **user tab** is weightier than on a
bench tab (the chip consented to driving, not to buying).

| op | class | notes |
|---|---|---|
| `ping`, `subscribe` | meta | always allowed |
| `tabs.list`, `agent.tabs`, `agent.probe` | read | metadata only |
| `page.wait`, `page.text`, `page.snapshot`, `page.console`, `page.frames` | read | content reads; need granted/mine tab via `own()` as today |
| `page.screenshot` | read; **write if `path` set** | `path` expands `~` and writes *anywhere the app can* — a filesystem write hiding inside a read op |
| `tabs.open` | write | creates agent tab; `foreground:true` steals attention — still write |
| `tabs.attach`, `tabs.detach` | write | user tabs still gated by `grantedTabs`; unchanged |
| `tabs.select` | write | moves the user's screen |
| `page.go` | write on bench tab; **destructive on user tab** | walks a user's session to a new origin, drops page state |
| `page.back`, `page.forward` | write | on user tab: write |
| `page.reload` | write on bench; **destructive on user tab** | loses unsaved form state |
| `act.hover`, `act.scroll` | write | transient, visible-only state |
| `act.click`, `act.clickAt`, `act.fill`, `act.type`, `act.press`, `act.select`, `act.check` | write | the driving verbs the chip consents to. **Escalation**: when a snapshot `ref`/`loc` resolves to a control whose accessible name matches a danger lexicon (`buy|pay|order|purchase|subscribe|send|post|delete|transfer|confirm`), the op escalates write→destructive. refs carry `{role,name}`; one extra resolve call, guard mode only, best-effort. `press Enter` can't see its focused target — stays write, noted |
| `act.submit` | destructive | `requestSubmit()` is the canonical "buy/post" vector |
| `page.eval`, `page.code` | privileged | arbitrary JS = the tab's whole ambient authority at that origin (acts as the signed-in user: post, purchase, scrape). Not merely "write" |
| `tabs.close` | destructive | bench-only already; loses the tab's state |
| `agent.lease` | write | claims foreground coordination |
| `tabs.grant`, `tabs.ungrantAll` | privileged + door-bound | unreachable by tools/socket already; the gate leaves them alone |
| `ui.ask` | `open`/`stop`: write; **`send`/`steer`: privileged** | `send` posts text *as the user* into the in-app agent — cross-session prompt injection into the session that holds the grants. Ungated today |
| downloads | destructive | not an op — gated where they become one: `Browser.keep(_:)` / `decidePolicyFor .download`. Files on disk |

## 3. The gate

One choke point already exists: `Drive.serve` — both doors funnel through it,
`origin` in hand. The check goes after `jsonSafe`, before the `switch`:

```swift
switch Policy.check(op, args, mode: mode(for: origin), tab: tab(args)) {
case .allow: break                                    // dispatch as today
case .deny(let why): finish(["error": why, "code": "DENIED"])
case .ask(let card): parkApproval(card, finish);      // finish parked
}
```

`Policy` (new `Sources/Search/AskPolicy.swift`, one file per concern):
`check(op:mode:tab:) -> Verdict`. Verdict matrix: read allows `meta|read`;
guard allows ≤`write`, asks on `destructive|privileged`, denies nothing;
full allows all but the door-bound ops (those stay refused by origin, not
mode — a socket in `full` still can't `tabs.grant`). `always` decisions land
as remembered rules: `[DriveOrigin: Set<AlwaysKey>]` where
`AlwaysKey = (opOrClass, host)` — dies with `ungrantAll`/`leave`, same
lifetime as every other consent here.

**The ask path.** The op's `finish` is parked in `pendingApprovals[UUID]` —
`Share.pending` stays incremented, `done` never fires, the harness's
`tool()` promise just waits. Drive raises `Mind.shared.ask(approval)` — the
same pattern as `ui.ask` → `Mind.shared.open`. On resolution,
`Drive.settleApproval(id, verdict)`: allow → dispatch the original op
fresh (re-runs `own()`/`view()` — a navigated/gone tab errors normally);
deny → `finish(["error":"denied by user — \(summary)", "code":"DENIED"])`.

**Evidence.** For tab-targeted asks the gate snapshots `tab.built` (never
stands one up) via the same `WKSnapshotConfiguration` path `screenshot`
uses → thumbnail path on the card.

**The "why".** Two sources, both shown: an auto-description from op+args
(`Policy.describe`: "submit the form on acme.com", "run JavaScript on
github.com (tab a1b2c3d4)") — deterministic, always present, uncorruptable;
plus an optional `why` arg the model passes on mutating tools (add to TOOLS
params in harness.js). `why` must be stripped by the gate before dispatch —
`actArgs` forwards everything but `tab` to `d.act`, so it would otherwise
leak page-side.

**Socket sessions never block.** AgentSocket answers any op after a 30s
patience timer and owns no UI; parked approvals can't ride a socket. If a
socket session is in `guard`/`read`, `ask` verdicts resolve immediately to
`["error":"…needs approval — the wire can't be shown a card","code":"NEEDS_UI"]`.
`full` default means today's tests (`ui.ask send`) are unaffected.

**Settling pendings.** Approvals settle-deny on: `Mind.stop`→`Harness.stop`
(kill clears JS-side pendingTools; Drive's parked `finish` must also settle —
`Harness.stop` calls `drive.settleApprovals(for:.app)`), `leave(origin)`
(socket death), `ungrantAll`/chat delete (the chat's consent and its asks
die together), `run()` replacing the live turn.

## 4. Sandboxing a browser: identity is the seatbelt

Codex's axis is filesystem writes; a browser's equivalent is **whose cookies
the tab carries**. Today every agent tab is signed-in-as-you: `benchOpen`
→ `Tab(bench:true)` → `Web.configuration(shy:false)` → `Spaces.store`.
`Tab(shy:)` is the ready-made guest option: `.nonPersistent()` store, no
extensions, no history.

| mode | agent-tab data store | op ceiling | asks? |
|---|---|---|---|
| `read` | `.nonPersistent()` — fresh forced | `read` ops | never |
| `guard` | signed-in (today); `fresh:true` opt-in per `tabs.open` | ≤ write | destructive + privileged |
| `full` | signed-in; `fresh` opt-in | all | never |

The store is fixed in `Tab.init(configuration:)` before the view exists — so
sandbox level is a **`tabs.open`-time property of the tab**, not a live
session switch: `open()` computes `fresh = args["fresh"] ?? (mode == .read)`
→ `Tab(shy: fresh, bench: true)`. `tab.shy` is already the marker; no new
flag. Chips compose cleanly: a granted user tab still reads signed-in
content in `read` mode (the chip is consent for *that* tab) while fresh
agent tabs stay logged-out.

Downloads: `Browser.keep(_:)` gets the initiating tab via `tab(for:)`;
bench tab whose holder session is `< full` → ask (guard) or
`download.cancel()` (read).

Domain allowlists (v2 hook, cheap): derive a per-chat `allowedHosts` from
the chips' origins + the first `page.go` host; off-list `page.go` on a user
tab → ask. The URL is already in hand at `go()`; ship the hook with an
allow-all default.

## 5. Approval UX

Card in the chat stream (Aside's pattern), a new `AskApproval` rendered where
ToolRows render:

```
┌──────────────────────────────────────────┐
│ ⏸  Wants to submit the form on acme.com  │   ← Policy.describe
│    "place the office-supplies reorder"   │   ← model's why (optional)
│    [tab screenshot thumbnail]            │
│    [Allow]  [Always: submit · acme.com]  │   [Deny]
└──────────────────────────────────────────┘
```

- `AskEvent` gains `.approval(chat: UUID, AskApproval)` and
  `.approvalResolved(chat: UUID, id: UUID, verdict)`; `AskApproval{id, op,
  summary, why?, tabID?, host, shotPath?, when}`;
  `ApprovalVerdict{allow, deny, always}`.
- `Mind`: `@Published pendingApprovals: [AskApproval]`,
  `resolve(_:to:)` → `Drive.settleApproval`. Resolution appends
  `AskMessage(role:.note, text:"✓ allowed act.submit on acme.com")` — the
  audit trail: persisted in chat JSON, and replays into model history as
  `[note: …]` so the model sees its own record.
- Pending state: the tool's ToolRow spins while `result==nil`; harness emits
  `activity` "waiting for your ok — …".
- **No timeout.** A parked `finish` is first-class (`Share.pending`). Deny-
  on-timer is a lie about what happened. Pendings die with stop/chat/leave.
- **Always scoping**: `(op, host)` within the chat — `Always: submit ·
  acme.com`, not "always submit". Privileged ops may be always'd per host.
- Steer during a pending ask works normally; text never resolves a card —
  only the buttons count as consent, so "yes" in chat can't be mistaken.

## 6. Defaults and failure modes

- New chats: `guard`. Upgradable from the composer capsule or Settings.
  Migration: decode-missing `mode` → `guard`.
- Denied tool result: `{error:"denied by user — submit the form on
  acme.com", code:"DENIED"}`. System prompt gains one line: *"A denied call
  is the user's answer — say what you wanted and why; never retry it."*
  Codes: `DENIED`, `NEEDS_UI`, `MODE` (op above ceiling: `"act.submit is
  above read mode"`).
- A steer landing during a pending card reaches the model after the card
  resolves. Deleting the chat kills grants *and* pendings — one lifetime.
- Audit: every ask + verdict persists as note messages; `always` rules are
  in-memory per chat — a `agent.policy` debug op can dump them later.
