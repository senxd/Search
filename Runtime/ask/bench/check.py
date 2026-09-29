"""Runner checks without a provider or browser: python3 Runtime/ask/bench/check.py."""
import run

assert run.RATE_LIMIT.search('openrouter 429 rate limited')
assert run.RATE_LIMIT.search('codex 503 unavailable')
assert run.RATE_LIMIT.search('devin 429 unavailable')
assert not run.RATE_LIMIT.search('openrouter 402 credits: requested 65536, afford 2461')
assert not run.RATE_LIMIT.search('codex 401 Unauthorized')

class Agent:
    def call(self, *args, **kwargs):
        return {"chat": "check"}

def preflight(chat, done=True):
    original = run.wait_turn
    run.wait_turn = lambda *args: (done, None, chat)
    try:
        return run.preflight(Agent, "/unused", "check", "codex", "gpt-6-sol",
                             lambda: (_ for _ in ()).throw(AssertionError("unexpected relaunch")))
    finally:
        run.wait_turn = original

assert preflight({"messages": [{"role": "agent", "text": "OK"}]})[0] == "codex/gpt-6-sol"
for chat, done, expected in [
    ({"messages": [{"role": "note", "text": "codex 401 secret error body"}]}, True, "HTTP 401"),
    ({"messages": [{"role": "note", "text": "openrouter 402 credits"}]}, True, "HTTP 402"),
    ({"messages": [{"role": "agent", "text": "wrong answer"}]}, True, "did not reply OK"),
    ({}, False, "timed out"),
]:
    try:
        preflight(chat, done)
        raise AssertionError("failed preflight was accepted")
    except run.BenchError as error:
        assert expected in str(error), error
        assert "secret" not in str(error), error

print("PASS preflight stops auth/credit/timeout failures, rate-limit status parsing")
