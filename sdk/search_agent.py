"""search_agent — the external SDK for Search's agent socket.

The running browser listens on a Unix socket —
``~/Library/Application Support/Search[ (world)]/agent.sock`` — and speaks
JSON-lines: requests ``{"id": N, "op": "…", "args": {…}}`` are answered
``{"id": N, "result": {…}}`` or ``{"id": N, "error": "…"}``, and sessions
that sent ``{"op": "subscribe", "args": {"events": ["*"]}}`` also receive
``{"event": "…", "data": {…}}`` lines between answers.  The op catalog is
Runtime/ask/PROTOCOL.md; this module is a stdlib-only (Python ≥3.9) client
for it.

Canonical use::

    from search_agent import Agent

    with Agent("test") as a:                    # the SEARCH_PROBE=test world
        tab = a.open("https://example.com")
        a.wait(tab)
        print(a.snapshot(tab)["snapshot"])

``world`` names the run, exactly like ``Store.world`` and ``bench``:
``None`` is the real browser ("Search"), ``"test"`` is "Search (test)", and
anything else is "Search (<world>)".  Connecting is lazy — ``Agent()`` does
nothing until ``connect()`` (or the first call), so a client built for a
browser that isn't up fails at first use, not construction.
"""

import json
import os
import queue
import socket
import tempfile
import threading
import time

__all__ = ["Agent", "AgentError", "AgentTimeout", "SocketGone", "socket_path", "world_folder"]

_NOT_GIVEN = object()
_EVENT_END = object()          # pushed on the event queue when the socket dies

# The act verbs the server's query() won't read `text` as a locator for —
# Drive.swift excludes them because `text` is (or could be) the payload:
# fill's and type's value, press's and clickAt's for uniformity.  For
# those, a `text:` target can't ride the wire as {"text": …}.
_NO_TEXT_QUERY = frozenset(("fill", "type", "press", "clickAt"))


def _xpath_literal(s):
    """``s`` as an XPath string literal — concat() when both quotes show."""
    if '"' not in s:
        return f'"{s}"'
    if "'" not in s:
        return f"'{s}'"
    return "concat(" + ', \'"\', '.join(f'"{p}"' for p in s.split('"')) + ")"


def _text_xpath(text):
    """``text:`` said as ``xpath:`` for the verbs that can't carry a
    ``text`` locator — ``loc`` itself has no ``text:`` scheme (drive.js's
    resolve takes loc:css/role/href/xpath only).  The shape of the text=
    matcher it stands in for: the clickables (button, a, summary, the
    button/link/tab roles) by their visible words, value-named inputs by
    @value, then fields and widgets by the attributes that name them —
    exact, whitespace-collapsed, case-folded on both sides.  What the
    matcher's second pass alone could reach — names computed from
    <label>s, legends, aria-labelledby — has no honest xpath; a target
    only it would find answers NOT_FOUND like any locator that misses.
    """
    want = _xpath_literal(" ".join(str(text).split()).lower())
    fold = lambda e: (
        "translate(normalize-space(" + e + "),"
        "'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')=" + want
    )
    named = " or ".join(
        fold(a) for a in ("@aria-label", "@placeholder", "@title", "@alt")
    )
    return (
        ".//*[(self::button or self::a or self::summary"
        " or @role='button' or @role='link' or @role='tab')"
        f" and {fold('string(.)')}]"
        " | .//input[(@type='submit' or @type='button' or @type='reset'"
        f" or @type='image') and ({fold('@value')} or {fold('string(.)')})]"
        " | .//*[(self::input[not(@type='hidden')] or self::textarea"
        " or self::select or self::img or self::button or self::a[@href]"
        " or self::summary or @role='button' or @role='link'"
        " or @role='tab' or @role='textbox' or @role='searchbox'"
        " or @role='combobox' or @role='listbox' or @role='checkbox'"
        " or @role='radio' or @role='switch' or @role='slider'"
        " or @role='spinbutton' or @role='option' or @role='treeitem'"
        " or @role='menuitem' or @role='menuitemcheckbox'"
        " or @role='menuitemradio' or @role='heading' or @role='summary'"
        f" or @role='iframe') and ({named})]"
    )


