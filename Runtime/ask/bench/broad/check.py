#!/usr/bin/env python3
"""Offline checks for answer preservation and seat cleanup on failed runs."""
import tempfile
import json
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location("broad_runner", Path(__file__).with_name("run.py"))
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)

assert run.answer({"chat": {"messages": [{"role": "agent", "text": "Part one.\nPart two.",
    "blocks": [{"kind": "text", "text": "Part one."}, {"kind": "tool"}, {"kind": "text", "text": "Part two."}]}]}}) == "Part one.\nPart two."

calls = []
status = {"finished": True, "error": "test provider failure"}
def call(world, **request):
    calls.append(request)
    if request["action"] == "start":
        return {"id": "seat"}
    if request["action"] == "status":
        return status
    return {"released": True}

run.call = call
actual_wait = run.wait
run.wait = lambda *args: False
task = {"task_id": "test", "suite": "bu-v1", "confirmed_task": "Test task"}
with tempfile.TemporaryDirectory() as folder:
    try:
        run.run_task("isolated", task, Path(folder), 1)
    except RuntimeError as exc:
        assert "provider failure" in str(exc)
        saved = json.loads((Path(folder) / "bu-v1/test/trace.json").read_text())
        assert saved["error"] == status["error"], "host failure evidence must be retained"
    else:
        raise AssertionError("provider failure was silently scored")
assert calls[-1]["action"] == "release", "failed task must release its seat"

calls.clear()
run.judge_prompt = lambda *args: "Judge task"
with tempfile.TemporaryDirectory() as folder:
    try:
        run.grade("isolated", task, {"observations": []}, Path(folder), Path(folder))
    except RuntimeError as exc:
        assert "provider failure" in str(exc)
    else:
        raise AssertionError("judge failure was silently scored")
    assert json.loads((Path(folder) / "bu-v1/test/judge.json").read_text())["error"] == status["error"]
assert calls[-1]["action"] == "release", "failed judge must release its seat"
print("PASS full answer preservation and failed task/judge cleanup")

for invalid_task, verdict in [(task, {"verdict": 1}),
                             ({**task, "suite": "odysseys", "rubrics": {"R1": "test"}}, {"rubric_scores": {"R1": True}})]:
    calls.clear()
    status = {"finished": True, "chat": {"messages": [{"role": "agent", "text": json.dumps(verdict)}]}}
    with tempfile.TemporaryDirectory() as folder:
        try:
            run.grade("isolated", invalid_task, {"observations": []}, Path(folder), Path(folder))
        except ValueError:
            pass
        else:
            raise AssertionError("invalid judge output was accepted")
    assert calls[-1]["action"] == "release"
print("PASS invalid judge output rejection and cleanup")

