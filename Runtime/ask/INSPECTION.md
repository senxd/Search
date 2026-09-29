# Browser automation and inspection

Search exposes its WebKit inspector protocol alongside the existing page and
input commands. It is **WebKit protocol**, not a CDP compatibility layer.
Discover commands and parameters on the running OS instead of assuming Chrome
domain names. The connection uses guarded private WebKit inspector APIs; an OS
without those APIs returns an explicit error.

## Persistent programs

Use `sdk/search_agent.py` or `./ask run program.py` for a workflow. The latter
provides a connected `agent` variable. A socket connection owns its tabs and
receipts. Single-command CLI invocations are separate connections; an `open`
followed by a separate `eval` invocation is not a persistent workflow.

```python
# Run with ./ask --world test run draft.py
tab = agent.open("https://example.com", agent_name="Research")
agent.wait(tab)
print(agent.snapshot(tab, interactive=True)["snapshot"])
# Finish editing a draft, then hand over the existing live page.
agent.surface(tab)
```

## Agent tabs and handoff

Background tabs appear in an Agent tabs dropdown, grouped by session and optional
`agentName`. Selecting a row previews it; Keep moves that same tab into the normal
tab bar. `tabs.surface {tab, foreground?:true}` is the programmatic equivalent.
It preserves the tab ID, WKWebView, document, form values and JavaScript state.
A small flask identifies a kept tab. The tab survives disconnect and cannot be
closed through the agent-only `tabs.close` operation. Other sessions still need
the user's consent before attaching it. The originating session can finish
reading it until it disconnects or detaches.

Normal session restoration retains the URL and indicator. It does not promise
to restore unsaved form contents after quitting the browser.

## Engine protocol

| Operation | Arguments | Result |
|---|---|---|
| `inspector.attach` | `tab` | `protocol`, `mainTargetID`, `targets`, `backend`, command parameter and event descriptions |
| `inspector.send` | `tab`, `method`, `params?`, `targetId?`, `save?` | Raw protocol result or a protocol error |
| `inspector.events` | `tab` | Drains this session's bounded event history; `dropped` reports overflow |
| `inspector.detach` | `tab` | Releases this session's connection |
| `inspector.read` | `tab`, `path`, `offset?`, `length?` | UTF-8 text chunk, `nextOffset`, `eof`; only artifacts belonging to this tab |

Protocol results above 256 KB, results requested with `save:true`, and events
above 64 KB return an `artifact` with `path`, `bytes`, and `format:"json"`.
Read that JSON file for the full result, or use `inspector.read` /
`a.inspector_read` to inspect it from an agent without filesystem access. The world-specific artifact directory
retains at most 32 files and 128 MiB, evicting oldest files; copy evidence you
need to keep. A single artifact above 128 MiB returns an explicit error.
The polling history retains 64 event records per tab and session. Expired
artifact records are omitted and counted as dropped when history is drained.

External clients can `subscribe(["inspector.event"])` to receive live events.
Small events contain `tab`, `targetID`, `method`, and `params`. Large events
contain `artifact` instead of inline parameters. Worker targets can be
selected with `targetId`. On this WebKit version, cross-origin frames have
execution contexts: match `Runtime.executionContextCreated` against the frame
ID from `Page.getResourceTree`, then use `Runtime.evaluate` with `contextId`.
Refresh targets/contexts after navigation. Remote object IDs and object groups
use WebKit's Runtime commands and must be released when finished.

```python
capabilities = agent.inspector_attach(tab)
value = agent.inspector_send(tab, "Runtime.evaluate", {
    "expression": "document.title", "returnByValue": True
})
print(value)

agent.inspector_send(tab, "Network.enable")
# Navigate or trigger the request after enabling capture.
agent.go(tab, "https://example.com")
agent.wait(tab)
events = agent.inspector_events(tab)["events"]
for event in events:
    if event.get("method") == "Network.loadingFinished":
        body = agent.inspector_send(tab, "Network.getResponseBody", {
            "requestId": event["params"]["requestId"]
        })
```

The inspector frontend enables some domains itself. Re-enabling those may return
an engine "already enabled" error. This is a real shared inspector connection;
debugger/profiler settings affect other clients inspecting the same page.

## Profiles and debugging

The tested WebKit build supports `ScriptProfiler.startTracking` with
`includeSamples:true`, `ScriptProfiler.stopTracking`, `CPUProfiler.startTracking`,
`CPUProfiler.stopTracking`, and `Heap.snapshot`. Script samples arrive in
`ScriptProfiler.trackingComplete`; CPU updates arrive as events. These names
and outputs differ from Chrome's `Profiler` and `HeapProfiler` domains.

```python
agent.inspector_attach(tab)
agent.inspector_send(tab, "ScriptProfiler.startTracking", {"includeSamples": True})
agent.inspector_send(tab, "CPUProfiler.startTracking")
# Exercise the page while recording.
agent.inspector_send(tab, "CPUProfiler.stopTracking")
agent.inspector_send(tab, "ScriptProfiler.stopTracking")
profile = agent.inspector_events(tab)
agent.inspector_detach(tab)
```

Use the discovered Debugger commands for breakpoints, pause/resume and stack
inspection. Closed shadow roots, browser permissions, emulation and service
workers are available only to the extent the installed engine exposes them;
the page helper does not invent fallback implementations.

## Objects and engine console

