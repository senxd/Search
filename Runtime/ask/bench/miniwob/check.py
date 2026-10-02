"""Fast, provider-free checks for the MiniWoB runner."""

import pathlib
import tempfile
import importlib.util
import json

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("miniwob_runner", HERE / "run.py")
miniwob = importlib.util.module_from_spec(spec)
spec.loader.exec_module(miniwob)


tasks = miniwob.catalog()
assert len(tasks) == 125
assert len({task["id"] for task in tasks}) == 125
assert len(miniwob.choose_tasks(tasks, "click-button,choose-list")) == 2
for task in tasks:
    assert task["description"]
    assert task["id"] == "miniwob." + task["subdomain"]

stochastic = {task["subdomain"] for task in tasks if task["nondeterministic"]}
assert stochastic == {"click-pie", "click-pie-nodelay", "terminal", "visual-addition"}

assert miniwob.score_episode(True, 1) == 1
assert miniwob.score_episode(True, 0.01) == 1
assert miniwob.score_episode(True, 0) == 0
assert miniwob.score_episode(True, -1) == 0
assert miniwob.score_episode(False, 1) == 0
assert miniwob.score_episode(True, None) == 0

assert "Math.seedrandom(0)" in miniwob.GOAL_ADAPTER
assert "core.EPISODE_MAX_TIME = __EPISODE_MS__" in miniwob.GOAL_ADAPTER
assert "WOB_RAW_REWARD_GLOBAL" not in miniwob.GOAL_ADAPTER
assert "core.clearTimer()" in miniwob.GOAL_ADAPTER
assert miniwob.VIEWPORT == {"width": 332, "height": 214}
assert "click-menu-2" in miniwob.GOAL_ADAPTER
assert "use-colorwheel-2" in miniwob.GOAL_ADAPTER
assert miniwob.max_round_failure({"messages": [{"role": "note",
                                                 "isError": True,
                                                 "text": "reached the 100-step limit"}]})
assert not miniwob.infra_note({"messages": [{"role": "note",
                                              "isError": True,
                                              "text": "reached the 100-step limit"}]})
assert miniwob.infra_note({"messages": [{"role": "note",
                                          "isError": True,
                                          "text": "Codex host crashed"}]})
try:
    miniwob.assert_browser_profile({"mode": "full", "messages": [{"role": "agent", "tools": [
        {"name": "page.eval"}]}]})
except miniwob.RunError:
    pass
else:
    raise AssertionError("benchmark profile must reject page.eval")

miniwob.assert_browser_profile({"mode": "full", "messages": []})
for mode in [None, "guard", "read", "invalid"]:
    try:
        miniwob.assert_browser_profile({"mode": mode, "messages": []})
    except miniwob.RunError as error:
        assert "Full mode" in str(error)
    else:
        raise AssertionError("benchmark must reject confirmation mode")

