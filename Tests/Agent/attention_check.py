"""Run against a disposable Search world: python3 Tests/Agent/attention_check.py WORLD."""
import http.server
import json
import pathlib
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "sdk"))
from search_agent import Agent, AgentError, world_folder

assert len(sys.argv) == 2 and sys.argv[1] not in ("", "main"), "an isolated test world is required"
world = sys.argv[1]


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b'<title>Attention check</title><button id="result" onclick="this.textContent=\'Clicked\'">Review result</button>')

    def log_message(self, *_):
        pass


def bench(**args):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(10)
        sock.connect(str(pathlib.Path(world_folder(world)) / "bench.sock"))
        sock.sendall(json.dumps(dict(do="ui", **args)).encode() + b"\n")
        result = json.loads(sock.makefile("rb").readline())
        assert "error" not in result, result


def rejected(code, action):
    try:
        action()
    except AgentError as error:
        assert error.code == code, error.metadata
    else:
        raise AssertionError(f"expected {code}")


def eventually(action):
    until = time.monotonic() + 4
    while time.monotonic() < until:
        if action():
            return
        time.sleep(.05)
    raise AssertionError("condition did not become true")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}/"
outlined = "!!document.querySelector('[data-search-highlight]')"
suite = "com.officecommun.search.test" + ("" if world == "test" else "." + world)


def stored(key):
    return subprocess.check_output(["defaults", "read", suite, key], text=True).strip()


try:
    with Agent(world) as agent:
        tab = agent.open(url)
        agent.wait(tab)
        agent.select(tab)
        assert next(row for row in agent.tabs() if row["id"] == tab)["active"]
        assert agent.highlight(tab, "css:#result", duration=2)["highlighted"]
        assert agent.eval(tab, outlined)
        assert agent.eval(tab, "document.querySelector('#result').getAttribute('style')") is None
        agent.click(tab, "css:#result")
        assert agent.eval(tab, "document.querySelector('#result').textContent") == "Clicked"
        assert agent.clear_highlight(tab)["cleared"]
        agent.highlight(tab, "css:#result", duration=1)
        eventually(lambda: not agent.eval(tab, outlined))
        agent.highlight(tab, "css:#result")
        agent.press(tab, "Escape")
        eventually(lambda: not agent.eval(tab, outlined))
        for args in ({"css": "#result", "duration": True}, {"css": "#result", "duration": 31}, {"css": "#result", "ref": "e1"}):
            rejected("INVALID_ARGUMENT", lambda: agent.call("page.highlight", tab=tab, **args))
        agent.highlight(tab, "css:#result")
        bench(agentHighlights=False, agentFocus=False)
        eventually(lambda: stored("ask.agentFocus") == "0" and stored("ask.agentHighlights") == "0")
        eventually(lambda: not agent.eval(tab, outlined))
        rejected("ATTENTION_DISABLED", lambda: agent.highlight(tab, "css:#result"))
        rejected("ATTENTION_DISABLED", lambda: agent.select(tab))
        before = {row["id"] for row in agent.tabs()}
        rejected("ATTENTION_DISABLED", lambda: agent.open(url, foreground=True))
        assert {row["id"] for row in agent.tabs()} == before
        rejected("ATTENTION_DISABLED", lambda: agent.surface(tab))
        assert next(row for row in agent.tabs() if row["id"] == tab)["bench"]
        background = agent.open(url)
        assert not next(row for row in agent.tabs() if row["id"] == background)["active"]
        agent.surface(background, foreground=False)
        assert not next(row for row in agent.tabs() if row["id"] == background)["active"]
        assert agent.clear_highlight(tab)["cleared"] is False
        bench(agentFocus=True, agentHighlights=True)
        agent.highlight(tab, "css:#result")
        agent.detach(tab)
        eventually(lambda: not agent.eval(tab, outlined))
        agent.highlight(tab, "css:#result")
        agent.surface(tab, foreground=False)
    # The page persists after handoff, but the departed session's outline does not.
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(10)
        sock.connect(str(pathlib.Path(world_folder(world)) / "bench.sock"))
        sock.sendall(json.dumps(dict(do="eval", id=tab, js=outlined)).encode() + b"\n")
        reply = json.loads(sock.makefile("rb").readline())
        assert not reply.get("value"), reply
    print("PASS tab focus, outline/clicks, expiry, Escape, validation, disable/clear, foreground atomicity, background handoff, detach and disconnect cleanup")
finally:
    bench(agentFocus=True, agentHighlights=True)
    eventually(lambda: stored("ask.agentFocus") == "1" and stored("ask.agentHighlights") == "1")
    server.shutdown()
