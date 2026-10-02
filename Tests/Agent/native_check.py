"""Native drag, page PDF, download routing, and Ask status checks.

Run against a disposable Search world after launching its app:
    python3 Tests/Agent/native_check.py WORLD
"""
import base64
import http.server
import os
import pathlib
import struct
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sdk"))
sys.path.insert(0, str(ROOT / "Runtime/ask/bench"))
from search_agent import Agent, AgentError, world_folder
import run as bench

assert len(sys.argv) == 2 and sys.argv[1] not in ("", "main"), "an isolated test world is required"

HTML = b'''<!doctype html><meta charset="utf-8"><title>Native parity</title>
<style>html,body{margin:0;width:100%;height:100%;overflow:hidden}canvas{display:block;width:100vw;height:100vh;background:#eee}
#source,#target{position:fixed;left:12px;top:12px;width:48px;height:48px;z-index:2;opacity:.75}
#target{left:72px;top:72px}#copy,#paste{position:fixed;top:130px;left:12px;width:130px;height:28px;z-index:3}
#paste{left:160px}#type,#next{position:fixed;top:165px;left:12px;width:130px;height:24px;z-index:3}
#next{left:160px}#download{position:fixed;right:4px;bottom:4px;z-index:3;background:white}</style>
<button id="generate" style="position:fixed;left:12px;top:202px;z-index:4">Generate</button>
<button id="open-child" style="position:fixed;left:170px;top:4px;z-index:4">Open child</button>
<p id="generated" style="position:fixed;left:100px;top:192px;z-index:4">Generated: -</p>
<canvas id="canvas"></canvas><div id="source"></div><div id="target"></div>
<textarea id="copy">Search copy check</textarea><textarea id="paste"></textarea>
<input id="type"><input id="next">
<a id="download" href="/download">download</a>
<script>
window.__rafTicks=0;const pageRAF=window.requestAnimationFrame.bind(window);const ctx=document.getElementById('canvas').getContext('2d');
function pageFrame(){window.__rafTicks++;ctx.clearRect(0,0,80,12);ctx.fillStyle='#d22';ctx.fillRect(window.__rafTicks%70,1,8,8);pageRAF(pageFrame)}pageRAF(pageFrame);
window.__childState=null;
if(location.pathname==='/child'){
  document.title='Native parity child';
  function reportChild(){try{window.opener.__childState={width:innerWidth,height:innerHeight,ticks:window.__rafTicks}}catch{}pageRAF(reportChild)}
  pageRAF(reportChild);
}
document.querySelector('#open-child').addEventListener('click',e=>{if(e.isTrusted)window.open('/child','_blank')});
window.__preventMetaA=false;window.__keyEvents=[];document.addEventListener('keydown',e=>{window.__keyEvents.push([e.key,e.shiftKey,e.metaKey,e.target.id]);if(window.__preventMetaA&&e.metaKey&&e.key.toLowerCase()==='a')e.preventDefault()});
window.__dragEvents=[];let dragging=false,pointer=[0,0],dragSeq=0,pollTimer;
document.addEventListener('mousedown',e=>{dragging=true;window.__dragEvents.push(['down',dragSeq++,e.clientX,e.clientY,e.buttons,e.which,e.isTrusted])});
document.addEventListener('mousemove',e=>{pointer=[e.clientX,e.clientY];window.__dragEvents.push(['move',dragSeq++,e.clientX,e.clientY,e.buttons,e.which,e.isTrusted])});
document.addEventListener('mouseup',e=>{window.__dragEvents.push(['up',dragSeq++,e.clientX,e.clientY,e.buttons,e.which,e.isTrusted]);dragging=false;clearInterval(pollTimer)});
window.__startDragPoll=()=>{clearInterval(pollTimer);pollTimer=setInterval(()=>window.__dragEvents.push(['poll',dragSeq++,pointer[0],pointer[1],dragging]),20)};
window.__startDragPoll();
let generated=0;document.querySelector('#generate').addEventListener('click',e=>{if(e.isTrusted){generated++;document.querySelector('#generated').textContent='Generated: '+generated}});
</script>'''

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/download":
            payload = b"Search agent download check\n"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="agent-check.txt"')
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(HTML)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}/"


