"""Native timed-drag checks on an already running disposable Search world.

Run: python3 Tests/Agent/drag_hold_check.py WORLD [OUTPUT.json]
"""
import http.server
import json
import pathlib
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sdk"))
sys.path.insert(0, str(ROOT / "Runtime/ask/bench"))
from search_agent import Agent, AgentError
import run as bench

HTML = b'''<!doctype html><meta charset="utf-8"><title>Drag hold check</title>
<style>html,body{margin:0;width:100%;height:100%;background:#ddd}</style>
<script>
window.events=[];window.atEnd=false;window.ticks=0;window.dialogAtEnd=false;
function frame(){ticks++;requestAnimationFrame(frame)}requestAnimationFrame(frame);
for(const type of ['mousedown','mousemove','mouseup'])document.addEventListener(type,e=>{
  events.push({type,x:e.clientX,y:e.clientY,buttons:e.buttons,trusted:e.isTrusted,t:performance.now(),ticks});
  if(type==='mousemove'&&e.buttons===1&&e.clientX===120&&e.clientY===120){
    atEnd=true;if(dialogAtEnd)setTimeout(()=>alert('hold interruption'),100);
  }
});
</script>'''

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(HTML)
    def log_message(self, *_): pass

def run(world, output=None):
    assert world not in ("", "main", "test"), "use a disposable test world"
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/"
    evidence = []
    def record(row):
        evidence.append(row)
        if output: pathlib.Path(output).write_text(json.dumps(evidence, indent=2) + "\n")
    def read(tab, js):
        return json.loads(bench.bench_cli(world, ["eval", tab, js]).stdout)
    def eventually(fn):
        until = time.monotonic() + 5
        while time.monotonic() < until:
            value = fn()
            if value: return value
            time.sleep(.02)
        raise AssertionError("condition did not become true")
    with Agent(world) as agent:
        def fresh():
            tab = bench.bench_cli(world, ["open", url]).stdout.strip().splitlines()[-1]
            bench.bench_cli(world, ["wait", tab, "10"])
            agent.attach(tab)
            assert read(tab, "events.length") == 0
            return tab
        def check_events(tab):
            events = read(tab, "events")
            downs = [e for e in events if e["type"] == "mousedown"]
            ups = [e for e in events if e["type"] == "mouseup"]
            moves = [e for e in events if e["type"] == "mousemove" and e["buttons"] == 1]
            # WebKit can coalesce intermediate moves before DOM delivery.
            assert len(downs) == len(ups) == 1 and 1 <= len(moves) <= 4, events
            assert (moves[-1]["x"], moves[-1]["y"]) == (120, 120), events
            assert sum((e["x"], e["y"]) == (120, 120) for e in moves) == 1, events
            assert all(e["trusted"] for e in events), events
            assert downs[0]["buttons"] == 1 and ups[0]["buttons"] == 0, events
            assert all((e["x"], e["y"]) == (120, 120) for e in ups), events
            return events, ups[0]["t"] - moves[-1]["t"], ups[0]["ticks"] - moves[-1]["ticks"]
        try:
            for hold in [None, 0, 350, 2000]:
                tab = fresh()
                try:
                    args = {} if hold is None else {"holdMs": hold}
                    result = agent.drag(tab, [40, 40], [120, 120], steps=4, **args)
                    events, elapsed, frames = check_events(tab)
                    record({"case":"timing","holdMs":hold,"elapsed_ms":elapsed,"frames_during_hold":frames,"events":events,"result":result})
                    assert result.get("ok") and result["holdMs"] == (hold or 0), result
                    assert elapsed >= (hold or 0) - 2, (hold, elapsed)
                    assert elapsed < (hold or 0) + 750, (hold, elapsed)
                    if hold: assert frames >= hold / 100, ("hold blocked page rendering", hold, frames)
                finally: bench.bench_cli(world, ["close", tab], check=False)
            tab = fresh()
            try:
                for hold in [-1, 2001, 1.5, "350", True, None]:
                    try:
                        agent.drag(tab, [40,40], [120,120], holdMs=hold)
                        raise AssertionError(f"accepted invalid hold {hold!r}")
                    except AgentError as error: assert error.code == "INVALID_ARGUMENT", error
                assert read(tab, "events.length") == 0, "invalid hold dispatched native input"
                record({"case":"invalid_values","rejected":6,"native_events":0})
            finally: bench.bench_cli(world, ["close", tab], check=False)
            for interruption in ["cancel", "detach", "dialog"]:
                tab = fresh()
                result = []
                try:
                    if interruption == "dialog":
                        agent.dialogs(tab, True)
                        read(tab, "dialogAtEnd=true")
                    with agent._cond: request_id = agent._next
                    def drag():
                        try: result.append(agent.drag(tab, [40,40], [120,120], steps=4, holdMs=2000))
                        except Exception as error: result.append(error)
                    worker = threading.Thread(target=drag)
                    worker.start()
                    if interruption != "dialog": eventually(lambda: read(tab, "atEnd"))
                    began = time.monotonic()
                    if interruption == "cancel": agent.request_cancel(request_id)
                    elif interruption == "detach": agent.detach(tab)
                    worker.join(5)
                    assert not worker.is_alive() and len(result) == 1, result
                    if interruption == "dialog":
                        assert isinstance(result[0], dict) and result[0].get("dialogPending"), result
                        pending = eventually(lambda: agent.dialogs(tab).get("pending"))
                        agent.answer_dialog(tab, pending["id"], True)
                    else:
                        assert isinstance(result[0], AgentError) and result[0].code in ("CANCELLED", "GUARD_CANCELLED"), result
                    eventually(lambda: read(tab, "events.some(e=>e.type==='mouseup')"))
                    events, elapsed, frames = check_events(tab)
                    response_seconds = time.monotonic()-began
                    record({"case":interruption,"elapsed_ms":elapsed,"response_seconds":response_seconds,"events":events,
                            "result":result[0] if isinstance(result[0],dict) else {"code":result[0].code}})
                    assert elapsed < 1000 and response_seconds < 1, (interruption, elapsed, response_seconds)
                finally:
                    bench.bench_cli(world, ["close", tab], check=False)
        finally:
            server.shutdown()
            server.server_close()
    return evidence

if __name__ == "__main__":
    result = run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    if len(sys.argv) > 2: pathlib.Path(sys.argv[2]).write_text(json.dumps(result, indent=2) + "\n")
    print("PASS native drag holds: default/zero/350/2000ms, responsive rendering, invalid inputs, cancellation, ownership loss and dialog interruption")
