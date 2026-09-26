# Agent SDK — driving Search from outside

Two doors in: `./ask` for shells, `sdk/search_agent.py` for programs. Both
speak the op catalog in `PROTOCOL.md` over the same socket.

## The wire

`~/Library/Application Support/Search[ (world)]/agent.sock` is a Unix
socket (chmod 600, peer uid checked — the same user only). A connection
stays open and speaks JSON-lines: send `{"id": N, "op": "…", "args": {…}}`,
get `{"id": N, "result": {…}}` or `{"id": N, "error": "…"}` back, one
answer per request, several in flight at once under their own ids. Between
answers, sessions that sent `{"op": "subscribe", "args": {"events": ["*"]}}`
also receive `{"event": "…", "data": {…}}` — `tab.navigated`, `tab.added`,
`tab.title`, `tab.closed` for tabs the session owns or attached,
`lease.lost`, and `done` when nothing is pending.

```
→  {"id": 1, "op": "tabs.open", "args": {"url": "https://example.com"}}
←  {"id": 1, "result": {"id": "a1b2c3d4"}}
→  {"id": 2, "op": "page.snapshot", "args": {"tab": "a1b2c3d4"}}
←  {"event": "tab.navigated", "data": {"id": "a1b2c3d4", "url": "https://example.com/", …}}
←  {"id": 2, "result": {"snapshot": "- link \"More information...\" [ref=e2]", "version": 3, …}}
```

Tab ids are the first 8 lowercase hex chars of the tab's UUID. Ops that
name a tab take `"tab"` (`"id"` also works — bench's spelling). The
browser needs Settings › General › "Let a script drive Search" on.

## Python — `sdk/search_agent.py`

Stdlib only, Python ≥3.9. The reader thread demultiplexes the interleaved
stream: answers by id to their callers, events to a queue.

```python
from search_agent import Agent          # or: sys.path.insert(0, "sdk")

with Agent("test") as a:                # world: None → real browser,
    tab = a.open("https://example.com") #        "test" → Search (test),
    a.wait(tab)                         #        else → Search (NAME)
    print(a.snapshot(tab)["snapshot"])
    for ev in a.events(timeout=10):
        print(ev)
```

| Call | Op | Returns |
|---|---|---|
| `a.call(op, **args)` | any | raw `result` dict; `AgentError` on `{"error":…}` (`.code` e.g. `STALE_REF`), `SocketGone` when there's no listener |
| `a.ping()` | ping | `{pong: true}` |
| `a.tabs()` | tabs.list | `[{id,url,title,name,group,loading,bench,active,asleep,…}]` |
| `a.agent_tabs()` | agent.tabs | agent (⚗) tabs only |
| `a.open(url, foreground=None, space=None)` | tabs.open | new tab id — `space=` is sent through but this build's tabs.open ignores it |
| `a.attach(id, granted=False)` | tabs.attach | `{id, attached}` — a user tab must already be chip-granted in the app's Ask panel (`granted` is a compat shim, never sent — the wire can't grant) |
| `a.detach(id)` / `a.close(id)` / `a.select(id)` | tabs.* | result dict; `a.close()` bare hangs up the session |
| `a.go(tab,url)` `a.back(tab)` `a.forward(tab)` `a.reload(tab)` | page.* | `{id,…}`; reload wakes a sleeping tab |
| `a.wait(tab, seconds=None)` | page.wait | `{id,url,title,loading}` |
| `a.text(tab)` | page.text | `{text,truncated,url,title}` |
| `a.snapshot(tab, scope="viewport", boxes=False, max_chars=None)` | page.snapshot | `{snapshot,version,url,title,truncated}` — refs `[ref=eN]`, `loc=` handles |
| `a.screenshot(tab, path=None, marks=False, width=None)` | page.screenshot | `{path,width,height,format,data(b64)}`; no path → a tmp file, its path returned |
| `a.eval(tab, js)` | page.eval | the value — raw `evaluateJavaScript`, privileged |
| `a.code(tab, js)` | page.code | `{value,consoleLines}` — runs with `__drive` installed; prefer over many small calls |
| `a.console(tab)` / `a.frames(tab)` | page.console / page.frames | `[{level,text,when}]` / `[{ref,url,sameOrigin}]` |
| `a.click(tab, target, tier="auto", …)` | act.click | `target` = `e3`, `css:…`, `text:…`, `loc:…`, or `ref=`/`css=`/`text=`/`loc=` kwargs; extras pass through (`button`,`double`,`modifiers`,`withSnapshot`) |
| `a.fill(tab,target,text)` `a.type(tab,target,text,delay=ms)` | act.fill / act.type | a `text:` target can't ride as `text` (that's the payload) — the SDK sends it as an `xpath:` loc approximating the `text=` matcher: clickables/fields by their words or naming attributes; a miss answers `NOT_FOUND` |
| `a.press(tab,key,target=None,modifiers=[…])` | act.press | "Enter","Tab","Escape","a"… — a real NSEvent, focusing `target` first when given |
| `a.hover(tab,target)` `a.scroll(tab,"page",dx,dy,to_text=…)` | act.hover / act.scroll | |
| `a.select_option(tab,target,values)` | act.select | named so `select(tab)` stays "bring to front" |
| `a.check(tab,target,on)` `a.submit(tab,target)` `a.click_at(tab,x,y)` | act.* | |
| `a.lease(tab,on)` | agent.lease | the user's own input releases it → `lease.lost` |
| `a.probe()` | agent.probe | window/panel/group/active report |
| `a.groups()` | (via probe) | `[{id,title,colour,icon,expanded,count}]` |
| `a.spaces()` | (via probe) | the spaces list from the probe report (`spaces`/`spacesOn`/`space`) |
| `a.ask_open(on)` | ui.ask | `{open: bool}` — the op also takes `send:"text"` (a real Ask turn; `a.call("ui.ask", send="…")` → `{open, ok, chat}`), `steer:"text"` (`a.steer`), `stop:true` (`a.stop_ask`) |
| `a.subscribe(["*"])` `a.next_event(timeout)` `a.events(timeout)` | subscribe | `{event,data}` dicts; the generator ends after `timeout` silent seconds or when the socket dies. `subscribe([])` subscribes to nothing — how a session goes quiet without hanging up |