with tempfile.TemporaryDirectory() as directory:
    output = pathlib.Path(directory)
    source = output / 'debug-binary'
    source.write_bytes(b'fixture-binary')
    target = output / 'SearchBenchmark.app/Contents/MacOS/SearchBenchmark'
    assert miniwob.bundle_debug(source, target) == target
    assert target.read_bytes() == source.read_bytes()
    assert miniwob.plistlib.loads((target.parent.parent / 'Info.plist').read_bytes())['CFBundleExecutable'] == target.name
    assert miniwob.bench.app_bundle_id(target) == miniwob.BENCH_BUNDLE_ID
    assert miniwob.bench.webkit_container(target) == miniwob.BENCH_BUNDLE_ID
    for name in ('harness.js', 'drive.js', 'skills/captcha-solver/SKILL.md'):
        assert (target.parent.parent / 'Resources/ask' / name).read_bytes() == (miniwob.REPO / 'Runtime/ask' / name).read_bytes()
    audit = output / "harness.audit.jsonl"
    audit.write_text("\n".join(json.dumps(row) for row in [
        {"kind": "request", "chat": "sample", "provider": "codex",
         "model": "gpt-6-luna", "effort": "xhigh"},
        {"kind": "round", "chat": "sample", "usage": {
            "input_tokens": 10,
            "input_tokens_details": {"cached_tokens": 2},
            "output_tokens": 5,
            "output_tokens_details": {"reasoning_tokens": 3}}},
        {"kind": "done", "chat": "sample", "failed": False,
         "failure": "none"},
    ]) + "\n", encoding="utf-8")
    miniwob.world_folder = lambda _: str(output)
    metrics = miniwob.audit_metrics("sample-world", "sample")
    assert metrics["requests"] == 1 and metrics["rounds"] == 1
    assert metrics["pending_requests"] == 0
    assert metrics["input_tokens"] == 10 and metrics["cached_tokens"] == 2
    assert metrics["output_tokens"] == 5 and metrics["reasoning_tokens"] == 3
    assert miniwob.validate_audit_turn(dict(metrics))["cancelled_requests"] == 0
    cancelled = dict(metrics, pending_requests=1)
    assert miniwob.validate_audit_turn(cancelled, cancelled=True)["cancelled_requests"] == 1
    retry_records = [json.loads(line) for line in audit.read_text().splitlines()]
    retry_records.insert(1, {'kind': 'retry', 'chat': 'sample', 'provider': 'codex', 'status': 503, 'attempt': 1})
    retry_records.insert(2, dict(retry_records[0], retry=1))
    audit.write_text('\n'.join(json.dumps(record) for record in retry_records) + '\n')
    retried = miniwob.audit_metrics('sample-world', 'sample')
    assert retried['requests'] == 2 and retried['provider_retries'] == 1 and retried['rejected_requests'] == 1
    assert miniwob.validate_audit_turn(retried)['cancelled_requests'] == 0
    retry_records[1]['kind'] = 'rejection'
    terminal_records = [retry_records[0], retry_records[1], {'kind': 'done', 'chat': 'sample', 'failed': True, 'failure': 'harness'}]
    audit.write_text('\n'.join(json.dumps(record) for record in terminal_records) + '\n')
    rejected = miniwob.audit_metrics('sample-world', 'sample')
    assert rejected['rejected_requests'] == 1 and rejected['pending_requests'] == 0 and rejected['failed_turns'] == 1
    try:
        miniwob.validate_audit_turn(dict(metrics, pending_requests=2), cancelled=True)
    except miniwob.RunError:
        pass
    else:
        raise AssertionError("runner cancellation may leave at most one provider request pending")

    miniwob.codex_credential = lambda: "fixture-secret"
    staged = miniwob.stage_codex("fixture-world")
    assert staged.stat().st_mode & 0o777 == 0o600
    assert json.loads(staged.read_text(encoding="utf-8")) == {"codex": "fixture-secret"}
    try:
        miniwob.stage_codex("fixture-world")
    except FileExistsError:
        pass
    else:
        raise AssertionError("staging must not overwrite an existing world credential")

    metadata = {"selected_ids": [tasks[0]["id"]], "selected_count": 1}
    miniwob.snapshot_row([{"id": tasks[0]["id"], "seed": 0,
                           "status": "failure", "score": 0,
                           "action_failures": {"page.click": 1},
                           "screenshot_pixels": {"width": 664, "height": 428},
                           "screenshot_scale": 2,
                           "goal": "fixture-secret"}], output, metadata)
    saved = (output / "results.json").read_text(encoding="utf-8")
    assert "fixture-secret" not in saved
    assert '"goal"' not in saved
    assert '"action_failures": {\n        "page.click": 1' in saved

    row = json.loads(saved)["results"][0]
    assert row["screenshot_pixels"] == {"width": 664, "height": 428}
    assert row["screenshot_scale"] == 2

print("PASS MiniWoB catalog, deterministic score rule, seeded reset, and prompt-free result serialization")
