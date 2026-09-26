# Ask — interaction designs: ask_user, retry, fork

Three features on the one loop. Shared spine: the bridge's `kind:"tool"`
is already async — `tool()` parks a Promise in `pendingTools` until
`__h._tool(id, result)` lands — so a tool that waits on a *person* needs
no new loop machinery, only a new endpoint on the Swift side.

## 1. `ask_user` — the agent asks mid-turn

**Tool def** (harness.js `TOOLS`; `op` names a door, not a Drive op):

    { name: 'ask_user', op: 'ask.user',
      description: 'Ask the user a question and wait — for a choice only
      they can make or facts no tab holds. Result is {answer:"…"} or
      {declined:"dismissed"|"timeout"|"busy"}; a declined question means
      make your own call and say what you assumed. options[] become
      quick-pick pills; free text is always allowed.',
      params: obj({ question:{type:'string'},
                    options:{type:'array',items:{type:'string'}} }, ['question']) }

SYSTEM gains a line: 'ask_user when you need the human — declined answers
mean decide yourself.'

**Loop: unchanged.** `tool('ask.user',…)` parks like any call; `kill(ctx)`
still flushes it `{error:'stopped'}` on stop. `cardSink` emits the tool
card *before* the await, so the card exists when the question lands.

**Swift side** — `Harness.tool(_:)` intercepts before Drive (like the
`tabs.grant` refusal, `ask.user` must never reach `serve`):

    private var pendingAsk: Int?                    // bridge id, one at a time
    // in tool(_:), after the granted-strip:
    if name == "ask.user" { poseAsk(id, args); return }

    func poseAsk(_ id: Int, _ args: [String: Any]) {
        guard pendingAsk == nil else { toolReply(id, ["declined":"busy — another question is open"]); return }
        guard let chat = activeChat else { toolReply(id, ["declined":"unavailable"]); return }
        pendingAsk = id
        Mind.shared.pose(args["question"] as? String ?? "",
                         options: args["options"] as? [String] ?? [], in: chat)
    }
    // pendingAsk = nil also in run() and on the done for activeChat —
    // after a kill the JS promise is already force-resolved, so a late
    // resolveAsk is a no-op, but the seat must free for the next turn.

**Protocol** — `AskEngine` extension grows a no-op (the `sync()` pattern):

    func resolveAsk(_ result: [String: Any]) {}
    // Harness: guard let id = pendingAsk else { return }
    //          pendingAsk = nil; toolReply(id, result)

**Mind state:**

    @Published private(set) var question: AskQuestion?
    private var questionClock: Task<Void,Never>?

    func pose(_ text: String, options: [String], in chat: UUID) {
        question = AskQuestion(chat: chat, text: text, options: options)
        open = true            // asking is deliberate attention-seeking
        let q = question!
        questionClock = Task { try? await Task.sleep(for: .seconds(300))
            guard question?.id == q.id else { return }
            resolveAsk(["declined":"timeout"]); question = nil }
    }
    func answer(_ text: String) { questionClock?.cancel(); engine?.resolveAsk(["answer": text]); question = nil }
    func pass()               { questionClock?.cancel(); engine?.resolveAsk(["declined":"dismissed"]); question = nil }