`Agent()` connects lazily — first call or `connect()`/`with`. One `Agent`
is safe to share between threads; calls can be in flight together.

## CLI — `./ask`

Sibling to `bench` — one session per command, same `--test` / `--world
NAME` flags. Objects print as pretty JSON, snapshot/text raw, errors go to
stderr with exit 1. Global flags (`--test`, `--world NAME`) lead
the command; a verb's own flags come after it — past the verb a bare
`--…` word is payload (`type ID e3 --yes` types "--yes").

```
ask tabs                    ask open URL [--foreground]    ask attach ID
ask go ID URL               ask text ID                    ask snap ID [--full] [--boxes] [--max-chars N]
ask shot ID [PATH] [--marks] [--width N]                   ask eval/code ID JS
ask click ID REF|css:SEL|text:STR [--tier T] [--double] [--button B] [--modifiers M,…]
ask fill ID REF STR         ask press ID KEY [REF] [mods…] ask scroll ID [REF|page] [DY] [--dx N] [--to-text S]
ask type ID REF STR [--delay MS]   ask hover/check/submit/choose/clickat …
ask console ID              ask frames ID                  ask wait ID [N]
ask close ID                ask lease ID on|off            ask panel on|off
ask events                  subscribe ["*"] and print event lines until Ctrl-C
```

`attach` on one of the user's own tabs fails until the tab is chipped in
the app's Ask panel — the wire can't grant anything; the chip is the one
grant, arriving as `tabs.grant` on the in-app door alone. While the
consenting chat lives, the tab attaches from any session; a new or
deleted chat clears every grant. Unchipped, the attach fails with
`… needs its chip in Ask — the wire can't grant it`.

## If it were TypeScript

No JS implementation here — the mapping is the whole spec:

```ts
// a session = one socket, JSON lines
send({ id: n, op: "page.snapshot", args: { tab, scope: "viewport" } });
// onLine: "id" in msg → resolve pending.get(msg.id) with
//         msg.result ?? reject(msg.error);  "event" in msg → emit to subscribers

type Op =
  | "ping" | "subscribe"
  | "tabs.list" | "tabs.open" | "tabs.attach" | "tabs.detach"
  | "tabs.close" | "tabs.select"
  | "tabs.grant" // exists, but the in-app door alone may speak it — refused on the socket
  | "page.go" | "page.back" | "page.forward" | "page.reload"
  | "page.wait" | "page.text" | "page.snapshot" | "page.screenshot"
  | "page.eval" | "page.code" | "page.console" | "page.frames"
  | "act.click" | "act.fill" | "act.type" | "act.press" | "act.hover"
  | "act.scroll" | "act.select" | "act.check" | "act.submit" | "act.clickAt"
  | "agent.tabs" | "agent.probe" | "agent.lease" | "ui.ask";

type Event =
  | "tab.navigated" | "tab.closed" | "tab.added" | "tab.title"
  | "lease.lost" | "done";
```

## Security notes

- **Same-user only — and that's the whole boundary.** The socket is
  chmod 600 in the app's own folder and the peer's uid is checked on
  accept — another user can't connect, and nothing here should weaken
  that. Everything a session may do is gated by exactly this check.
- **Consent lives in the app — never on the wire.** The only grant a
  user tab can get is its chip added in the Ask panel: the chip arrives
  as `tabs.grant`, an op the in-app door alone accepts (the socket is
  refused — `the wire can't grant a tab`), and the model's own tool
  calls can neither name `tabs.grant` nor carry `granted` (the key is
  stripped before dispatch). `granted:true` on `tabs.attach` is refused
  on every door — `granted isn't an attach argument — grants come
  through the grant door` — so no client, same uid or not, can assert a
  consent it wasn't given. Attaching a tab nobody chipped fails with
  `… needs its chip in Ask — the wire can't grant it`; once the chip is
  there, any session may attach that tab by name — for the consenting
  chat's lifetime: a new or deleted chat clears every grant. What a
  person granted in the panel is what the agent layer may drive — and
  the transport is still only the same-user check, so every process
  running as you shares in whatever was granted.
- **Attaches are per-session; the consent is the driver's.** A session
  reads and drives only tabs it opened or attached itself — one client's
  attach isn't another's (a second session attaches the granted tab
  afresh). The `grantedTabs` consent lapses when the last holder lets
  go — `tabs.detach`, a disconnect, the tab closing, the app exiting —
  and one session's detach can neither burn the chip's grant out from
  under a live holder nor end another session's hold.
- **`page.eval`/`page.code` are privileged.** Full JavaScript in the page's
  context, as the signed-in user — the escape hatch is deliberately sharp.
- Agent tabs (⚗) stay out of history and session, and `tabs.close` can
  only touch those — the socket can't close the user's tabs or read one
  this session hasn't attached.
- Foreground actions on the real window (`tabs.select`, `tabs.open
  foreground`, the `event` input tier) are deliberately allowed only for
  tabs that are agent-opened or attached, and `agent.lease` hands a tab
  back the moment its owner touches it.
