"""Run against an isolated Search world: python3 Tests/Agent/check.py WORLD."""
import http.server
import pathlib
import json
import socket
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "sdk"))
from search_agent import Agent, AgentError, world_folder

assert len(sys.argv) == 2 and sys.argv[1] not in ("", "main"), "an isolated test world is required"
html = b'''<!doctype html><title>Agent handoff check</title>
<textarea id="draft" aria-label="Draft"></textarea>
<button id="once" onclick="window.hits=(window.hits||0)+1;document.querySelector('#hit-count').textContent='Hits: '+window.hits">Count</button>
<p id="hit-count">Hits: 0</p>
<button id="prompt" onclick="window.answer=prompt('Test question')">Prompt</button>
<input id="file" type="file"><div id="shadow"></div>
<script>document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<button id="inner">Shadow button</button>';</script>'''

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(html)
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}/"

def eventually(fn):
    until = time.monotonic() + 8
    while time.monotonic() < until:
        result = fn()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError("condition did not become true")

def bench(op, **args):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(10)
        sock.connect(str(pathlib.Path(world_folder(sys.argv[1])) / "bench.sock"))
        sock.sendall(json.dumps(dict(do=op, **args)).encode() + b"\n")
        reply = json.loads(sock.makefile("rb").readline())
        assert "error" not in reply, reply
        return reply

try:
    with Agent(sys.argv[1]) as a:
        tab = a.open(url, agent_name="Handoff check")
        a.wait(tab)
        assert "Shadow button" in a.snapshot(tab, interactive=True)["snapshot"]
        a.fill(tab, "css:#draft", "Keep this unsent draft")
        a.eval(tab, "window.handoffIdentity='same-live-page'")
        clicked = a.click(tab, "css:#once", withSnapshot=True)
        assert "snapshot" in clicked
        eventually(lambda: a.eval(tab, "window.hits") == 1)
        time.sleep(.6)
        assert a.eval(tab, "window.hits") == 1
        a.dialogs(tab, True)
        prompted = a.click(tab, "css:#prompt", tier="event", withSnapshot=True)
        assert prompted.get("dialogPending") is True, prompted
        assert "snapshotError" in prompted and "pending" in prompted["snapshotError"], prompted
        prompt = eventually(lambda: a.dialogs(tab).get("pending"))
        assert prompt["kind"] == "prompt"
        a.answer_dialog(tab, prompt["id"], True, "native answer")
        eventually(lambda: a.eval(tab, "window.answer") == "native answer")
        resumed = a.click(tab, "css:#once", tier="event", withSnapshot=True)
        assert "Hits: 2" in resumed.get("snapshot", ""), resumed
        assert a.eval(tab, "window.hits") == 2
        a.click(tab, "css:#file")
        chooser = eventually(lambda: a.dialogs(tab).get("pending"))
        assert chooser["kind"] == "file"
        with tempfile.NamedTemporaryFile(suffix=".txt") as file:
            file.write(b"test upload"); file.flush()
            a.choose_files(tab, chooser["id"], [file.name])
            eventually(lambda: a.eval(tab, "document.querySelector('#file').files.length") == 1)
        caps = a.inspector_attach(tab)
        assert caps
        result = a.inspector_send(tab, "Runtime.evaluate", {"expression": "21*2", "returnByValue": True})
        assert result["result"]["value"] == 42, result
        saved = a.inspector_send(tab, "Runtime.evaluate", {"expression": "'saved 😀 result'", "returnByValue": True}, save=True)
        artifact = pathlib.Path(saved["artifact"]["path"])
        assert json.loads(artifact.read_text())["result"]["value"] == "saved 😀 result"
        chunks, offset = [], 0
        while True:
            part = a.inspector_read(tab, str(artifact), offset=offset, length=8)
            chunks.append(part["text"])
            if part["eof"]: break
            assert part["nextOffset"] > offset
            offset = part["nextOffset"]
        assert json.loads("".join(chunks))["result"]["value"] == "saved 😀 result"
        a.inspector_detach(tab)
        a.inspector_attach(tab)
        assert a.inspector_send(tab, "Runtime.evaluate", {"expression": "6*7", "returnByValue": True})["result"]["value"] == 42
        a.inspector_detach(tab)
        a.surface(tab)
        assert a.eval(tab, "document.querySelector('#draft').value") == "Keep this unsent draft"
        assert a.eval(tab, "window.handoffIdentity") == "same-live-page"
        row = next(t for t in a.tabs() if t["id"] == tab)
        assert row["surfaced"] and not row["bench"] and row["active"], row
        try:
            a.close(tab)
            raise AssertionError("agent could close a handed-off user tab")
        except AgentError:
            pass
        # Pinning uses the same Browser handoff as the dropdown's Keep button.
        kept = a.open(url, agent_name="Keep check")
        a.wait(kept)
        bench("pin", id=kept)
        time.sleep(.7)
        assert a.eval(kept, "document.title") == "Agent handoff check"
        assert next(t for t in a.tabs() if t["id"] == kept)["surfaced"]
        parked = a.open(url, agent_name="Space check")
        a.wait(parked)
        original_space = next(t for t in a.tabs() if t["id"] == parked)["space"]
        bench("ui", spaces=True)
        bench("space", action="new", name="Agent check other space", fresh=True)
        a.select(parked)
        assert next(t for t in a.tabs() if t["id"] == parked)["active"]
        assert next(t for t in a.tabs() if t["id"] == parked)["space"] == original_space
        # A session ending while its tab is parked still cleans it up.
        bench("space", action="new", name="Agent check cleanup", fresh=True)
    with Agent(sys.argv[1]) as observer:
        row = next(t for t in observer.tabs() if t["id"] == tab)
        assert row["surfaced"] and not row["bench"]
        assert not any(t["id"] == parked for t in observer.tabs())
        try:
            observer.attach(tab)
            raise AssertionError("surface granted unrelated sessions permission")
        except AgentError:
            pass
    print("PASS native click/snapshot, shadow roots, prompt, upload, inspector/artifact/reconnect, live draft handoff, Keep, parked selection/cleanup, consent")
finally:
    server.shutdown()
