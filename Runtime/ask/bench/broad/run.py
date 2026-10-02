#!/usr/bin/env python3
"""Batch public BU V1 and Odysseys tasks through independent native Ask seats."""
import argparse
import ast
import base64
import collections
import concurrent.futures
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
spec = importlib.util.spec_from_file_location("miniwob_runner", HERE.parent / "miniwob/run.py")
mini = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mini)
bench = mini.bench
BU_REV = "1e0e2f1ed12d3dfbdfab6b7bff415ec090ff9f74"
ODYSSEY_REV = "837814633ef948479abb3d142458f0acdb73fa65"


def download(repo, revision, path, target):
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(f"https://raw.githubusercontent.com/{repo}/{revision}/{path}", timeout=60) as response:
            target.write_bytes(response.read())
    return target.read_bytes()


def catalogs(cache):
    from cryptography.fernet import Fernet
    encrypted = download("browser-use/benchmark", BU_REV, "BU_Bench_V1.enc", cache / BU_REV / "BU_Bench_V1.enc")
    key = base64.urlsafe_b64encode(hashlib.sha256(b"BU_Bench_V1").digest())
    bu = json.loads(Fernet(key).decrypt(base64.b64decode(encrypted)))
    od = json.loads(download("ljang0/Odysseys", ODYSSEY_REV, "data/odysseys.json", cache / ODYSSEY_REV / "odysseys.json"))
    assert len(bu) == 100 and len(od) == 200
    tasks = [{**task, "suite": suite} for suite, rows in [("bu-v1", bu), ("odysseys", od)] for task in rows]
    assert len({(task["suite"], task["task_id"]) for task in tasks}) == 300
    return tasks


def call(world, **request):
    path = str(Path(mini.world_folder(world)) / "bench.sock")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(40)
        client.connect(path)
        client.sendall(json.dumps(request).encode() + b"\n")
        reply = client.makefile("rb").readline()
    result = json.loads(reply)
    if result.get("error") and request.get("action") != "status":
        raise RuntimeError(result["error"])
    return result


def ready_pages(world):
    # The socket can accept requests before the native window is attached.
    deadline = time.monotonic() + 15
    while True:
        try:
            return call(world, do="pages", on=True)
        except RuntimeError as exc:
            if str(exc) != "pages only works on a --test run" or time.monotonic() >= deadline:
                raise
            time.sleep(.2)


def wait(world, run_id, timeout, reserve=0):
    deadline = time.monotonic() + timeout
    reminded = False
    while time.monotonic() < deadline:
        status = call(world, do="agent-run", action="status", id=run_id)
        if status.get("finished"):
            return False
        if reserve and not reminded and time.monotonic() >= deadline - reserve:
            try:
                call(world, do="agent-run", action="steer", id=run_id,
                     text=f"About {reserve} seconds remain in this task budget. Finish the current verification, then report verified findings and any incomplete requirements through done before the deadline. Avoid starting another broad search.")
            except RuntimeError as exc:
                if str(exc) != "steer requires an active executor and text" or not call(world, do="agent-run", action="status", id=run_id).get("finished"):
                    raise
                return False
            reminded = True
        time.sleep(2)
    call(world, do="agent-run", action="stop", id=run_id)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if call(world, do="agent-run", action="status", id=run_id).get("finished"):
            return True
        time.sleep(.2)
    raise RuntimeError("cancelled harness seat did not complete")


def release(world, run_id):
    if not call(world, do="agent-run", action="status", id=run_id).get("finished"):
        call(world, do="agent-run", action="stop", id=run_id)
        wait(world, run_id, 30)
    call(world, do="agent-run", action="release", id=run_id)


def answer(trace):
    messages = trace.get("chat", {}).get("messages", [])
    agents = [row for row in messages if row.get("role") == "agent"]
    if not agents:
        return ""
    return agents[-1].get("text", "")


