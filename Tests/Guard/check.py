"""End-to-end Guard checks against an isolated SEARCH_PROBE Search app.

Run as: python3 Tests/Guard/check.py WORLD
The app must already be running with bench enabled; all page data is fake and local.
"""
import http.server
import json
import pathlib
import socket
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "Runtime/ask/bench/fixtures/guard.html"
assert len(sys.argv) == 2 and sys.argv[1] not in ("", "main", "1"), "an isolated test world is required"
WORLD = "".join(c for c in sys.argv[1].lower() if c.isascii() and (c.isalnum() or c == "-"))
SOCKET = pathlib.Path.home() / "Library/Application Support" / f"Search ({WORLD})" / "bench.sock"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(FIXTURE.parent), **kwargs)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()


def call(verb, allow_error=False, **args):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(str(SOCKET))
        connection.sendall(json.dumps({"do": verb, **args}).encode() + b"\n")
        reply = json.loads(connection.makefile("rb").readline())
    if not allow_error:
        assert "error" not in reply, reply
    return reply


def eventually(fn, message, seconds=10):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        result = fn()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(message)


def start(op, cancellable=False, **args):
    request = call("guard-test", action="start", op=op, args=args, cancellable=cancellable)
    return request["id"]


def result(request_id):
    return call("guard-test", action="result", id=request_id, allow_error=True)


def wait_result(request_id):
    def finished():
        value = result(request_id)
        return None if value.get("pending") else value
    return eventually(finished, f"Drive request {request_id} did not finish")


def approvals():
    return call("guard-test", action="pending")["approvals"]


def wait_approval():
    return eventually(approvals, "no approval card appeared")


def resolve(card, verdict="allow"):
    return call("guard-test", action="resolve", id=card["id"], verdict=verdict)


def page_value(tab, expression):
    return call("eval", id=tab, js=expression)["value"]


def effects(tab):
    return json.loads(page_value(tab, "JSON.stringify(window.effects)"))


def approved(op, args, tab, action, screenshot=True):
    request_id = start(op, tab=tab, **args)
    card = wait_approval()[0]
    assert card["op"] == op, card
    shot = pathlib.Path(card["shotPath"])
    if screenshot:
        assert shot.is_file(), f"approval evidence screenshot missing: {shot}"
        picture = pathlib.Path(tempfile.gettempdir()) / f"search-guard-{WORLD}.png"
        assert call("winshot", path=str(picture)).get("saved") == str(picture)
        assert picture.is_file(), "native Search window screenshot was not captured"
    assert result(request_id).get("pending") is True, "guarded operation completed before approval"
    assert effects(tab) == [], f"{op} caused a page effect before approval: {effects(tab)}"
    resolve(card)
    wait_result(request_id)
    actual = eventually(lambda: effects(tab) if effects(tab) else None,
                        f"{op} did not cause its one approved side effect")
    assert [event["action"] for event in actual] == [action], actual