`hear(.done)` clears `question` when `question?.chat == chat` (a stopped or
finished turn isn't waiting on anyone).

**The card is the tool row.** AskUI special-cases `tool.name == "ask_user"`
in `AskLine.agent` → `QuestionRow` instead of `ToolRow`:

- pending (`live && tool.result == nil && mind.question != nil`):
  question text, one `Pill` per option (tap → `mind.answer(option)`), a
  TextField + send → `mind.answer(field)`, "Skip" → `mind.pass()`. The
  full text comes from `mind.question` — the card's args are trimmed.
- settled: one line, `ask_user  "…question…" → "…answer…"`.
- ended unanswered (`result == nil && !live`, incl. after relaunch):
  "went unanswered" — honest, same shape as `ended` tools.

**Composer while a question is open** — `Mind.steer` changes one branch:

    if let q = question, q.chat == chat.id { answer(words) } else { engine?.steer(words) }

The `.you` message still lands first — it *is* the visible answer. It must
NOT also engine.steer: the loop is parked inside `await tool(...)`, so a
steer would just queue unread until the question resolves — the composer
*is* the answer box. Bonus: `ui.ask{steer}` on the socket answers too.

**Edges**
- Second `ask_user` while one is open → `{declined:"busy"}`.
- Panel shut / socket-started turn → panel opens on pose; nobody answers
  → 300s timeout → `{declined:"timeout"}`. No queueing.
- Webview crash / quit → ctx dies with it; saved chat reads "went unanswered".
- History hole this widens: `toHistory` replays calls whose `result == null`
  as bare tool_calls → provider 400s. Fix once: push synthetic
  `{role:'tool', text:'(ended before it answered)'}` for unresolved calls.
- Declined ≠ failed: no `error` key, card reads "asked, declined".

## 2. retry — re-run a turn, optionally on another brain

    /// Re-run from a user message: drops everything after it and sends it
    /// again. `brain` becomes the chat's model — sticky for the rest of
    /// the chat; `mind.model` (the new-chat default) untouched.
    func retry(from message: AskMessage, with brain: AskModel? = nil)

    guard let chat = current, !running,
          let at = chat.messages.firstIndex(where: { $0.id == message.id }),
          chat.messages[at].role == .you else { return }
    var copy = chat
    copy.messages = Array(copy.messages.prefix(through: at))  // the .you stays
    copy.messages[at].retries += 1            // new field: var retries = 0
    if let brain { copy.model = brain.id }
    copy.turn = UUID()                                        // see below
    store(copy)
    engine?.run(AskJob(chat: copy, tabs: message.attachments, text: message.text))

Checkpoint = the user message itself: the weak reply, its tool cards and
any error `.note` after it are dropped. The kept `.you`'s attachments go
back through `attachTabs` — chips re-grant, consent reapplies.

**Truncates, doesn't fork** — destructive like regenerate. No `.note`
marker — the model would read `[note: retried]` noise; the bubble gets a
quiet badge from `retries` ("· retried ×2") which the model never sees.

**Stale events (the real hazard):** a killed turn still emits trailing
`message`/`done` — `stop()` sets running=false instantly but the JS tail
lands after, and `hear` folds by chat id → resurrected reply. Guard with a
turn stamp: `var turn: UUID?` on `AskChat` (Codable; set on every
send/retry) → `AskJob` carries it inside `chat` → harness.js reads
`job.chat.turn` → every emit's `data.turn` → `Harness.event()` drops
delta/message/tool whose `turn != lastRunTurn`. Also closes today's
send-after-stop resurrection hole.

**UI affordances:** contextMenu on `.you` bubbles — "Retry from here" +
"Retry with…" submenu (the model list); plus a quiet "↻" row under the
tail agent message when `!mind.running`. Hidden while running.

**Edges**
- Retry mid-turn: refused by the guard.
- Mid-chat retry on an old `.you`: drops all later turns — the menu says
  "from here".
- Retry of a tooled turn: re-drives from scratch — tabs/refs may be dead;
  the old cards are gone with the truncation so the model isn't reading
  stale results.

## 3. fork — branch a chat

    /// AskChat gains:  var parent: UUID?     // optional → old files decode nil

    /// Branch at a message (nil = the whole chat) — a pure clone,
    /// persisted at once, becoming current. Nothing re-runs.
    func fork(from message: AskMessage? = nil) {
        guard let chat = current else { return }
        var copy = AskChat()
        copy.parent = chat.id
        copy.model = chat.model
        copy.title = chat.title + " (fork)"
        copy.messages = message
            .flatMap { m in chat.messages.firstIndex { $0.id == m.id } }
            .map { Array(chat.messages.prefix(through: $0)) } ?? chat.messages
        copy.when = Date()
        chats.insert(copy, at: 0); AskStore.save(copy)
        currentID = copy.id; context = []
        AskRuntime.drive?.perform("tabs.ungrantAll", [:], from: .app) { _ in }
    }

Model context: `job.chat.messages` is the cloned prefix — the agent
continues as if it said those things itself (claims clicks it never took
in this timeline — accepted, same as ChatGPT branching; `toHistory`
already filters ragged tool tails).

Grants/contexts do NOT carry: `context` emptied, `tabs.ungrantAll` like
`newChat` — consent was the parent's chat's. Caveat: grants are
app-session-global — forking a chat whose turn is still running starves
that parent's tab access mid-flight. Rare; documented, not fixed.

**UI affordances:** contextMenu on every `AskLine` — "Fork from here";
contextMenu on `ChatRow` — "Fork" (whole chat); `ChatRow` shows a small
"⑂" when `chat.parent != nil`.

**Edges**
- Fork while running copies messages as they stand; the parent's turn
  keeps writing to the parent (events are chat-scoped — never leak).
- Fork of a fork: `parent` is the immediate source — fine.
- Message-level fork mid-turn may end inside a tool batch — harmless.