def run_task(world, task, output, timeout, reserve=0):
    started = time.monotonic()
    prompt = task["confirmed_task"]
    if task.get("website"):
        prompt = f"Start at {task['website']}.\n\n" + prompt
    run_id = call(world, do="agent-run", action="start", prompt=prompt, fixtures=task.get("category") == "InteractionTests")["id"]
    try:
        timed_out = wait(world, run_id, timeout, reserve)
        trace = call(world, do="agent-run", action="status", id=run_id, detail=True)
        trace.update(task_id=task["task_id"], suite=task["suite"], seconds=time.monotonic() - started, timeout=timed_out)
        failure = trace.get("error")
        folder = output / task["suite"] / task["task_id"]
        folder.mkdir(parents=True, exist_ok=True)
        for i, observation in enumerate(trace.get("observations", [])):
            path = observation.get("screenshot")
            if not path and observation.get("op") == "page.screenshot":
                path = observation.get("result", {}).get("path")
            if path and Path(path).is_file():
                target = folder / f"step-{i:03}.png"
                shutil.copy2(path, target)
                observation["screenshot"] = str(target)
        (folder / "trace.json").write_text(json.dumps(trace, indent=2))
        if failure and "-step limit" not in failure:
            raise RuntimeError(f"harness failure for {task['task_id']}: {failure}")
        steps = [{"step_num": i, "action": row["op"], "arguments": row["args"],
                  "response": json.dumps(row["result"]), "screenshot": row.get("screenshot", "")}
                 for i, row in enumerate(trace.get("observations", []))]
        steps.append({"step_num": len(steps), "final": True, "response": answer(trace)})
        (folder / "steps.jsonl").write_text("".join(json.dumps(row) + "\n" for row in steps))
        return trace
    finally:
        release(world, run_id)

def judge_prompt(task, trace, cache):
    steps = [f"{i}: {row['op']} {json.dumps(row['args'])}\nObserved: {json.dumps(row['result'])}"
             for i, row in enumerate(trace.get("observations", []))]
    if task["suite"] == "bu-v1":
        source = download("browser-use/benchmark", BU_REV, "judge.py", cache / BU_REV / "judge.py").decode()
        # Execute only the upstream prompt constructor with inert message containers.
        tree = ast.parse(source)
        nodes = [row for row in tree.body if isinstance(row, ast.FunctionDef)]
        def container(**kwargs):
            return kwargs
        env = {name: container for name in ["BaseMessage", "ContentPartImageParam", "ContentPartTextParam", "ImageURL", "SystemMessage", "UserMessage"]}
        exec(compile(ast.fix_missing_locations(ast.Module(body=[ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)] + nodes, type_ignores=[])), "upstream_judge", "exec"), env)
        messages = env["construct_judge_messages"](task["confirmed_task"], answer(trace), steps, [], task.get("answer"))
        return messages[0]["content"] + "\n\n" + messages[1]["content"][0]["text"]
    return ("Evaluate each supplied rubric independently against observed browser actions, screenshots and the final answer. "
            "Credit a rubric only when its requirement and verification are evidenced. Never trust a success claim alone. "
            "Missing filters, blocked sites, absent deliverables and unsupported facts fail the relevant rubric. "
            "Return JSON {\"rubric_scores\": {\"R1\": 0 or 1, ...}, \"reasoning\": \"cite evidence for each rubric\"}.\n\n"
            + json.dumps({"task": task["confirmed_task"], "rubrics": task["rubrics"], "actions": steps, "final_answer": answer(trace)}))