class AgentError(Exception):
    """The socket answered ``{"error": "…"}`` — a bad ref, a missing tab, a
    refused attach.  ``code`` carries the protocol's machine name for the
    failure when there is one ("STALE_REF", "NOT_FOUND", …)."""

    def __init__(self, message, code=None, request_id=None, receipt=None, metadata=None):
        super().__init__(message)
        self.code = code
        self.request_id = request_id
        self.receipt = receipt
        self.metadata = metadata or {}


class AgentTimeout(TimeoutError):
    """The caller stopped waiting. The operation's outcome is unknown."""

    def __init__(self, message, request_id):
        super().__init__(message)
        self.request_id = request_id
        self.receipt = {"requestId": request_id, "state": "running", "outcome": "unknown"}


class SocketGone(Exception):
    """The socket itself isn't there or stopped answering — the browser
    isn't running this world, or "Let a script drive Search" is off."""

    def __init__(self, message, request_id=None):
        super().__init__(message)
        self.request_id = request_id
        self.outcome = "unknown" if request_id is not None else None


def world_folder(world=None):
    """The app's folder for ``world``: "Search", "Search (test)",
    "Search (<name>)" — named exactly the way Store.world does."""
    if world is None:
        name = "Search"
    else:
        world = "".join(
            c for c in str(world).lower() if c.isascii() and (c.isalnum() or c == "-")
        )
        name = f"Search ({'test' if world in ('', '1') else world})"
    return os.path.expanduser(f"~/Library/Application Support/{name}")


def socket_path(world=None):
    return os.path.join(world_folder(world), "agent.sock")


def _locator(target):
    """`e3`, `css:…`, `text:…`, `loc:…`, `role:…`, `href:…`, `xpath:…`
    → the query keys drive.js resolves."""
    if target is None:
        return {}
    if isinstance(target, dict):
        return dict(target)
    if target.startswith("css:"):
        return {"css": target[4:]}
    if target.startswith("text:"):
        return {"text": target[5:]}
    if target.startswith("ref:"):
        return {"ref": target[4:]}
    # The durable handles a snapshot prints as loc= — css:/role:/href:/xpath:
    # inside — and the same prefixes said bare.
    if target.startswith("loc:"):
        return {"loc": target[4:]}
    for prefix in ("role:", "href:", "xpath:"):
        if target.startswith(prefix):
            return {"loc": target}
    # A bare word is a snapshot ref — `e3`, `f0e7`, what a snapshot prints.
    return {"ref": target}


