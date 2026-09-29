"""Local input regressions. Run in an isolated world configured with echo/echo."""
import functools
import http.server
import json
import pathlib
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sdk"))
from search_agent import Agent, AgentError, world_folder

assert len(sys.argv) == 2 and sys.argv[1] not in ("", "main"), "an isolated echo world is required"

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(
    Handler, directory=str(ROOT / "Runtime/ask/bench/fixtures")))
threading.Thread(target=server.serve_forever, daemon=True).start()

def eventually(fn):
    until = time.monotonic() + 10
    while time.monotonic() < until:
        if fn():
            return
        time.sleep(.05)
    raise AssertionError("condition did not become true")

try:
    with Agent(sys.argv[1]) as agent:
        def page(name):
            tab = agent.open(f"http://127.0.0.1:{server.server_port}/{name}.html")
            agent.wait(tab)
            return tab

        tab = page("trusted")
        agent.click(tab, "css:#vote")
        eventually(lambda: agent.eval(tab, "document.querySelector('#count').textContent") == "1")
        time.sleep(.5)
        assert agent.eval(tab, "document.querySelector('#count').textContent") == "1"

        tab = page("covered")
        try:
            agent.click(tab, "css:#buy")
            raise AssertionError("covered button accepted a click")
        except AgentError as error:
            assert error.code == "COVERED", error
        assert not agent.eval(tab, "document.querySelector('#bought').classList.contains('show')")
        agent.click(tab, "css:#dismiss")
        agent.click(tab, "css:#buy")
        eventually(lambda: agent.eval(tab, "document.querySelector('#bought').classList.contains('show')"))

        tab = page("keys")
        agent.type(tab, "css:#field", "hello world")
        agent.press(tab, "Enter", "css:#field")
        eventually(lambda: agent.eval(tab, "Array.from(document.querySelectorAll('#log li'), x => x.textContent)") == ["hello world"])

        tab = page("longscroll")
        agent.scroll(tab, dy=100000)
        eventually(lambda: agent.eval(tab, "!!document.querySelector('#the-end')"))
        agent.scroll(tab, dy=100000)
        assert "THE END" in agent.snapshot(tab, scope="viewport")["snapshot"]
        assert agent.eval(tab, "document.querySelector('#the-end').getBoundingClientRect().bottom <= window.innerHeight + 1 && window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 1")

        agent.call("ui.ask", new=True)
        reply = agent.call("ui.ask", send="first echo")
        chat_file = pathlib.Path(world_folder(sys.argv[1])) / "chats" / f"{reply['chat']}.json"
        def replied(text):
            chat = json.loads(chat_file.read_text())
            return any(m.get("role") == "agent" and text in m.get("text", "") for m in chat["messages"])
        eventually(lambda: replied("Echo: first echo"))
        # Let the done event settle before steering the already completed chat.
        time.sleep(.3)
        agent.call("ui.ask", steer="idle follow-up")
        eventually(lambda: replied("Echo: idle follow-up"))
    print("PASS trusted click once, covered refusal/recovery, native type/Enter, scroll-end, idle steer")
finally:
    server.shutdown()