def grade(world, task, trace, output, cache):
    images = [row["screenshot"] for row in trace.get("observations", []) if row.get("screenshot")]
    # Retain chronological evidence distributed across the whole trajectory.
    if len(images) > 10:
        images = [images[round(i * (len(images) - 1) / 9)] for i in range(10)]
    run_id = call(world, do="agent-run", action="start", judge=True,
                  prompt=judge_prompt(task, trace, cache), images=images)["id"]
    try:
        if wait(world, run_id, 180):
            raise RuntimeError("judge timed out")
        judged = call(world, do="agent-run", action="status", id=run_id, detail=True)
        folder = output / task["suite"] / task["task_id"]
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "judge.json").write_text(json.dumps(judged, indent=2))
        if judged.get("error"):
            raise RuntimeError("judge failed: " + judged["error"])
        raw = answer(judged).strip()
        if raw.startswith("```"):
            raw = raw.split("\n", 1)[1].rsplit("```", 1)[0]
        result = json.loads(raw)
        if task["suite"] == "bu-v1":
            if not isinstance(result.get("verdict"), bool):
                raise ValueError("invalid BU judge verdict")
            score = int(result["verdict"])
            perfect = bool(score)
        else:
            scores = result.get("rubric_scores", {})
            if set(scores) != set(task["rubrics"]) or not all(type(v) is int and v in (0, 1) for v in scores.values()):
                raise ValueError("invalid rubric scores")
            score = sum(scores.values()) / len(scores)
            perfect = all(scores.values())
        (folder / "result.txt").write_text(str(score))
        return {"task_id": task["task_id"], "suite": task["suite"], "score": score, "perfect": perfect,
                "seconds": trace["seconds"], "timeout": trace["timeout"], "limit": bool(trace.get("error")),
                "tools": len(trace.get("observations", [])), "judgement": result, "chat": trace["id"]}
    finally:
        release(world, run_id)

def resume_inputs(folder, tasks, timeout):
    """Validate a finalized fragment before preserving any scored cases."""
    metadata = json.loads((folder / "metadata.json").read_text())
    if "seconds" not in metadata or (metadata["model"], metadata["effort"], metadata["timeout"],
            metadata["bu_revision"], metadata["odyssey_revision"]) != (
            "codex/gpt-6-luna", "xhigh", timeout, BU_REV, ODYSSEY_REV):
        raise ValueError("resume requires a finalized matching model, deadline and catalog")
    rows = json.loads((folder / "results.json").read_text())
    catalog = {(t["suite"], t["task_id"]) for t in tasks}
    identities = {(r["suite"], r["task_id"]) for r in rows}
    if len(identities) != len(rows) or not identities <= catalog:
        raise ValueError("invalid resume task identities")
    selected = metadata.get("selected_task_ids")
    if selected is None:
        if identities != catalog or metadata["expected"] != len(catalog):
            raise ValueError("legacy resume requires an exact full catalog result set")
        selected = [t["task_id"] for t in tasks]
    if len(set(selected)) != len(selected) or len(selected) != metadata["expected"]:
        raise ValueError("invalid original selection")
    tasks = [t for t in tasks if t["task_id"] in set(selected)]
    if len(tasks) != len(selected) or not identities <= {(t["suite"], t["task_id"]) for t in tasks}:
        raise ValueError("resume results disagree with selection")
    for filename, digest in metadata["hashes"].items():
        path = folder / "inputs" / filename
        if filename == ".build/debug/Search":
            path = folder / "inputs/SearchBroad.app/MacOS/SearchBroad"
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError("frozen input hash mismatch: " + filename)
    for name in ["harness.js", "drive.js"]:
        path = folder / "inputs/SearchBroad.app/Resources/ask" / name
        if hashlib.sha256(path.read_bytes()).hexdigest() != metadata["hashes"]["Runtime/ask/" + name]:
            raise ValueError("frozen bundled runtime mismatch")
    valid = []
    for row in rows:
        if "score" not in row:
            continue
        score = row["score"]
        directory = folder / row["suite"] / row["task_id"]
        trace = json.loads((directory / "trace.json").read_text())
        judge = json.loads((directory / "judge.json").read_text())
        if (type(score) not in (int, float) or not math.isfinite(score) or not 0 <= score <= 1
                or float((directory / "result.txt").read_text()) != score
                or (trace.get("suite"), trace.get("task_id")) != (row["suite"], row["task_id"])
                or trace.get("id") != row.get("chat") or not judge.get("id")):
            raise ValueError("invalid preserved score: " + row["task_id"])
        valid.append(row)
    return metadata, tasks, valid


