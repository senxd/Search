# Benchmarking Ask — a scenario harness

Ask is benchmarked end-to-end: a scenario is a prompt posted through
`ui.ask {send}` — the real composer path — plus a machine-checkable verify.
One fresh world per run; per-scenario isolation is a fresh chat, not a
fresh world.

## Transports — and why there are two

The runner keeps **two** doors open (both behind the `bench` pref, opened
together by `Bench.start` → `AgentSocket.start`):

- `agent.sock`, via `sdk/search_agent.py`'s `Agent`, for `ui.ask`
  {open,send,steer,stop} and `tabs.list`. Ownership bites here: a tab the
  in-app agent opens belongs to the `.app` session, and one the runner's
  socket opens belongs to the runner — neither can drive the other's.
- `bench.sock`, a one-request-per-connection socket (the `./bench` script's
  `ask()`), for everything else: `open` makes **loose** bench tabs that
  belong to no session — the in-app agent attaches them freely — and
  `eval`/`tabs`/`sleep`/`pin`/`close all`/`winshot` work on **any** tab,
  no consent needed. All verification and setup run here.

Turns are tracked through the chat file, not the socket: `ui.ask send`
answers `{open,ok,chat:<uuid>}` and Mind persists
`<world>/chats/<uuid>.json` on send ([you]), on the final agent message,
and on done-with-error ([note]). Deltas/tool cards never write — so
**turn over ⇔ newest message role ∈ {agent,note} and the file's mtime has
been quiet ≥1.5 s** (`until:"quiet"` just waits mtime-quiet — for `stop`).
The socket's `done` event is pending-ops, unrelated.

## Scenario format — `Runtime/ask/bench/scenarios/*.json`

```json
{
  "name": "form-fill", "tags": ["form"],
  "prompt": "Fill the form: name Ada Lovelace …",
  "setup": {"tabs": [{"url": "fixture:form", "as": "f", "via": "bench",
                      "pin": false, "sleep": false}]},
  "drive": [{"sleep": 6}, {"steer": "…"}, {"stop": true}],
  "verify": {"kind": "js", "tab": "f", "js": "…predicate…"},
  "timeout": 90
}
```