For objects too large or cyclic to serialize, keep a remote handle and request
its properties. Release the object group when finished; navigation invalidates
its handles.

```python
obj = agent.inspector_send(tab, "Runtime.evaluate", {
    "expression": "document.body", "objectGroup": "inspection"
})["result"]
try:
    properties = agent.inspector_send(tab, "Runtime.getProperties", {
        "objectId": obj["objectId"], "ownProperties": True
    })
finally:
    agent.inspector_send(tab, "Runtime.releaseObjectGroup", {
        "objectGroup": "inspection"
    })
```

The `page.console` shortcut uses the injected collector. Engine console output
is available as `Console.messageAdded` through inspector events. Attach before
the activity you need to capture. Neither route promises an unlimited history
of messages emitted before attachment.

## Network interception and traces

Use `Network.addInterception` with a URL and `stage:"request"` or
`stage:"response"`, then handle `Network.requestIntercepted` or
`Network.responseIntercepted`. Finish each intercepted request with
`Network.interceptContinue`, `Network.interceptWithRequest`,
`Network.interceptRequestWithResponse`, or `Network.interceptWithResponse`,
as appropriate for its stage. Discover the required parameters first.
Trigger the request without awaiting its completion, then consume the event
and answer it. Waiting for the fetch first would wait on your own interception.

Search keeps agent interception rules separate from the inspector frontend's
automatic handling. Detaching or disconnecting the controlling session removes
its rules and continues pending requests. Inspector state remains shared with
other clients, so avoid changing rules owned by another client.

WebSocket handshake, sent/received frame and close events use the `Network`
domain. `Timeline.start` and `Timeline.stop` collect `Timeline.eventRecorded`
events for execution and rendering traces. Read events throughout long captures
to avoid the bounded history dropping older records.

## Native dialogs and file choosers

`page.dialogs {tab,enabled:true}` opts a session into handling native JavaScript
dialogs and file choosers for that tab. Enable it before triggering the dialog.
Read `page.dialogs {tab}` or subscribe to `page.dialog` for a pending dialog's ID.
Use `page.dialog {tab,dialog,accept,text?}` for alert/confirm/prompt, or
`page.files {tab,dialog,paths:[absolute paths]}` for a file chooser. Empty paths
cancels file selection. Paths must exist, be readable, and satisfy the chooser's
single/multiple/directory constraints. Pending dialogs dismiss after 120 seconds
or when their controlling session leaves. One session controls a tab's dialogs
at a time. These operations and raw inspection are privileged in Guard mode.

## Snapshots and input

Snapshots accept `interactive:true`, `selector`, or `ref` to reduce the result,
and traverse open shadow roots and same-origin frames. Cross-origin page execution
is available through the inspector. Default clicks use one native gesture after
actionability checks. A covered element is refused. `tier:"js"` explicitly requests
synthetic input; a lack of DOM changes never causes a second click.

## Cancellation and limits

Each request ID must be a nonempty string or safe integer, unique while its receipt
is retained. `request.status {requestId}` reads the original operation's status.
`request.cancel {requestId}` requests cooperative cancellation. Native typing
checks between characters; its final receipt records `typedCount`. Arbitrary page
JavaScript may continue: cancellation or a timeout can return **running / unknown**.
Do not retry such a mutation blindly. Inspect its receipt or wait for the scoped
`request.finished` event. Receipts record completion metadata, not full result data.

The socket allows 64 pending requests per session, 256 retained terminal receipts,
32 sessions and 256 underlying operations globally. Status and cancellation remain
available at the per-session pending limit. Outgoing socket buffering is capped
at 8 MB; clients must drain events. The Python SDK bounds its event queue and
exposes `dropped_events`. Reconnection is explicit and starts a new session.

## Aside comparison

Two GPT-6 Luna agents inspected Aside 1.26.916.1741 using `aside guide`,
`aside guide repl`, and CLI help. Their work was read-only. The documented REPL
is persistent with a 120-second timeout; it exposes `listBrowserTabs`,
`attachBrowserTab`, `openTab`, `closeTab`, interactive/scoped snapshots and
Playwright-style page methods. Its docs do not establish a raw CDP connection,
profiler API, or promote-to-user-tab operation. Search makes those inspection
and handoff capabilities explicit. No undocumented Aside behavior is assumed.

## Checks

- `bun Runtime/ask/drive.test.js`
- `bun Runtime/ask/test/harness.unit.bun.js`
- `bash Tests/Inspector/run.sh`, real WebKit protocol and profiler checks
- `python3 Tests/Agent/check.py WORLD`, isolated Search app integration
- `python3 Tests/Agent/input_check.py WORLD`, local input and idle steering checks; configure the world with `echo/echo`
- `python3 sdk/check_request_lifecycle.py WORLD --server-timeout`
- `python3 Runtime/ask/bench/check.py`, benchmark preflight and error classification

Only use a test world for the live checks. Close its dev application afterward.

The expanded native checks cover request/response bodies, profiling, heap data,
cross-origin contexts, workers, console events, remote objects, WebSockets,
timeline events, and breakpoint pause/stack evaluation/stepping/resume.
Local input and handoff checks pass. The latest model-driven scenario rerun was
blocked by Codex HTTP 401 and OpenRouter HTTP 402; it provides no new model
success rate. Mid-turn steering has harness coverage but was not reverified
against a live model in that run.