def clone(source, target):
    # ponytail: macOS copy-on-write keeps screenshot recovery within local disk capacity.
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", "-cR", str(source), str(target)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--completion-reserve", type=int, default=90, help="one executor reminder before hard deadline; recovery retains the original policy")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--limit", type=int, default=0, help="tasks per suite for a partial pilot, zero runs all 300")
    selection.add_argument("--task-id", action="append", default=[], help="repeat to rerun exact catalog task IDs")
    selection.add_argument("--resume", type=Path, help="recover ungraded cases using the original frozen app")
    parser.add_argument("--reuse", help="connect to a root-controlled broad-profile test world")
    args = parser.parse_args()
    if not (1 <= args.workers <= 12 and args.timeout > 0 and args.limit >= 0 and args.completion_reserve >= 0):
        parser.error("workers must be 1 to 12, timeout positive, and limit/reserve nonnegative")
    if args.resume and args.reuse:
        parser.error("resume owns a fresh world and cannot use --reuse")
    cache = REPO / ".build/broad-data"
    tasks = catalogs(cache)
    if args.task_id:
        requested = set(args.task_id)
        tasks = [task for task in tasks if task["task_id"] in requested]
        if {task["task_id"] for task in tasks} != requested:
            parser.error("unknown catalog task ID")
    if args.limit:
        # Deterministic coverage across categories and task difficulty.
        selected = []
        for suite in ["bu-v1", "odysseys"]:
            groups = collections.defaultdict(list)
            for task in tasks:
                if task["suite"] == suite:
                    groups[task.get("category", task.get("level", ""))].append(task)
            while len([t for t in selected if t["suite"] == suite]) < args.limit and any(groups.values()):
                for group in groups.values():
                    if group and len([t for t in selected if t["suite"] == suite]) < args.limit:
                        selected.append(group.pop(0))
        tasks = selected
    reserve = 0 if args.resume else min(args.completion_reserve, args.timeout // 2)
    original = None
    results = []
    if args.resume:
        args.resume = args.resume.resolve()
        original, tasks, results = resume_inputs(args.resume, tasks, args.timeout)
        reserve = original.get("completion_reserve", 0)
    selected_tasks = tasks
    completed = {(r["suite"], r["task_id"]) for r in results}
    tasks = [t for t in tasks if (t["suite"], t["task_id"]) not in completed]
    if not tasks:
        parser.error("selection has no ungraded tasks")
    world = args.reuse or f"broad-{uuid.uuid4().hex[:8]}"
    output = HERE / "results" / f"{world}-{int(time.time())}"
    output.mkdir(parents=True)
    output.chmod(0o700)
    app = auth = log = agent = None
    metadata = {"world": world, "model": "codex/gpt-6-luna", "effort": "xhigh", "workers": args.workers,
                "timeout": args.timeout, "completion_reserve": reserve, "selected_task_ids": [task["task_id"] for task in selected_tasks], "expected": len(selected_tasks), "catalog_total": 300, "complete": False,
                "native_action_timeout": 30, "evidence_capture_timeout": 8,
                "hash_scope": "local inputs; reuse caller verifies running app" if args.reuse else "launched app and source inputs",
                "storage": "per-seat ephemeral website data store; default tabs in a seat share its store",
                "execution_constraints": "Agent instructions prohibit sign-in, account creation, purchases, publishing, and contacting others. Native gates restrict uploads to run-owned generated samples on browser-use.github.io synthetic stress-test forms and block file navigation and arbitrary screenshot paths. Missing required deliverables receive zero rubric credit.",
                "bu_revision": BU_REV, "odyssey_revision": ODYSSEY_REV, "judge": "adapted Luna xhigh; not official leaderboard judging"}
    if original:
        metadata = {**original, **{k: metadata[k] for k in ["world", "workers", "selected_task_ids", "expected", "complete"]}}
        metadata.pop("infrastructure_error", None)
        metadata.pop("seconds", None)
        metadata["selected_complete"] = False
        metadata["resume_controller_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        metadata["fragments"] = original.get("fragments", [{**{k: original.get(k) for k in
            ["world", "workers", "timeout", "seconds", "hashes", "infrastructure_error"]},
            "source": str(args.resume), "graded": len(results), "attempts": len(json.loads((args.resume / "results.json").read_text()))}]) + [
            {"world": world, "workers": args.workers, "timeout": args.timeout,
             "task_ids": [t["task_id"] for t in tasks], "resume_from": str(args.resume)}]
        clone(args.resume / "inputs", output / "inputs")
        controller = output / "inputs/recovery" / (world + ".py")
        controller.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(Path(__file__), controller)
        clone(args.resume / "harness.audit.jsonl", output / "prior.audit.jsonl")
        for row in results:
            clone(args.resume / row["suite"] / row["task_id"], output / row["suite"] / row["task_id"])
        (output / "results.json").write_text(json.dumps(results, indent=2))
    else:
        metadata["hashes"] = {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
                              [Path(__file__), REPO / "Runtime/ask/harness.js", REPO / "Runtime/ask/drive.js", REPO / ".build/debug/Search",
                               *[REPO / "Sources/Search" / name for name in ["BenchmarkRuns.swift", "Harness.swift", "Drive.swift", "Browser.swift", "Bench.swift", "AgentInteractions.swift"]]]}
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2))
        for filename in metadata["hashes"]:
            if filename == ".build/debug/Search": continue
            target = output / "inputs" / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / filename, target)
            assert hashlib.sha256(target.read_bytes()).hexdigest() == metadata["hashes"][filename]
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2))
    started = time.monotonic()
    try:
        if not args.reuse:
            source = REPO / ".build/debug/Search"
            target = REPO / ".build/broad/SearchBroad.app/Contents/MacOS/SearchBroad"
            mini.close_previous_debug(source)
            mini.close_previous_debug(target)
            if original:
                target = output / "launch/SearchBroad.app/Contents/MacOS/SearchBroad"
                clone(output / "inputs/SearchBroad.app", target.parent.parent)
                binary = target
            else:
                binary = mini.bundle_debug(source, target)
                import plistlib
                plist = binary.parent.parent / "Info.plist"
                info = plistlib.loads(plist.read_bytes())
                info["CFBundleIdentifier"] = "com.officecommun.search.broadbenchmark"
                plist.write_bytes(plistlib.dumps(info))
                shutil.copytree(binary.parents[1], output / "inputs/SearchBroad.app")
                assert hashlib.sha256(binary.read_bytes()).hexdigest() == metadata["hashes"][".build/debug/Search"]
            if hashlib.sha256(binary.read_bytes()).hexdigest() != metadata["hashes"][".build/debug/Search"]:
                raise ValueError("launched executable differs from frozen input")
            bench.wipe_world(world, bench.webkit_container(binary))
            suite = bench.suite_for(world)
            bench.stage_defaults(suite, "codex", "gpt-6-luna")
            bench.defaults_write(suite, "ask.maxRounds", "-int", "100")
            auth = mini.stage_codex(world)
            log = open(output / "app.log", "ab", buffering=0)
            app = subprocess.Popen([str(binary)], env={**os.environ, "SEARCH_PROBE": world, "SEARCH_BENCHMARK": "broad"},
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        agent = bench.wait_for_agent(world, timeout=60)
        ready_pages(world)
        native_checks = {}
        for check in (["check-host", "check-storage", "check-queue"] if original else
                      ["check-host", "check-storage", "check-queue", "check-js-dialogs", "check-fixtures", "check-steer"]):
            checked = call(world, do="agent-run", action=check)
            native_checks[check] = checked
            (output / "preflight.json").write_text(json.dumps(native_checks, indent=2))
            if not checked.get("ok"):
                raise RuntimeError(check + " failed: " + json.dumps(checked))
        # Concurrent preflight proves separate chats, identical inference and clean release.
        preflights = []
        try:
            for _ in range(min(4, args.workers)):
                preflights.append(call(world, do="agent-run", action="start", prompt="Reply with exactly READY"))
            assert len({row["id"] for row in preflights}) == len(preflights)
            for row in preflights:
                assert not wait(world, row["id"], 90)
                trace = call(world, do="agent-run", action="status", id=row["id"], detail=True)
                assert not trace.get("error") and answer(trace).strip().rstrip(".") == "READY", "preflight failed"
        finally:
            for row in preflights:
                release(world, row["id"])
        print(f"RUN {world} tasks={len(tasks)} workers={args.workers} output={output}", flush=True)
        def execute(task):
            trace = run_task(world, task, output, args.timeout, reserve)
            return grade(world, task, trace, output, cache)
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = {pool.submit(execute, task): task for task in tasks}
            failures = []
            for future in concurrent.futures.as_completed(futures):
                if future.cancelled():
                    task = futures[future]
                    results.append({"task_id": task["task_id"], "suite": task["suite"], "cancelled": True, "reason": "batch aborted after infrastructure failure"})
                    (output / "results.json").write_text(json.dumps(results, indent=2))
                    continue
                try:
                    result = future.result()
                    print(f"{len(results) + 1}/{len(selected_tasks)} {result['suite']} {result['task_id']} score={result['score']:.2f} seconds={result['seconds']:.1f} tools={result['tools']}", flush=True)
                except Exception as exc:
                    task = futures[future]
                    result = {"task_id": task["task_id"], "suite": task["suite"], "infrastructure_error": f"{type(exc).__name__}: {exc}"}
                    failures.append(result)
                    for pending in futures:
                        pending.cancel()
                results.append(result)
                (output / "results.json").write_text(json.dumps(results, indent=2))
            if failures:
                raise RuntimeError(f"{len(failures)} infrastructure failures; completed outcomes preserved")
        metadata["selected_complete"] = (len(results) == len(selected_tasks) and
            {(r["suite"], r["task_id"]) for r in results if "score" in r} ==
            {(t["suite"], t["task_id"]) for t in selected_tasks})
        metadata["complete"] = metadata["selected_complete"] and len(selected_tasks) == 300
    except BaseException as exc:
        metadata["infrastructure_error"] = f"{type(exc).__name__}: {exc}"
        raise
    finally:
        metadata["seconds"] = time.monotonic() - started
        audit = Path(mini.world_folder(world)) / "harness.audit.jsonl"
        if audit.exists():
            shutil.copy2(audit, output / "fragment.audit.jsonl")
        with (output / "harness.audit.jsonl").open("wb") as combined:
            for fragment in [output / "prior.audit.jsonl", output / "fragment.audit.jsonl"]:
                if fragment.exists():
                    with fragment.open("rb") as source:
                        shutil.copyfileobj(source, combined)
        if original:
            metadata["fragments"][-1].update(seconds=metadata["seconds"], infrastructure_error=metadata.get("infrastructure_error"),
                attempts=sum(r["task_id"] in metadata["fragments"][-1]["task_ids"] for r in results),
                graded=sum(r["task_id"] in metadata["fragments"][-1]["task_ids"] and "score" in r for r in results))
        if agent:
            agent.close()
        if app:
            mini.stop_process(app)
        if auth:
            auth.unlink(missing_ok=True)
        if log:
            log.close()
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2))
    print("DONE", output, flush=True)


if __name__ == "__main__":
    main()