class Agent:
    """One persistent session on the browser's agent socket.

    with Agent("test") as a:
        tab = a.open("https://example.com")
        a.wait(tab)
        print(a.snapshot(tab)["snapshot"])

    A reader thread owns the socket's inbound side and demultiplexes what
    arrives: answers land in a dict keyed by request id for whoever called,
    and ``{"event":…,"data":…}`` lines go to a queue ``subscribe()`` +
    ``next_event()`` / ``events()`` drain — the wire interleaves them
    freely, so nothing is ever read from under a waiting caller.

    Calls may be in flight at once under their own ids, and the object is
    safe to share between threads (sends are serialized; waits are
    per-id).
    """

    def __init__(self, world=None, timeout=120.0):
        self.world = world
        #: Default seconds ``call`` waits for an answer; the server pledges
        #: one (a late op answers ``"no answer within N s"`` rather than
        #: going quiet), so this is a tripwire, not the plan.
        self.timeout = timeout
        self._sock = None
        self._file = None
        self._reader = None
        self._cond = threading.Condition()
        self._send_lock = threading.Lock()
        self._results = {}               # id -> the whole answer object
        self._pending = set()
        self._events = queue.Queue(maxsize=256)
        self.dropped_events = 0
        self._event_lock = threading.Lock()
        self._connect_lock = threading.RLock()
        self._dead = None                # why the socket went away, if it did
        self._next = 0
        self._generation = 0

    # ------------------------------------------------------------ socket

    def connect(self, world=_NOT_GIVEN):
        with self._connect_lock:
            return self._connect(world)

    def _connect(self, world):
        """Open the session (idempotent — and if the socket died since,
        this buries the corpse and dials again).  Raises SocketGone when
        there's nothing listening — is the browser running, with "Let a
        script drive Search" enabled?"""
        if world is not _NOT_GIVEN:
            if self._sock is not None and self._dead is None:
                raise AgentError("already connected — close() first")
            self.world = world
        if self._sock is not None:
            if self._dead is None:
                return self
            self.close()  # went quiet under us — clean it up, redial below
        path = socket_path(self.world)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(path)
        except OSError as e:
            s.close()
            raise SocketGone(
                f"can't reach {path}: {e.strerror or e} — is the browser "
                f"running, with Settings › General › “Let a script drive "
                f"Search” on?"
            ) from e
        with self._cond:
            self._generation += 1
            self._dead = None
            self._results.clear()
            self._cond.notify_all()
        while not self._events.empty():
            try:
                self._events.get_nowait()
            except queue.Empty:
                break
        self._sock = s
        self._file = s.makefile("rb")
        self._reader = threading.Thread(
            target=self._read, args=(self._file, self._generation),
            name="search-agent-reader", daemon=True
        )
        self._reader.start()
        return self

    def close(self, id=_NOT_GIVEN):  # noqa: A003 - the op's own name
        """``close()`` alone hangs up the session; ``close(tab)`` closes an
        agent tab (the protocol's rule: only tabs the agent opened)."""
        if id is not _NOT_GIVEN:
            return self.call("tabs.close", id=id)
        s, f = self._sock, self._file
        self._sock = self._file = None
        if s is not None:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass
        if f is not None:
            try:
                f.close()
            except OSError:
                pass
        self._fail("closed")
        if self._reader is not None and self._reader.is_alive():
            self._reader.join(timeout=2)
        return None

    def __enter__(self):
        return self.connect()

    def __exit__(self, *exc):
        self.close()
        return False

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    @property
    def path(self):
        return socket_path(self.world)

    @property
    def connected(self):
        """A live session — False again once the socket's gone, even
        before the next call (or close()) notices."""
        return self._sock is not None and self._dead is None

    def _fail(self, why, generation=None):
        """The socket went quiet: everyone waiting on an answer gets told,
        and the event stream ends."""
        with self._cond:
            if generation is not None and generation != self._generation:
                return
            if self._dead is None:
                self._dead = why
            self._cond.notify_all()
        self._put_event(_EVENT_END)

    def _put_event(self, event):
        with self._event_lock:
            # Bound retained event bytes as well as count. Large payloads remain
            # available through the requested operation's response.
            if event is not _EVENT_END and len(json.dumps(event).encode()) > 65_536:
                self.dropped_events += 1
                return
            try:
                self._events.put_nowait(event)
            except queue.Full:
                try:
                    self._events.get_nowait()
                except queue.Empty:
                    pass
                self.dropped_events += 1
                self._events.put_nowait(event)

    def _read(self, reader=None, generation=None):
        """One line in is one object: an answer (has "id") or an event
        (has "event").  The socket's own error lines ("request too long")
        arrive with no id — they park under None, unread."""
        reader = self._file if reader is None else reader
        generation = self._generation if generation is None else generation
        try:
            while True:
                line = reader.readline(8_000_002)
                if len(line) > 8_000_001:
                    self._fail("response exceeds 8 MB", generation)
                    return
                if not line:
                    break
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(msg, dict):
                    continue
                with self._cond:
                    # A replaced reader may still have a buffered message.
                    # Never deliver its events or answers to the new session.
                    if generation != self._generation:
                        return
                    if "event" in msg:
                        self._put_event({"event": msg["event"], "data": msg.get("data", {})})
                    else:
                        mid = msg.get("id")
                        if mid in self._pending:
                            self._results[mid] = msg
                        self._cond.notify_all()
        except OSError:
            pass
        except Exception as e:                      # never kill the caller silently
            self._fail(f"reader died: {e}", generation)
            return
        self._fail("connection closed", generation)

    # ------------------------------------------------------------ calls

    def call(self, op, timeout=_NOT_GIVEN, **args):
        """Send once. Timeouts and disconnects never retry an operation.

        Errors expose request_id and receipt for request_status/request_cancel.
        Reconnect explicitly with connect() after a lost session. Its receipts
        belong to the old connection and cannot be queried on the new one.
        """
        if timeout is _NOT_GIVEN:
            timeout = self.timeout
        if self._dead is not None:
            raise SocketGone(f"agent socket is gone: {self._dead}; call connect() explicitly")
        self.connect()
        with self._cond:
            if self._dead:
                raise SocketGone(f"agent socket is gone: {self._dead}")
            if len(self._pending) >= 64 and op not in ("request.status", "request.cancel"):
                raise AgentError("64 requests already pending", code="TOO_MANY_REQUESTS")
            ident = self._next
            generation = self._generation
            request_socket = self._sock
            self._next += 1
            self._pending.add(ident)
        try:
            line = (json.dumps({"id": ident, "op": op, "args": args}, allow_nan=False) + "\n").encode()
            if len(line) > 4_000_000:
                raise AgentError("request exceeds 4 MB", code="INVALID_ARGS", request_id=ident)
            try:
                with self._send_lock:
                    if generation != self._generation:
                        raise SocketGone("request belongs to the previous connection", request_id=ident)
                    request_socket.sendall(line)
            except (OSError, AttributeError) as e:
                self._fail(f"send failed: {e}", generation)
                raise SocketGone(f"agent socket is gone: {e}", request_id=ident) from e
            with self._cond:
                deadline = None if timeout is None else time.monotonic() + timeout
                while ident not in self._results:
                    if self._dead or generation != self._generation:
                        raise SocketGone(f"agent socket is gone: {self._dead}", request_id=ident)
                    left = None if deadline is None else deadline - time.monotonic()
                    if left is not None and left <= 0:
                        raise AgentTimeout(f"{op} got no answer within {timeout} s; outcome unknown", ident)
                    self._cond.wait(left)
                msg = self._results.pop(ident)
            if "error" in msg:
                raise AgentError(str(msg["error"]), code=msg.get("code"), request_id=ident,
                                 receipt=msg.get("receipt"), metadata=msg)
            return msg.get("result", {})
        finally:
            with self._cond:
                self._pending.discard(ident)
                self._results.pop(ident, None)

    def request_status(self, request_id):
        """Read a receipt on this connection. Finished receipts have a bounded lifetime."""
        return self.call("request.status", requestId=request_id)

    def request_cancel(self, request_id):
        """Request cooperative cancellation. Running/unknown means effects may continue."""
        return self.call("request.cancel", requestId=request_id)

    # ------------------------------------------------------------ events

    def subscribe(self, events=None):
        """Ask the socket for events — ``["*"]`` (the default) is all of
        them: tab.navigated, tab.closed, tab.added, tab.title, lease.lost,
        done.  ``[]`` subscribes to nothing — how a subscribed session
        goes quiet without hanging up.  Answers
        ``{"subscribed": true, "events": […]}``."""
        return self.call(
            "subscribe", events=["*"] if events is None else list(events)
        )

    def next_event(self, timeout=None):
        """The next subscribed event — ``{"event": …, "data": {…}}`` — or
        None when ``timeout`` seconds pass first (or the socket's gone)."""
        if self._dead and self._events.empty():
            return None
        try:
            item = self._events.get(timeout=timeout)
        except queue.Empty:
            return None
        if item is _EVENT_END:
            return None
        return item

    def events(self, timeout=None):
        """Yield events as they arrive, stopping after ``timeout`` silent
        seconds — ``for ev in a.events(30):`` — or running until the socket
        dies when timeout is None.  Ctrl-C lands on the caller as usual."""
        while True:
            ev = self.next_event(timeout)
            if ev is None:
                return
            yield ev

    # ------------------------------------------------------------ tabs.*

    def tabs(self):
        """Every tab, user and agent → [{id,url,title,name,group,loading,
        bench,active,asleep,…}].  Metadata only; listing wakes nobody."""
        return self.call("tabs.list").get("tabs", [])

    def agent_tabs(self):
        """Only the agent (⚗) tabs → same shape as tabs()."""
        return self.call("agent.tabs").get("tabs", [])

    def open(self, url, foreground=None, space=None, agent_name=None):
        """Open an agent tab at ``url`` → its 8-char id.  ``foreground``
        selects it; ``space`` is passed through for builds that take one
        (this build's tabs.open ignores it)."""
        args = {"url": url}
        if foreground is not None:
            args["foreground"] = bool(foreground)
        if space is not None:
            args["space"] = space
        if agent_name is not None:
            args["agentName"] = str(agent_name)
        return self.call("tabs.open", **args).get("id")

    def attach(self, id, granted=False):
        """Claim read+drive rights over a tab → ``{id, attached}``.
        Agent tabs attach freely.  One of the user's must have been
        consented first — by its chip in the app's Ask panel, the only
        grant there is: ``tabs.grant`` is the in-app door alone (the
        socket is refused it) and ``granted`` on attach is refused on
        every door, so the wire can't grant a tab.  Attach one nobody
        chipped and it answers "… needs its chip in Ask — the wire can't
        grant it"; chipped once, attach succeeds from any session for the
        consenting chat's lifetime — the grant dies with the chat (a new
        or deleted chat clears them all), with the last holder, or with
        the app.  ``granted`` stays only so old call sites keep working —
        it maps to nothing and is never sent."""
        return self.call("tabs.attach", id=id)

    def detach(self, id):
        return self.call("tabs.detach", id=id)

    def select(self, id):
        """Bring a tab to the front (this session's own or attached)."""
        return self.call("tabs.select", id=id)

    def surface(self, tab, foreground=True):
        """Keep the live agent tab as a normal user tab, including its draft."""
        return self.call("tabs.surface", tab=tab, foreground=bool(foreground))

    def highlight(self, tab, target, duration=8, scroll=True):
        """Outline one element temporarily. Respects Settings > Ask; does not select the tab."""
        return self.call("page.highlight", tab=tab, duration=duration, scroll=scroll, **_locator(target))

    def clear_highlight(self, tab):
        """Dismiss this session's outline, including when highlights are disabled."""
        return self.call("page.clearHighlight", tab=tab)

    def inspector_attach(self, tab):
        """Discover real WebKit protocol targets, commands, parameters and events."""
        return self.call("inspector.attach", tab=tab)

    def inspector_send(self, tab, method, params=None, target_id=None, save=False):
        args = {"tab": tab, "method": method, "params": params or {}, "save": bool(save)}
        if target_id is not None:
            args["targetId"] = target_id
        return self.call("inspector.send", **args)

    def inspector_events(self, tab):
        return self.call("inspector.events", tab=tab)

    def inspector_read(self, tab, path, offset=0, length=16384):
        return self.call("inspector.read", tab=tab, path=path, offset=offset, length=length)

    def inspector_detach(self, tab):
        return self.call("inspector.detach", tab=tab)

    def dialogs(self, tab, enabled=None):
        args = {"tab": tab}
        if enabled is not None:
            args["enabled"] = bool(enabled)
        return self.call("page.dialogs", **args)

    def answer_dialog(self, tab, dialog, accept, text=None):
        args = {"tab": tab, "dialog": dialog, "accept": bool(accept)}
        if text is not None:
            args["text"] = text
        return self.call("page.dialog", **args)

    def choose_files(self, tab, dialog, paths):
        return self.call("page.files", tab=tab, dialog=dialog, paths=[os.path.abspath(os.path.expanduser(p)) for p in paths])

    # ------------------------------------------------------------ page.*

    def go(self, tab, url):
        """Navigate → {id,url}; the URL is normalized like `bench open`."""
        return self.call("page.go", tab=tab, url=url)

    def back(self, tab):
        return self.call("page.back", tab=tab)

    def forward(self, tab):
        return self.call("page.forward", tab=tab)

    def reload(self, tab):
        """Also the way a sleeping tab comes back."""
        return self.call("page.reload", tab=tab)

    def wait(self, tab, seconds=None):
        """Until the page has loaded → {id,url,title,loading,timeout?}.
        The socket's own patience is ``seconds`` + 5, so call() is given
        the same room."""
        args = {"tab": tab}
        if seconds is not None:
            args["seconds"] = seconds
        return self.call("page.wait", timeout=(seconds or 30) + 15, **args)

    def text(self, tab):
        """→ {text,truncated,url,title} — document.body.innerText, 120k cap."""
        return self.call("page.text", tab=tab)

    def snapshot(self, tab, scope="viewport", boxes=False, max_chars=None, interactive=False, selector=None, ref=None):
        """The semantic tree → {snapshot,version,url,title,truncated}.
        scope "viewport"|"full"; boxes adds [box=x,y,w,h]; refs die on
        navigation."""
        args = {"tab": tab, "scope": scope, "boxes": bool(boxes)}
        if max_chars is not None:
            args["maxChars"] = max_chars
        args["interactive"] = bool(interactive)
        if selector is not None:
            args["selector"] = selector
        if ref is not None:
            args["ref"] = ref
        return self.call("page.snapshot", **args)

    def screenshot(self, tab, path=None, marks=False, width=None):
        """A page image → {path,width,height,viewport,scale,format,data(b64)}.
        Default image pixels match CSS action coordinates. For an explicit
        width, divide image coordinates by scale before clicking or dragging.
        ``marks`` has drive.js draw index boxes first; ``width`` rescales.
        With no ``path`` the image lands in a tmp file whose name is
        handed to the server, and that path comes back in the result."""
        args = {"tab": tab, "marks": bool(marks)}
        tmp = None
        if path is None:
            fd, tmp = tempfile.mkstemp(prefix="search-shot-", suffix=".png")
            os.close(fd)
            args["path"] = tmp
        else:
            args["path"] = os.path.abspath(os.path.expanduser(path))
        if width is not None:
            args["width"] = width
        result = self.call("page.screenshot", **args)
        # A big shot comes back JPEG even under a .png name — give the tmp
        # file the honest extension.
        if tmp and result.get("format") == "jpeg" and tmp.endswith(".png"):
            jpg = tmp[:-4] + ".jpg"
            try:
                os.replace(tmp, jpg)
                result["path"] = jpg
            except OSError:
                pass
        return result

    def eval(self, tab, js):
        """Raw evaluateJavaScript → the JSON-safe value.  The escape
        hatch; privileged."""
        return self.call("page.eval", tab=tab, js=js).get("value")

    def code(self, tab, js):
        """JS run with ``__drive`` guaranteed installed →
        {value,consoleLines}.  For multi-step agent programs — prefer one
        of these over many tiny calls."""
        return self.call("page.code", tab=tab, js=js)

    def console(self, tab):
        """Recent console lines collected by drive.js →
        [{level,text,when}]."""
        return self.call("page.console", tab=tab).get("messages", [])

    def frames(self, tab):
        """→ [{ref,url,sameOrigin}]."""
        return self.call("page.frames", tab=tab).get("frames", [])

    # ------------------------------------------------------------ act.*

    def click(self, tab, target=None, tier="auto", **args):
        """act.click — ``target`` is a snapshot ref (``e3``) or a prefixed
        locator (``css:``, ``text:``, ``loc:``); or pass ref=/css=/text=/
        loc= directly.  tier "auto"|"js"|"event" (auto uses one native click after
        actionability checks; js explicitly opts into synthetic events).  Extra args pass through:
        button, double, modifiers, withSnapshot."""
        return self.call("act.click", tab=tab, tier=tier,
                         **_act_args("click", target, args))

    def fill(self, tab, target, text, **args):
        """act.fill — atomic set through the element's own setter (React-
        aware; contenteditable too).  A ``text:`` target travels as the
        xpath that says it — ``text`` here is the value going in."""
        return self.call("act.fill", tab=tab, text=text,
                         **_act_args("fill", target, args))

    def type(self, tab, target, text, delay=None, **args):  # noqa: A003
        """act.type — real per-character key events; ``delay`` in ms.
        Same ``text:``-target translation as fill."""
        if delay is not None:
            args["delay"] = delay
        return self.call("act.type", tab=tab, text=text,
                         **_act_args("type", target, args))

    def press(self, tab, key, target=None, modifiers=None, **args):
        """Press a named key or chord such as ``cmd+a`` with real NSEvents.
        Search runs on macOS: use ``cmd`` for editing shortcuts. Modifier
        names and aliases are case-insensitive; invalid keys are rejected.
        Focuses ``target`` first when one is given."""
        args["key"] = key
        if modifiers is not None:
            args["modifiers"] = list(modifiers)
        return self.call("act.press", tab=tab, **_act_args("press", target, args))

    def hover(self, tab, target=None, **args):
        return self.call("act.hover", tab=tab, **_act_args("hover", target, args))

    def scroll(self, tab, target="page", dx=None, dy=None, to_text=None, **args):
        """act.scroll — ``"page"`` (the default) or an element; dx/dy in
        px, ``to_text`` scrolls a string into view."""
        if target == "page":
            args["ref"] = "page"
        else:
            args.update(_locator(target))
        if dx is not None:
            args["dx"] = dx
        if dy is not None:
            args["dy"] = dy
        if to_text is not None:
            args["toText"] = to_text
        return self.call("act.scroll", tab=tab, **args)

    def select_option(self, tab, target, values, **args):
        """act.select — pick ``values`` (a list) in a <select>.  (Named so
        it can't be mistaken for ``select(tab)``, which raises a tab.)"""
        args["values"] = list(values)
        return self.call("act.select", tab=tab, **_act_args("select", target, args))

    def check(self, tab, target, on=True, **args):
        """act.check — a checkbox/radio on or off."""
        args["on"] = bool(on)
        return self.call("act.check", tab=tab, **_act_args("check", target, args))

    def submit(self, tab, target=None, **args):
        """act.submit — requestSubmit() the form around the element."""
        return self.call("act.submit", tab=tab, **_act_args("submit", target, args))

    def click_at(self, tab, x, y, **args):
        """act.clickAt — the coordinate tier, for canvas/SVG →
        {ok,at,tier,element?}."""
        return self.call("act.clickAt", tab=tab, x=x, y=y, **args)

    def drag(self, tab, source, to, steps=None, **args):
        """act.drag — drag a source locator to another locator or a viewport
        point (x, y), optionally following a continuous viewport path.
        Returns after the native mouse gesture completes."""
        args["source"] = list(source) if isinstance(source, (tuple, list)) else _locator(source)
        args["to"] = list(to) if isinstance(to, (tuple, list)) else _locator(to)
        if steps is not None:
            args["steps"] = steps
        return self.call("act.drag", tab=tab, **args)

    def save_pdf(self, tab):
        """page.pdf — render the current page to a session-scoped artifact."""
        return self.call("page.pdf", tab=tab)

    def artifacts(self, tab=None):
        """→ metadata for this session's saved PDFs and completed downloads."""
        args = {} if tab is None else {"tab": tab}
        return self.call("artifact.list", **args).get("artifacts", [])

    def downloads(self, tab=None):
        """Completed downloads owned by this session, with readable metadata."""
        return [item for item in self.artifacts(tab) if item.get("kind") == "download"]

    def artifact_read(self, artifact_id, offset=0, length=48_000):
        """Read a binary artifact chunk as base64, scoped to this session."""
        return self.call("artifact.read", id=artifact_id, offset=offset, length=length)

    # ------------------------------------------------------------ meta

    def lease(self, tab, on=True):
        """agent.lease — while held, the user's own input on that tab
        takes it back and emits ``lease.lost``."""
        return self.call("agent.lease", tab=tab, on=bool(on))

    def probe(self):
        """agent.probe — the window's own report: active tab, panels,
        groups, windows, lights."""
        return self.call("agent.probe")

    def groups(self):
        """The tab groups → [{id,title,colour,icon,expanded,count}].
        The socket has no groups op of its own; the probe report carries
        them, so this is agent.probed."""
        return self.probe().get("groups", [])

    def spaces(self):
        """The spaces → [name, …] — the probe report carries them today,
        beside ``spacesOn`` and the current ``space``; a build too old to
        know the field raises AgentError instead."""
        report = self.probe()
        if "spaces" in report:
            return report["spaces"]
        raise AgentError(
            "spaces aren't exposed over agent.sock in this build — "
            "agent.probe's report has no 'spaces' (see SDK.md)"
        )

    def ask_open(self, on=True):
        """ui.ask — open or close the Ask panel → {"open": bool}.
        The op's other keys have their own wrappers: ``send`` rides as
        ``a.call("ui.ask", send="…")`` → {open, ok, chat}, and ``steer``
        / ``stop_ask`` feed and kill the running turn."""
        return self.call("ui.ask", open=bool(on))

    def ask_status(self):
        """→ current in-app Ask chat, model, turn activity, and waiting state."""
        return self.call("ui.ask", status=True)

    def ask_new_chat(self):
        """Start a fresh empty in-app chat when no Ask turn is running."""
        return self.call("ui.ask", new=True)

    def steer(self, text):
        """ui.ask — a follow-up for the in-app agent's live turn →
        {open, ok, chat?} (Mind.steer: with no chat open it sends)."""
        return self.call("ui.ask", steer=text)

    def stop_ask(self):
        """ui.ask — stop the in-app agent's running turn → {open, ok}."""
        return self.call("ui.ask", stop=True)

    def ping(self):
        """→ {"pong": true}; the cheapest "are you there"."""
        return self.call("ping")


def _act_args(verb, target, extra):
    """Merge a locator (``e3`` / ``css:…`` / ``text:…`` / ``loc:…``, or an
    explicit ref=/css=/text=/loc= kwarg) with the rest of an act's args.
    ``verb`` is the act verb the server sees — it decides whether a
    ``text:`` target can ride as ``{"text": …}`` or has to become the
    xpath: loc that says the same thing."""
    args = dict(extra)
    if target is not None:
        loc = _locator(target)
        if verb in _NO_TEXT_QUERY and "text" in loc:
            loc = {"loc": "xpath:" + _text_xpath(loc["text"])}
        args.update(loc)
    elif verb in ("press", "clickAt") and "text" in args:
        # These verbs have no `text` payload — a text= kwarg can only be
        # the locator, and left as-is it falls off the wire entirely
        # (query() keeps `text` out of the locator set for them).
        args["loc"] = "xpath:" + _text_xpath(args.pop("text"))
    return args