# Provider accounting keeps cached input inside total input, reasoning inside output.
spec = importlib.util.spec_from_file_location("broad_audit", Path(__file__).with_name("audit.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
assert audit.usage([{ "usage": {"input_tokens": 100, "input_tokens_details": {"cached_tokens": 60},
    "output_tokens": 20, "output_tokens_details": {"reasoning_tokens": 15}}}, {"usage": None}]) == {
    "input_tokens": 100, "cached_tokens": 60, "uncached_input_tokens": 40, "output_tokens": 20, "reasoning_tokens": 15,
    "missing_usage": 1}
assert audit.usage([{"usage": {"input_tokens": 100}}, {"usage": None}], requests=3)["unreported_requests"] == 2, "aborted requests without a round must not disappear"
print("PASS provider token accounting")
assert audit.repeated_reads([
    {"op": "page.snapshot", "result": {"error": "timeout"}},
    {"op": "page.snapshot", "result": {"error": "timeout"}},
    {"op": "page.snapshot", "result": {"url": "https://example.test", "snapshot": "Page content"}},
    {"op": "page.snapshot", "result": {"url": "https://example.test", "snapshot": "Page content"}},
    {"op": "page.text", "result": {"url": "https://example.test", "text": "Page content"}},
    {"op": "page.snapshot", "result": {"url": "https://different.test", "snapshot": "Page content"}}
]) == {"page.snapshot": 1}, "missing observation content and different pages are not repeated reads"
print("PASS repeated-read accounting")

# A zero score is preserved; failures remain recoverable; mismatched frozen inputs fail closed.
with tempfile.TemporaryDirectory() as temporary:
    folder = Path(temporary)
    metadata = {"seconds": 1, "model": "codex/gpt-6-luna", "effort": "xhigh", "timeout": 600,
                "bu_revision": run.BU_REV, "odyssey_revision": run.ODYSSEY_REV, "expected": 2, "hashes": {}}
    for name in ["harness.js", "drive.js"]:
        filename = "Runtime/ask/" + name
        metadata["hashes"][filename] = run.hashlib.sha256(b"frozen").hexdigest()
        for path in [folder / "inputs" / filename, folder / "inputs/SearchBroad.app/Resources/ask" / name]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"frozen")
    (folder / "metadata.json").write_text(json.dumps(metadata))
    rows = [{"suite": "bu-v1", "task_id": "zero", "score": 0, "chat": "executor"},
            {"suite": "odysseys", "task_id": "missing", "infrastructure_error": "host crash"}]
    (folder / "results.json").write_text(json.dumps(rows))
    directory = folder / "bu-v1/zero"
    directory.mkdir(parents=True)
    for name, value in [("trace.json", {"suite": "bu-v1", "task_id": "zero", "id": "executor"}),
                        ("judge.json", {"id": "judge"})]:
        (directory / name).write_text(json.dumps(value))
    (directory / "result.txt").write_text("0")
    catalog = [{"suite": r["suite"], "task_id": r["task_id"]} for r in rows]
    old, selected, valid = run.resume_inputs(folder, catalog, 600)
    assert len(selected) == 2 and valid == rows[:1]
    for invalid in ["deadline", "result", "hash", "unfinished"]:
        saved_metadata = (folder / "metadata.json").read_text()
        if invalid == "result":
            (directory / "result.txt").write_text("1")
        elif invalid == "hash":
            (folder / "inputs/SearchBroad.app/Resources/ask/harness.js").write_bytes(b"changed")
        elif invalid == "unfinished":
            (folder / "metadata.json").write_text(json.dumps({k: v for k, v in metadata.items() if k != "seconds"}))
        try:
            run.resume_inputs(folder, catalog, 60 if invalid == "deadline" else 600)
        except ValueError:
            pass
        else:
            raise AssertionError("unsafe resume accepted: " + invalid)
        (folder / "metadata.json").write_text(saved_metadata)
        (directory / "result.txt").write_text("0")
        (folder / "inputs/SearchBroad.app/Resources/ask/harness.js").write_bytes(b"frozen")
print("PASS frozen resume identity, zero-score preservation and mismatch rejection")

original_call, original_sleep = run.call, run.time.sleep
attempts = []
def pages(world, **request):
    attempts.append(request)
    if len(attempts) == 1:
        raise RuntimeError("pages only works on a --test run")
    return {"ok": True}
run.call, run.time.sleep = pages, lambda _: None
try:
    assert run.ready_pages("isolated") == {"ok": True} and len(attempts) == 2
    def denied(world, **request):
        raise RuntimeError("unrelated failure")
    run.call = denied
    try:
        run.ready_pages("isolated")
    except RuntimeError as exc:
        assert str(exc) == "unrelated failure"
    else:
        raise AssertionError("unrelated readiness failure swallowed")
finally:
    run.call, run.time.sleep = original_call, original_sleep
print("PASS bounded window readiness and unrelated error preservation")

original_call, original_clock, original_sleep = run.call, run.time.monotonic, run.time.sleep
try:
    for scenario, reserve in [('reminder', 4), ('hard_deadline', 4), ('completion_race', 4), ('no_reminder', 0)]:
        clock, requests, stopped, racing = [0], [], [False], [False]
        def timed_call(world, **request):
            requests.append(request)
            if request['action'] == 'stop': stopped[0] = True; return {}
            if request['action'] == 'steer' and scenario == 'completion_race':
                racing[0] = True
                raise RuntimeError('steer requires an active executor and text')
            if request['action'] == 'status':
                return {'finished': stopped[0] or racing[0] or (scenario != 'hard_deadline' and clock[0] >= 8)}
            return {}
        run.call, run.time.monotonic = timed_call, lambda: clock[0]
        def advance(seconds): clock[0] += seconds
        run.time.sleep = advance
        assert actual_wait('isolated', 'seat', 10, reserve) == (scenario == 'hard_deadline')
        assert sum(x['action'] == 'steer' for x in requests) == bool(reserve)
        assert sum(x['action'] == 'stop' for x in requests) == (scenario == 'hard_deadline')
finally:
    run.call, run.time.monotonic, run.time.sleep = original_call, original_clock, original_sleep
print('PASS one-shot completion reserve, hard deadline, finish race and judge default')