def eventually(fn, timeout=12):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = fn()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError("condition did not become true")


try:
    with Agent(sys.argv[1]) as agent:
        tab = agent.open(url, agent_name="Native parity")
        agent.wait(tab)

        width, height = agent.eval(tab, "[innerWidth,innerHeight]")
        assert width > 80 and height > 80, (width, height)
        raf_before = agent.eval(tab, "[document.visibilityState,window.__rafTicks]")
        time.sleep(.25)
        raf_after = agent.eval(tab, "[document.visibilityState,window.__rafTicks]")
        assert raf_after[1] > raf_before[1], (raf_before, raf_after)

        # Each result includes a snapshot taken immediately after the trusted
        # native click. A stale snapshot makes a sequence of decisions one
        # click behind even when a later standalone eval sees the right state.
        for count in range(1, 4):
            clicked = agent.click(tab, "css:#generate", tier="event", withSnapshot=True)
            expected = f'Generated: {count}'
            assert expected in clicked.get("snapshot", ""), (expected, clicked)
            assert agent.eval(tab, "document.querySelector('#generated').textContent") == expected
        box = agent.eval(tab, "(()=>{const r=document.querySelector('#generate').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
        agent.click_at(tab, *box)
        assert agent.eval(tab, "document.querySelector('#generated').textContent") == "Generated: 4"

        before = len(agent.eval(tab, "window.__dragEvents"))
        try:
            agent.click_at(tab, 12, height)
            raise AssertionError("out-of-viewport click was accepted")
        except AgentError as error:
            assert error.code == "INVALID_ARGUMENT", error
        assert len(agent.eval(tab, "window.__dragEvents")) == before, "invalid click dispatched mouse events"

        shot = agent.screenshot(tab)
        assert shot.get("viewport") == {"width": width, "height": height}, shot
        assert shot.get("format") == "png", shot
        png = base64.b64decode(shot["data"])
        assert png[:8] == b"\x89PNG\r\n\x1a\n", shot
        pixel_width, pixel_height = struct.unpack(">II", png[16:24])
        assert (pixel_width, pixel_height) == (width, height), (pixel_width, pixel_height, width, height)
        assert shot.get("scale") == 1, shot
        resized = agent.screenshot(tab, width=120)
        assert resized.get("viewport") == {"width": width, "height": height}, resized
        assert resized.get("width", 0) > 0 and resized.get("height", 0) > 0, resized
        assert abs(resized.get("scale", 0) - resized["width"] / width) < 0.02, resized

        copied = agent.eval(tab, "document.querySelector('#copy').value")
        agent.press(tab, "META+A", target="css:#copy")
        selection = eventually(lambda: agent.eval(tab, "[document.activeElement.id,document.querySelector('#copy').selectionStart,document.querySelector('#copy').selectionEnd]")
                               if agent.eval(tab, "document.querySelector('#copy').selectionEnd") == len(copied) else None)
        assert selection == ["copy", 0, len(copied)], selection
        agent.press(tab, "META+C", target="css:#copy")
        agent.press(tab, "META+V", target="css:#paste")
        pasted = eventually(lambda: agent.eval(tab, "document.querySelector('#paste').value")
                            if agent.eval(tab, "document.querySelector('#paste').value") == copied else None)
        assert pasted == copied, (copied, pasted)
        agent.press(tab, "SHIFT+a", target="css:#paste")
        shifted = eventually(lambda: agent.eval(tab, "[document.querySelector('#paste').value,window.__keyEvents.at(-1)]")
                             if agent.eval(tab, "document.querySelector('#paste').value") == copied + "A" else None)
        assert shifted == [copied + "A", ["A", True, False, "paste"]], shifted
        agent.press(tab, "A", target="css:#paste")
        capital = eventually(lambda: agent.eval(tab, "[document.querySelector('#paste').value,window.__keyEvents.at(-1)]")
                             if agent.eval(tab, "document.querySelector('#paste').value") == copied + "AA" else None)
        assert capital == [copied + "AA", ["A", True, False, "paste"]], capital

        agent.eval(tab, "window.__preventMetaA=true;document.querySelector('#copy').setSelectionRange(0,0)")
        before_events = agent.eval(tab, "window.__keyEvents.length")
        agent.press(tab, "META+A", target="css:#copy")
        eventually(lambda: agent.eval(tab, "window.__keyEvents.length") > before_events)
        time.sleep(.1)
        prevented_selection = agent.eval(tab, "[document.querySelector('#copy').selectionStart,document.querySelector('#copy').selectionEnd]")
        assert prevented_selection == [0, 0], prevented_selection

        agent.eval(tab, "document.querySelector('#paste').focus()")
        for key, modifiers in (("NO_SUCH_KEY", None), ("v", ["META", "unknown"])):
            try:
                agent.press(tab, key, target="css:#copy", modifiers=modifiers)
                raise AssertionError(f"invalid key/modifier was accepted: {key}, {modifiers}")
            except AgentError as error:
                assert error.code == "INVALID_ARGUMENT", error
        after_invalid = agent.eval(tab, "[document.activeElement.id,document.querySelector('#copy').value,document.querySelector('#paste').value]")
        assert after_invalid == ["paste", copied, copied + "AA"], after_invalid

        typed = agent.type(tab, "css:#type", "ab", delay=0)
        assert typed.get("typed") == "ab", typed
        agent.press(tab, "x", target="css:#next")
        entered = eventually(lambda: agent.eval(tab, "[document.querySelector('#type').value,document.querySelector('#next').value]")
                             if agent.eval(tab, "document.querySelector('#type').value==='ab'&&document.querySelector('#next').value==='x'") else None)
        assert entered == ["ab", "x"], entered

        if os.environ.get("SEARCH_BENCHMARK") == "miniwob":
            fixture_viewport = {"width": 332, "height": 214}
            assert agent.eval(tab, "({width:innerWidth,height:innerHeight})") == fixture_viewport
            agent.select(tab)
            selected = next(row for row in agent.tabs() if row["id"] == tab)
            assert selected["active"] is True, selected
            bench.bench_cli(sys.argv[1], ["resize", "792", "727", "4"], timeout=30)
            eventually(lambda: agent.eval(tab, "({width:innerWidth,height:innerHeight})") == fixture_viewport)
            shot = agent.screenshot(tab)
            assert shot.get("viewport") == fixture_viewport, shot
            assert shot.get("scale") == 1, shot
            pixels = struct.unpack(">II", base64.b64decode(shot["data"])[16:24])
            assert pixels == (332, 214), (pixels, shot.get("viewport"))

        start = [min(24, width // 4), min(24, height // 4)]
        end = [width * 3 // 4, height * 3 // 4]
        path = [[width // 3, height // 5], [width // 2, height // 3], [width * 2 // 3, height // 2]]
        key_window_before = agent.probe().get("key")
        agent.eval(tab, "window.__dragEvents=[];window.__startDragPoll()")
        dragged = agent.drag(tab, start, end, path=path)
        assert dragged.get("ok") and dragged.get("tier") == "event", dragged
        assert agent.probe().get("key") == key_window_before, (key_window_before, agent.probe().get("key"))
        # Read immediately after drag acknowledgement. The source move must
        # initialize page pointer state before mousedown begins the gesture.
        events = agent.eval(tab, "window.__dragEvents")
        source_move = next((event for event in events if event[0] == "move"), None)
        assert source_move and abs(source_move[2] - start[0]) <= 2 and abs(source_move[3] - start[1]) <= 2, events
        down_index = next(i for i, event in enumerate(events) if event[0] == "down")
        down = events[down_index]
        up = next(event for event in events if event[0] == "up")
        assert events.index(source_move) < down_index < events.index(up) and events[-1] == up, events
        assert source_move[4] == 0 and source_move[6] and down[4] == 1 and up[4] == 0 and down[6] and up[6], events
        assert any(event[0] == "poll" and source_move[1] < event[1] < down[1] and
                   abs(event[2] - start[0]) <= 2 and abs(event[3] - start[1]) <= 2 and not event[4]
                   for event in events), ("page did not sample the unpressed drag origin", events)
        moves = [event for event in events if event[0] == "move"]
        assert len(moves) >= 4, events
        for point in path:
            assert any(abs(move[2] - point[0]) <= 2 and abs(move[3] - point[1]) <= 2 and
                       move[4] == 1 and move[6] for move in moves), (point, moves)

        if os.environ.get("SEARCH_BENCHMARK") == "miniwob":
            agent.click(tab, "css:#open-child", tier="event")
            child_state = eventually(lambda: agent.eval(tab, "window.__childState && window.__childState.ticks > 0 ? window.__childState : null"))
            assert child_state["width"] == 332 and child_state["height"] == 214 and child_state["ticks"] > 0, child_state
            child = eventually(lambda: next((row for row in agent.agent_tabs()
                                              if row.get("title") == "Native parity child"), None))
            child_id = child["id"]
            agent.select(child_id)
            selected_child = next(row for row in agent.agent_tabs() if row["id"] == child_id)
            assert selected_child["active"] is True, selected_child
            fixture_viewport = {"width": 332, "height": 214}
            eventually(lambda: agent.eval(child_id, "({width:innerWidth,height:innerHeight})") == fixture_viewport)
            child_shot = agent.screenshot(child_id)
            assert child_shot.get("viewport") == fixture_viewport, child_shot
            assert child_shot.get("scale") == 1, child_shot
            child_pixels = struct.unpack(">II", base64.b64decode(child_shot["data"])[16:24])
            assert child_pixels == (332, 214), (child_pixels, child_shot.get("viewport"))

        pdf = agent.save_pdf(tab)["artifact"]
        assert pdf["kind"] == "pdf", pdf
        chunk = agent.artifact_read(pdf["id"])
        assert base64.b64decode(chunk["base64"]).startswith(b"%PDF-"), chunk
        assert any(item["id"] == pdf["id"] for item in agent.artifacts(tab))

        agent.click(tab, "css:#download")
        download = eventually(lambda: next((item for item in agent.downloads(tab)
                                            if item["name"] == "agent-check.txt"), None))
        saved = agent.artifact_read(download["id"])
        assert base64.b64decode(saved["base64"]) == b"Search agent download check\n"

        status = agent.ask_status()
        assert {"chat", "running", "model", "effort", "activity", "waiting"} <= status.keys(), status
        if status["running"]:
            try:
                agent.ask_new_chat()
                raise AssertionError("new chat replaced a running turn")
            except AgentError as error:
                assert error.code == "CHAT_RUNNING", error
        else:
            fresh = agent.ask_new_chat()
            assert fresh.get("newChat") and fresh.get("chat"), fresh
            assert agent.ask_status()["chat"] == fresh["chat"]
            mode = agent.call("agent.mode", to="guard", uiApproval=True)
            assert mode.get("mode") == "guard" and mode.get("uiApproval") is True, mode
            agent.call("agent.mode", to="full")

            # A second opted-in socket asks for a Guard drag. The UI card is
            # real and chat-scoped; closing the socket must remove it and
            # settle its parked request without a human approval click.
            approval_agent = Agent(sys.argv[1], timeout=20)
            approval_tab = approval_agent.open(url, agent_name="Approval cleanup")
            approval_agent.wait(approval_tab)
            opted = approval_agent.call("agent.mode", to="guard", uiApproval=True)
            assert opted.get("uiApproval") is True, opted
            result = []

            def request_approval():
                try:
                    result.append(approval_agent.drag(approval_tab, "css:#source", "css:#target"))
                except Exception as error:
                    result.append(error)

            pending = threading.Thread(target=request_approval, daemon=True)
            pending.start()
            eventually(lambda: agent.ask_status()["waiting"])
            approval_agent.close()
            pending.join(8)
            assert not pending.is_alive() and result and isinstance(result[0], Exception), result
            eventually(lambda: not agent.ask_status()["waiting"])

        print("PASS native drag path, viewport lifecycle, page PDF/download artifacts, Ask status/new-chat, and approval cleanup")
finally:
    server.shutdown()
