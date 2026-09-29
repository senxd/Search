"""Live check: python3 sdk/check_request_lifecycle.py WORLD [--server-timeout].

Requires a running dev Search with its agent socket enabled. Opens only an
agent-owned data page and closes it with the session. Does not start Search.
"""
import json
import socket
import sys
import time
from urllib.parse import quote

from search_agent import Agent, AgentError, AgentTimeout


def finished(agent, request_id, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        receipt = agent.request_status(request_id)
        if receipt["state"] == "finished":
            return receipt
        time.sleep(0.05)
    raise AssertionError(f"request {request_id} still running")


def completion_event(agent, request_id):
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        event = agent.next_event(0.1)
        if event and event["event"] == "request.finished" and event["data"]["requestId"] == request_id:
            return event["data"]
    raise AssertionError("missing scoped request.finished")


def run(world, server_timeout=False):
    with Agent(world, timeout=10) as agent:
        agent.subscribe(["request.finished"])
        tab = agent.open("data:text/html," + quote('<input id="field"><title>Request lifecycle check</title>'))
        agent.wait(tab)
        agent.eval(tab, "window.__lateFlag = 0")

        try:
            agent.call("act.type", tab=tab, css="#field", text="abcdefghijklmnopqrstuvwxyz" * 3,
                       delay=50, timeout=0.15)
            raise AssertionError("typing should exceed client patience")
        except AgentTimeout as error:
            typing_id = error.request_id
        cancellation = agent.request_cancel(typing_id)
        assert cancellation["cancelRequested"]
        assert finished(agent, typing_id)["outcome"] == "cancelled"
        assert completion_event(agent, typing_id)["outcome"] == "cancelled"
        value = agent.eval(tab, "document.querySelector('#field').value")
        assert len(value) < 78, value
        time.sleep(0.2)
        assert agent.eval(tab, "document.querySelector('#field').value") == value

        try:
            agent.call("page.code", tab=tab,
                       js="await new Promise(r => setTimeout(r, 600)); window.__lateFlag++; return 1;",
                       timeout=0.1)
            raise AssertionError("JavaScript should exceed client patience")
        except AgentTimeout as error:
            js_id = error.request_id
        cancellation = agent.request_cancel(js_id)
        assert cancellation["state"] == "running" and cancellation["outcome"] == "unknown"
        assert finished(agent, js_id)["outcome"] == "succeeded"
        assert completion_event(agent, js_id)["outcome"] == "succeeded"
        assert agent.eval(tab, "window.__lateFlag") == 1

        if server_timeout:
            try:
                agent.call("page.code", tab=tab,
                           js="await new Promise(r => setTimeout(r, 31000)); window.__lateFlag++; return 2;",
                           timeout=35)
                raise AssertionError("server deadline should fire")
            except AgentError as error:
                assert error.code == "TIMEOUT", error
                assert error.receipt["state"] == "running" and error.receipt["outcome"] == "unknown"
                timeout_id = error.request_id
            assert finished(agent, timeout_id)["outcome"] == "succeeded"
            assert completion_event(agent, timeout_id)["outcome"] == "succeeded"
            assert agent.eval(tab, "window.__lateFlag") == 2

        original = agent.call("ping")["receipt"]["requestId"]
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as other:
            other.settimeout(3)
            other.connect(agent.path)
            reader = other.makefile("rb")

            def raw(request):
                other.sendall((json.dumps(request) + "\n").encode())
                return json.loads(reader.readline())

            request = {"id": "duplicate-check", "op": "ping"}
            assert raw(request)["result"]["pong"]
            duplicate = raw(request)
            assert duplicate["code"] == "DUPLICATE_REQUEST_ID"
            assert duplicate["receipt"]["state"] == "finished"
            status = raw({"id": "isolation-check", "op": "request.status", "args": {"requestId": original}})
            assert status["code"] == "REQUEST_NOT_FOUND"
            reader.close()
        print("live request lifecycle checks passed")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    run(sys.argv[1], "--server-timeout" in sys.argv[2:])