- `fixture:<name>` → `http://127.0.0.1:<port>/<name>.html` from
  `Runtime/ask/bench/fixtures/` (a `python3 -m http.server` the runner owns).
  `via`: `bench` (default — loose, agent-drivable) · `agent` (runner's
  `a.open` — agent can't attach it; verify-only) · `user` (navigate the
  world's blank first tab via bench `go` — non-bench, unattachable).
  `pin:true`/`sleep:true` ride along via bench `pin`/`sleep`.
- `drive` steps run after send, before wait: `sleep`/`steer`/`stop`/`send`.
- `verify` kinds — `{"kind":"js","tab":"last|first|<as-name>|<id-prefix>","js":…}`
  (bench `eval` → `{value}` truthy) · `{"kind":"chat","expect":"<regex>","i":true,"negate":false,"all":false}`
  (last agent text; `all` = every agent text) · `{"kind":"tool","name":"click","minCalls":2,"failed":false}`
  (counts `tools[]` cards in agent messages) · `{"kind":"tabs","url":"<glob>","bench":true,"min":1}`
  (bench `tabs`, fnmatch) · `{"kind":"stopped","within":15}` (file quiet
  after `stop`) · `{"kind":"all"|"any","checks":[…]}` composites.
- `timeout` default 90 s. `skipIf`: `"noImages"` (echo/devin providers),
  `"offline"` (a real-site probe at run start fails).

## The catalog (25 scored + 1 preflight)

| name | setup | prompt (abbrev.) | verify |
|---|---|---|---|
| nav-title | — | open example.com, tell me its title | chat `Example Domain` + tool tab_open |
| nav-back | links page | open link three, go back, what's the title | chat regex + tool `back` ≥1 |
| tab-trio | — | open fixture links+counter+dashboard | tabs glob `127.0.0.1*` min 3 |
| snap-buttons | dashboard | list the buttons on "Mission Control" | chat names ≥3 of Deploy/Abort/Ping/Reset |
| snap-text | longscroll | what's the first row's label | chat `row 1` |
| extract-links | links | hrefs of the first three links | chat `link-0.*link-1.*link-2` ordered |
| form-fill | form | fill Ada Lovelace / ada@x.com / France / agree / submit | js `#result` has `CONF-741` ∧ `Ada` |
| form-enter | keys | focus field, type "hello world", press Enter | js `#log li` count 1 |
| click-2nd | links | click the second link | js pathname ends `link-1.html` |
| click-trusted | trusted | click "Vote" | js count==1 (auto→event escalation) |
| click-covered | covered | click "Buy" | js `#bought` visible (must Dismiss first) |
| stale-retry | stale | click "Sync"; retry if it fails | js `#synced` set (STALE_REF recovery) |
| flaky-order | flaky | place the order | js reached `ordered.html` (1st click fails) |
| multi-compare | a+b open | which open page is cheaper | chat `43`|`compare-b` |
| scroll-end | longscroll | scroll to the bottom, read the last line | chat `THE END` + js sentinel in DOM |
| iframe-count | frames | click the button *in the frame*, report count | chat `1` + js frames[0] counter |
| read-console | buggy page | is the page logging errors? | chat /error/ + tool `console` |
| vision-canvas | canvas | what word is in the blue box | chat `TEMPO` (skipIf noImages) |
| consent-pin | user tab pinned | close my pinned tab "Pinned Keepsake" | chat refusal regex ∧ tabs still lists it |
| sleeper | bench-open+sleep | the "Sleeping Nook" tab — first heading? | chat `Rise and Shine` + tool reload |
| steer-mid | — | long count task; drive: sleep 6 → steer "just say DONE" | chat last agent `DONE` |
| stop-mid | — | long task; drive: sleep 5 → stop | stopped within 15 s |
| long-chain | form | fill Grace Hopper, submit, then open links, click first link | all[ js link-0 landed, chat regex ] |
| real-example | — | example.com — what's the domain for | chat `illustrative|examples` (skipIf offline) |
| real-httpbin | — | httpbin.org/forms/post, custname "Test Person", submit | chat `Test Person` (skipIf offline) |
| real-wiki | — | en.wikipedia.org, search "Bicycle", first sentence | chat `bicycle` + tool count ≥2 |
| **preflight** | — | "Reply with exactly: OK" | unscored: decides the provider |

## Fixtures — `Runtime/ask/bench/fixtures/`

`dashboard` (4 labelled buttons, title "Mission Control") · `form` (name/
email/select/checkbox; submit → `#result` "CONF-741", client-side) ·
`longscroll` (200 rows; `THE END` lazily inserted near bottom) · `counter`
· `trusted` (button counts only `e.isTrusted` clicks — the JS tier's
`ignored` flag → real-NSEvent escalate) · `covered` (Buy under a
dismissible overlay — COVERED escalation lands on the occluder; Dismiss
then Buy is the honest path) · `links` (8 links → `link-N.html`, title
"Link N") · `keys` (Enter appends `<li>`) · `stale` (container innerHTML
rebuilt every 2 s — refs rot) · `flaky` (first Order click says "try
again", second navigates) · `frames` (embeds counter) · `canvas` ("TEMPO"
drawn, not in DOM) · `sleeper` (title "The Sleeping Nook", h1 "Rise and
Shine") · `about` (title "Pinned Keepsake", the user tab) ·
`compare-a`/`compare-b` (same page, price 41 vs 43) · `buggy`
(console.error on load) · `ordered` (form/confirm target).

## Runner — `Runtime/ask/bench/run.py` (stdlib + sdk/)

```
python3 Runtime/ask/bench/run.py [--model openai/gpt-6-luna] [--suite form,ui]
    [--world NAME] [--reuse] [--app build/Search.app|.build/debug/Search]
    [--port 8877] [--keys PATH] [--timeout 90]
```

1. world `bench-<ts>` (or `--world`): wipe the fresh.sh triad — `rm -rf
   ~/Library/Application Support/Search (<w>)`, `defaults delete
   com.officecommun.search.test.<w>`, `rm -rf
   ~/Library/WebKit/com.officecommun.search/WebsiteDataStore/<5E4C-hash>`
   (Store.probeStore FNV-1a, fresh.sh:23-35) — unless `--reuse`.
2. `defaults write <suite> bench -bool true`, `welcomed -bool true`,
   `ask.model -data <hex(JSON {"provider":p,"model":m})>` — read once at
   Mind init, so model changes need a launch.
3. Stage keys: copy `ask.keys.json` from the real world — or `--keys` —
   into the world dir, chmod 600.
4. Launch `SEARCH_PROBE=<w> <binary>` (direct exec keeps the pid for kill);
   wait for `agent.sock` to exist + `a.ping()`.
5. Fixture server up; `ui.ask {open:true}` so winshots show the rail.
6. **Preflight**: send "Reply with exactly: OK". A `note` matching
   `^openrouter (400|404)|no endpoints|not a valid model` → rewrite
   ask.model to `{"provider":"codex","model":<model basename>}`, relaunch
   once, record `model_effective`. `--model echo` needs no keys.
7. Per scenario: `ui.ask {new:true}` → setup tabs →
   `ui.ask {send:prompt}` → drive steps → wait until reply/quiet/timeout
   → verify via bench.sock → `bench winshot bench/shots/<name>.png` →
   `bench close all` → row `{name, ok, seconds, toolCalls{}, chat, detail,
   shot}`.
8. Write `Runtime/ask/bench/results-<ts>.json` + `summary-<ts>.md`
   (pass table + rate), copy the world's `chats/*.json` beside them.

## The one code addition

`ui.ask` has no way to start a fresh chat (`Mind.newChat` is UI-only and
clears tab grants — exactly the per-scenario isolation wanted). Add to
`Drive.ask`:

```swift
if args["new"] as? Bool == true { Mind.shared.newChat(); reply["ok"] = true; reply["newChat"] = true }
```

Runner probes it once (reply lacking `newChat` → `isolation:"shared"`,
scenarios keep working but share one chat — flagged in the report).

## Guardrails

- timeout → `ui.ask {stop:true}`, `ok:false, reason:"timeout"`; the app
  dying (SocketGone mid-scenario) → `crash`, one relaunch, abort on second.
- No scenario retries. A `note` matching `429|rate.?limit|5\d\d` → one
  backoff (sleep 20 s, resend, `rateLimited:true`) — transport healing,
  not a re-score.
- `--suite` matches tags/names. `skipIf noImages` reads the provider
  table; `offline` if example.com unreachable at start.
- Cost: ~25 scenarios × 2–8 model turns each + tool calls; single-digit
  dollars on a paid openrouter model — `results-*.json` records
  `model_effective` beside every row.
- bench.sock `winshot`/`eval`/`sleep`/`pin`/`close all` are test-run-only
  or user-tab-capable by design — fine here because the world is a probe,
  and the reason they must never run against the real browser.