try:
    call("ui", welcome=False)
    call("guard-test", action="setup")
    call("guard-test", action="setting", category="signingIn", enabled=True)
    call("guard-test", action="setting", category="destructive", enabled=True)
    call("guard-test", action="setting", category="messages", enabled=True)
    call("guard-test", action="setting", category="payments", enabled=True)
    call("guard-test", action="setting", category="account", enabled=True)
    call("guard-test", action="setting", category="unverified", enabled=True)
    open_id = start("tabs.open", url=f"http://127.0.0.1:{server.server_port}/guard.html", foreground=True)
    tab = wait_result(open_id)["id"]
    call("wait", id=tab, seconds=15)

    # A form with credentials remains untouched until its sign-in approval.
    approved("act.click", {"text": "Sign in"}, tab, "login", screenshot=False)
    call("guard-test", action="setting", category="signingIn", enabled=False)
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("act.click", tab=tab, text="Sign in")
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "login"}], "disabling sign-in category did not allow login")
    call("guard-test", action="setting", category="signingIn", enabled=True)

    call("eval", id=tab, js="document.querySelector('#login').remove()")

    # Sending by the labelled button and by Enter both wait for approval.
    call("eval", id=tab, js="window.effects=[]")
    approved("act.click", {"text": "Send"}, tab, "send")
    call("eval", id=tab, js="window.effects=[]")
    fill_id = start("act.fill", tab=tab, css="#recipient", text="bob@example.test")
    wait_result(fill_id)
    approved("act.press", {"key": "Enter", "css": "#recipient"}, tab, "send")
    assert effects(tab)[0]["recipient"] == "bob@example.test", effects(tab)

    call("eval", id=tab, js="window.effects=[]")
    approved("act.click", {"text": "Delete draft"}, tab, "delete")
    call("eval", id=tab, js="window.effects=[]")
    approved("act.click", {"text": "Buy item"}, tab, "purchase")

    # A generic Next action stays unverified until its effect is known.
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("act.click", tab=tab, text="Next")
    card = wait_approval()[0]
    assert effects(tab) == [], "unknown Next action ran before approval"
    resolve(card)
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "next"}], "generic Next was blocked or did not run")

    # A pending send is tied to the recipient the user approved. Changing it
    # while the card is open replaces that card with a new request.
    call("eval", id=tab, js="window.effects=[]; document.querySelector('#recipient').value='alice@example.test'")
    request_id = start("act.click", tab=tab, text="Send")
    card = wait_approval()[0]
    assert effects(tab) == [], "message was sent before approval"
    call("type", id=tab, selector="#recipient", text="mallory@example.test")
    resolve(card)
    fresh = eventually(lambda: next((rows for rows in [approvals()]
                                     if rows and rows[0]["id"] != card["id"]), None),
                       "changed recipient did not replace the approval card")
    assert result(request_id).get("pending") is True and effects(tab) == [], "recipient change caused a send"
    assert fresh[0]["summary"] != card["summary"] or fresh[0]["id"] != card["id"], (card, fresh)
    resolve(fresh[0])
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "send", "recipient": "mallory@example.test"}],
               "fresh approval did not send to its approved recipient")

    # Denying the card is cancellation: the guarded effect stays at zero.
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("act.click", tab=tab, text="Delete draft", cancellable=True)
    card = wait_approval()[0]
    call("guard-test", action="cancel", id=request_id)
    cancelled = wait_result(request_id)
    assert cancelled.get("code") == "GUARD_CANCELLED" and cancelled.get("guardStopped") is True, cancelled
    assert effects(tab) == [] and not any(row["id"] == card["id"] for row in approvals()), (cancelled, effects(tab))

    # A setting change is applied through the isolated world's real defaults.
    setting = call("guard-test", action="setting", category="messages", enabled=False)
    assert setting["enabled"] is False
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("act.click", tab=tab, text="Send")
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "send", "recipient": "mallory@example.test"}],
               "turning off the message category did not remove its approval")
    call("guard-test", action="setting", category="messages", enabled=True)

    # Delete-account belongs to both categories: disabling destructive alone
    # leaves the account warning active; disabling both makes it pass.
    call("guard-test", action="setting", category="destructive", enabled=False)
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("act.click", tab=tab, text="Delete account")
    overlap = wait_approval()[0]
    assert effects(tab) == [], "overlapping account action ran early"
    resolve(overlap)
    wait_result(request_id)
    call("guard-test", action="setting", category="account", enabled=False)
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("act.click", tab=tab, text="Delete account")
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "delete-account"}], "disabling both categories did not allow the action")
    call("guard-test", action="setting", category="account", enabled=True)
    call("guard-test", action="setting", category="destructive", enabled=True)

    # Opaque JavaScript is itself gated, and the page effect remains zero
    # while the approval card waits.
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("page.eval", tab=tab, js="window.effects.push({action:'eval'}); 'ok'")
    card = wait_approval()[0]
    assert effects(tab) == [], "page.eval ran before approval"
    resolve(card)
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "eval"}], "approved page.eval did not run")

    # JavaScript click and coordinate click use the same guard path.
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("act.click", tab=tab, text="Buy item", tier="js")
    card = wait_approval()[0]
    assert effects(tab) == [], "JS click ran before approval"
    resolve(card)
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "purchase"}], "approved JS click did not run")

    call("eval", id=tab, js="window.effects=[]")
    point = json.loads(page_value(tab, "JSON.stringify((() => { const r=document.querySelector('#purchase').getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2] })())"))
    request_id = start("act.clickAt", tab=tab, x=point[0], y=point[1])
    card = wait_approval()[0]
    assert effects(tab) == [], "coordinate click ran before approval"
    resolve(card)
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "purchase"}], "approved coordinate click did not run")

    # Unknown primitive names ask by default; after approval, disabling the
    # category lets the same harmless confirmation through without a card.
    call("eval", id=tab, js="window.effects=[]")
    call("guard-test", action="setting", category="unverified", enabled=True)
    request_id = start("act.click", tab=tab, text="Confirm selection")
    card = wait_approval()[0]
    assert effects(tab) == [], "unknown confirmation ran before approval"
    resolve(card)
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "confirm"}], "approved confirmation did not run")

    call("guard-test", action="setting", category="unverified", enabled=False)
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("act.click", tab=tab, text="Confirm selection")
    wait_result(request_id)
    eventually(lambda: effects(tab) == [{"action": "confirm"}], "unverified-off confirm did not complete")
    # A page cannot replace the isolated driver with a forged safe target.
    call("guard-test", action="setting", category="unverified", enabled=True)
    call("eval", id=tab, js="window.effects=[]; window.__drive={v:999,resolve:()=>document.querySelector('#harmless'),act:()=>({ok:true})}; true")
    request_id = start("act.click", tab=tab, text="Send")
    card = wait_approval()[0]
    assert "messages" in card["categories"], card
    assert effects(tab) == []
    resolve(card, "deny")
    assert wait_result(request_id)["code"] == "GUARD_CANCELLED"
    assert effects(tab) == []

    # Refresh captures fresh evidence without approving the pending action.
    request_id = start("act.click", tab=tab, text="Send")
    card = wait_approval()[0]
    call("guard-test", action="refresh", id=card["id"])
    fresh = eventually(lambda: next((r for r in approvals() if r["id"] != card["id"]), None), "preview did not refresh")
    assert effects(tab) == [] and result(request_id).get("pending")
    resolve(fresh, "deny")
    assert wait_result(request_id)["guardStopped"] is True

    # A nested span is still the Send control.
    call("eval", id=tab, js="document.querySelector('#message button').innerHTML='<span id=send-inner>Send</span>'")
    request_id = start("act.click", tab=tab, css="#send-inner", tier="js")
    card = wait_approval()[0]
    assert "messages" in card["categories"] and effects(tab) == []
    resolve(card)
    wait_result(request_id)
    eventually(lambda: len(effects(tab)) == 1, "nested send did not execute once")

    # Capture the actual pending card and settings, after onboarding is hidden.
    call("eval", id=tab, js="window.effects=[]")
    request_id = start("act.click", tab=tab, text="Send")
    card = wait_approval()[0]
    evidence_dir = ROOT / "Tests/Guard/evidence"
    evidence_dir.mkdir(exist_ok=True)
    call("winshot", path=str(evidence_dir / "approval.png"))
    call("ui", settings=True)
    call("winshot", path=str(evidence_dir / "settings.png"))
    call("ui", settings=False)
    resolve(card, "deny")
    assert effects(tab) == []
    print("PASS native Guard approvals, stale recipient, cancellation, category overlap, eval, JS click, clickAt, unverified toggle, forged driver, refresh, nested target")
finally:
    server.shutdown()
