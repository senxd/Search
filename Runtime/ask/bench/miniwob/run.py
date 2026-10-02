#!/usr/bin/env python3
"""Run the pinned BrowserGym MiniWoB++ catalog through Search Ask."""

import argparse
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone

HERE = pathlib.Path(__file__).resolve().parent
BENCH_DIR = HERE.parent
REPO = HERE.parents[3]
sys.path.insert(0, str(BENCH_DIR))
import run as bench  # noqa: E402

from search_agent import Agent, AgentError, SocketGone, world_folder  # noqa: E402

TASKS_FILE = HERE / "tasks.json"
MINIWOB_REPO = "https://github.com/Farama-Foundation/miniwob-plusplus.git"
MINIWOB_COMMIT = "7fd85d71a4b60325c6585396ec4f48377d049838"
CATALOG_COMMIT = "c05d7f38f4f788d6e4ee960512c3d5c8aabc6e42"
CATALOG_SHA256 = "70107a629ac8f714e9fbde7c9007ae1bbfc2f5eae081e6bc22a11bbf2fa59abc"
MODEL = "codex/gpt-6-luna"
EFFORT = "xhigh"
EPISODE_MS = 1_000_000
MAX_ROUNDS = 100
VIEWPORT = {"width": 332, "height": 214}
DEFAULT_TIMEOUT = 180
STATUS_INTERVAL = 0.5
ASK_TIMEOUT = 20
BENCH_BINARY = pathlib.Path.home() / 'Library/Caches/SearchBenchmark/SearchBenchmark.app/Contents/MacOS/SearchBenchmark'
LEGACY_BENCH_BINARY = REPO / '.build/miniwob/SearchBenchmark.app/Contents/MacOS/SearchBenchmark'
BENCH_BUNDLE_ID = 'com.officecommun.search.benchmark'


class RunError(RuntimeError):
    pass


def catalog():
    raw = TASKS_FILE.read_bytes()
    if hashlib.sha256(raw).hexdigest() != CATALOG_SHA256:
        raise RunError("tasks.json does not match its pinned SHA-256")
    data = json.loads(raw)
    if (data.get("browsergym_commit") != CATALOG_COMMIT
            or data.get("miniwob_commit") != MINIWOB_COMMIT
            or data.get("task_count") != 125
            or len(data.get("tasks", [])) != 125):
        raise RunError("tasks.json does not match the pinned 125-task catalog")
    ids = [task.get("id") for task in data["tasks"]]
    if len(set(ids)) != 125:
        raise RunError("tasks.json contains duplicate task IDs")
    return data["tasks"]


def effective_world(value=None):
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    candidate = value or f"miniwob-{stamp}-{uuid.uuid4().hex[:6]}"
    world = bench.sanitize_world(candidate)
    if not world or world == "test":
        raise RunError("world must be a unique non-test name")
    return world


def codex_credential():
    """Return one serialized Codex credential without printing or logging it."""
    prod_keys = pathlib.Path.home() / "Library/Application Support/Search/ask.keys.json"
    try:
        keys = json.loads(prod_keys.read_text(encoding="utf-8"))
        raw = keys.get("codex") if isinstance(keys, dict) else None
        parsed = json.loads(raw) if isinstance(raw, str) else None
        tokens = parsed.get("tokens", parsed) if isinstance(parsed, dict) else {}
        if isinstance(tokens, dict) and tokens.get("access_token"):
            return raw
    except (OSError, ValueError, TypeError):
        pass

    auth_path = pathlib.Path.home() / ".codex/auth.json"
    try:
        value = json.loads(auth_path.read_text(encoding="utf-8"))
        tokens = value.get("tokens", value) if isinstance(value, dict) else {}
        if isinstance(tokens, dict) and tokens.get("access_token"):
            return json.dumps(value, separators=(",", ":"))
    except (OSError, ValueError, TypeError):
        pass
    raise RunError("no valid Codex credential in Search keys or ~/.codex/auth.json")


def stage_codex(world):
    folder = pathlib.Path(world_folder(world))
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "ask.keys.json"
    payload = json.dumps({"codex": codex_credential()})
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(path, flags, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as target:
            target.write(payload)
    except Exception:
        path.unlink(missing_ok=True)
        raise
    if path.stat().st_mode & 0o777 != 0o600:
        raise RunError("staged credential file is not mode 0600")
    return path


def close_previous_debug(binary):
    """Stop only this repo's debug binary and dedicated benchmark copy."""
    owned_binaries = {binary.resolve(), BENCH_BINARY.resolve(), LEGACY_BENCH_BINARY.resolve(), LEGACY_BENCH_BINARY.with_name('Search').resolve()}
    result = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True,
                            text=True, check=True)
    pids = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        command = parts[1].split(None, 1)[0]
        if pathlib.Path(command).name not in {path.name for path in owned_binaries} or pid == os.getpid():
            continue
        # ps may retain a relative argv[0]. Verify the mapped executable
        # rather than guessing its working directory or matching by name.
        mapped = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"],
                                capture_output=True, text=True)
        if any(line.startswith("n") and pathlib.Path(line[1:]).resolve() in owned_binaries
               for line in mapped.stdout.splitlines()):
            pids.append(pid)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 8
    while pids and time.monotonic() < deadline:
        pids = [pid for pid in pids if subprocess.run(
            ["kill", "-0", str(pid)], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL).returncode == 0]
        time.sleep(0.2)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def clone_miniwob(target):
    subprocess.run(["git", "clone", "--quiet", "--no-checkout", MINIWOB_REPO,
                    str(target)], check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    subprocess.run(["git", "-C", str(target), "checkout", "--quiet", "--detach",
                    MINIWOB_COMMIT], check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    revision = subprocess.run(["git", "-C", str(target), "rev-parse", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
    if revision != MINIWOB_COMMIT:
        raise RunError("MiniWoB clone did not resolve to its pinned commit")
    root = target / "miniwob" / "html"
    for task in catalog():
        if not (root / "miniwob" / f"{task['subdomain']}.html").is_file():
            raise RunError(f"pinned MiniWoB page missing for {task['id']}")
    return root


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start_server(root, port):
    proc = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1",
         "--directory", str(root)], stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RunError("MiniWoB local server exited during startup")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                return proc
        except OSError:
            time.sleep(0.2)
    proc.terminate()
    raise RunError("MiniWoB local server did not answer on loopback")


def stop_process(proc):
    if not proc or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def bundle_debug(binary, target=BENCH_BINARY):
    """Give the isolated copy its own macOS app and WebKit identity."""
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, target)
    with (target.parent.parent / 'Info.plist').open('wb') as file:
        plistlib.dump({'CFBundleIdentifier': BENCH_BUNDLE_ID,
                      'CFBundleName': 'Search Benchmark',
                      'CFBundleDisplayName': 'Search Benchmark',
                      'CFBundleExecutable': target.name,
                      'CFBundlePackageType': 'APPL',
                      'CFBundleVersion': '1',
                      'NSHighResolutionCapable': True}, file)
    runtime = target.parent.parent / 'Resources/ask'
    runtime.mkdir(parents=True, exist_ok=True)
    for name in ('harness.js', 'drive.js'):
        shutil.copy2(REPO / 'Runtime/ask' / name, runtime / name)
    shutil.copytree(REPO / 'Runtime/ask/skills', runtime / 'skills', dirs_exist_ok=True)
    return target


def launch_debug(binary, world, log):
    env = dict(os.environ)
    env["SEARCH_PROBE"] = world
    env["SEARCH_BENCHMARK"] = "miniwob"
    return subprocess.Popen([str(binary)], env=env, stdout=log,
                            stderr=subprocess.STDOUT, start_new_session=True)


def status(agent):
    reply = agent.call("ui.ask", status=True, timeout=ASK_TIMEOUT)
    value = reply.get("status", reply)
    if not isinstance(value, dict) or not isinstance(value.get("running"), bool):
        raise RunError("ui.ask status returned an unsupported response")
    return value


def check_model_status(value):
    model = value.get("model")
    effort = value.get("effort")
    if model:
        if model not in (MODEL, "gpt-6-luna"):
            raise RunError("Ask status reports a different model than requested")
    if effort and effort != EFFORT:
        raise RunError("Ask status reports a different effort than requested")


def wait_status(agent, chat_id, deadline, tab=None):
    while time.monotonic() < deadline:
        value = status(agent)
        if value.get("chat") != chat_id:
            raise RunError("Ask status belongs to a different chat")
        if value.get("waiting"):
            raise RunError("Ask is waiting for user input during a benchmark task")
        check_model_status(value)
        terminal = (bench.bench_eval(agent.world, tab,
                                     "WOB_DONE_GLOBAL === true")[1]
                    if tab else False)
        if terminal:
            agent.call("ui.ask", stop=True, timeout=ASK_TIMEOUT)
            stop_deadline = time.monotonic() + 12
            while time.monotonic() < stop_deadline:
                value = status(agent)
                if value.get("chat") != chat_id:
                    raise RunError("Ask status belongs to a different chat")
                if not value.get("running"):
                    return True, value
                time.sleep(0.2)
            raise RunError("Ask did not stop after MiniWoB reached terminal state")
        if not value["running"]:
            return False, value
        time.sleep(STATUS_INTERVAL)
    return None, status(agent)


def eval_value(world, tab, js):
    output = bench.bench_cli(world, ["eval", tab, js], timeout=20).stdout.strip()
    try:
        return json.loads(output)
    except ValueError:
        return output


def ready(world, tab, timeout=30):
    bench.bench_cli(world, ["wait", tab, "20"], timeout=30)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ok = bench.bench_eval(world, tab,
                              "typeof core !== 'undefined' && WOB_TASK_READY === true")[1]
        if ok:
            return
        time.sleep(0.25)
    raise RunError("MiniWoB page never reached WOB_TASK_READY")


GOAL_ADAPTER = r"""
(() => {
  const q = document.getElementById('query');
  if (!q) throw new Error('MiniWoB task has no query element');
  const ids = ['reward-display', 'click-canvas', 'sync-task-cover'];
  const nodes = {};
  let queryHTML = q.innerHTML;
  const hide = () => {
    queryHTML = q.innerHTML;
    q.innerHTML = '';
    core.clearTimer();
    document.body.removeEventListener('click', core.canvasDrawClick);
    for (const id of ids) {
      const node = document.getElementById(id) || nodes[id];
      if (node) { nodes[id] = node; node.remove(); }
    }
  };
  const restore = () => {
    q.innerHTML = queryHTML;
    for (const id of ids) if (nodes[id]) document.body.appendChild(nodes[id]);
    core.createDisplay();
  };
  const visible = fn => { restore(); try { return fn(); } finally { hide(); } };
  const oldStart = core.startEpisodeReal;
  const oldEnd = core.endEpisode;
  const oldGoal = core.getUtterance;
  core.startEpisodeReal = function () { return visible(() => oldStart.apply(this, arguments)); };
  core.endEpisode = function () { return visible(() => oldEnd.apply(this, arguments)); };
  const goal = () => visible(() => {
    const task = __SUBDOMAIN__;
    if (task === 'click-menu-2') {
      const el = document.getElementById('query');
      if (el.children.length) return `${el.childNodes[0].textContent.replace(/\s+/g, ' ').trim()} "${el.children[0].getAttribute('class').split(' ')[1]}" ${el.childNodes[2].textContent.replace(/\s+/g, ' ').trim()}`;
    }
    if (task === 'use-colorwheel-2') {
      const el = document.getElementById('query');
      const rgb = el.children[1].style.backgroundColor;
      const hex = `#${rgb.match(/^rgb\((\d+),\s*(\d+),\s*(\d+)\)$/).slice(1).map(n => parseInt(n, 10).toString(16).padStart(2, '0')).join('')}`;
      return `${el.children[0].textContent.replace(/\s+/g, ' ').trim()} ${hex} ${el.children[2].textContent.replace(/\s+/g, ' ').trim()}`;
    }
    const value = oldGoal.call(core);
    return value && typeof value === 'object' ? value.utterance : value;
  });
  core.getUtterance = goal;
  hide();
  Math.seedrandom(0);
  core.EPISODE_MAX_TIME = __EPISODE_MS__;
  core.startEpisodeReal();
  return JSON.stringify(goal());
})()
"""


def reset_episode(world, tab, subdomain):
    js = GOAL_ADAPTER.replace("__SUBDOMAIN__", json.dumps(subdomain)).replace(
        "__EPISODE_MS__", str(EPISODE_MS))
    goal = eval_value(world, tab, js)
    if not isinstance(goal, str) or not goal.strip():
        raise RunError("MiniWoB returned an empty or invalid task instruction")
    return goal.strip()


def score_episode(done, raw_reward):
    return int(done is True and isinstance(raw_reward, (int, float)) and raw_reward > 0)


def chat_file(world, chat_id):
    return pathlib.Path(world_folder(world)) / "chats" / f"{chat_id}.json"


def chat_notes(chat):
    return [m.get("text", "") for m in chat.get("messages", [])
            if m.get("role") == "note" and m.get("isError") is True]


def chat_tool_counts(chat):
    return bench.tool_counts(chat)


def tool_failure_counts(chat):
    counts = {}
    for card in bench.tool_cards(chat):
        if card.get("failed"):
            name = card.get("name", "unknown")
            counts[name] = counts.get(name, 0) + 1
    return counts


def audit_metrics(world, chat_id):
    path = pathlib.Path(world_folder(world)) / "harness.audit.jsonl"
    records = []
    try:
        with path.open(encoding="utf-8") as source:
            for line in source:
                try:
                    record = json.loads(line)
                except ValueError as exc:
                    raise RunError("Ask benchmark audit contains malformed JSON") from exc
                if record.get("chat") == chat_id:
                    records.append(record)
    except OSError as exc:
        raise RunError("Ask benchmark audit is unavailable") from exc
    requests = [record for record in records if record.get("kind") == "request"]
    rounds = [record for record in records if record.get("kind") == "round"]
    done = [record for record in records if record.get("kind") == "done"]
    rejected = [record for record in records if record.get("kind") in ("retry", "rejection")]
    if not requests:
        raise RunError("Ask audit has no request record for a benchmark chat")
    if len(rounds) > len(requests):
        raise RunError("Ask audit has more response rounds than provider requests")
    if len(rounds) + len(rejected) > len(requests):
        raise RunError("Ask audit has more responses/rejections than provider requests")
    if any(record.get("provider") != "codex"
           or record.get("model") != "gpt-6-luna"
           or record.get("effort") != EFFORT for record in requests):
        raise RunError("Ask audit does not match codex/gpt-6-luna xhigh")
    usage = {"input_tokens": 0, "cached_tokens": 0,
             "output_tokens": 0, "reasoning_tokens": 0}
    calls = 0
    for record in rounds:
        value = record.get("usage") or {}
        if isinstance(value, dict):
            usage["input_tokens"] += int(value.get("input_tokens") or 0)
            usage["cached_tokens"] += int((value.get("input_tokens_details") or {}).get("cached_tokens") or 0)
            usage["output_tokens"] += int(value.get("output_tokens") or 0)
            usage["reasoning_tokens"] += int((value.get("output_tokens_details") or {}).get("reasoning_tokens") or 0)
        tool_calls = record.get("toolCalls") or 0
        calls += len(tool_calls) if isinstance(tool_calls, list) else int(tool_calls)
    return {"requests": len(requests), "rounds": len(rounds),
            "completed_turns": len(done),
            "failed_turns": sum(record.get("failed") is True for record in done),
            "failure_categories": [record.get("failure") for record in done],
            "provider_retries": sum(int(record.get('retry') or 0) > 0 for record in requests),
            "rejected_requests": len(rejected),
            "pending_requests": len(requests) - len(rejected) - len(rounds),
            "tool_calls": calls, **usage}


def validate_audit_turn(metrics, cancelled=False):
    if metrics["completed_turns"] != 1:
        raise RunError("Ask audit does not show exactly one completed turn")
    pending = metrics["pending_requests"]
    if pending < 0 or (cancelled and pending > 1) or (not cancelled and pending != 0):
        raise RunError("Ask audit has an unexpected number of unfinished provider requests")
    metrics["cancelled_requests"] = pending if cancelled else 0
    return metrics


def audit_after_turn(world, chat_id, cancelled=False):
    deadline = time.monotonic() + 3
    metrics = audit_metrics(world, chat_id)
    while metrics["completed_turns"] == 0 and time.monotonic() < deadline:
        time.sleep(0.2)
        metrics = audit_metrics(world, chat_id)
    return validate_audit_turn(metrics, cancelled)


def assert_browser_profile(chat):
    if chat.get("mode") != "full":
        raise RunError("benchmarks require Full mode without action confirmation")
    forbidden = {"page.eval", "page.code", "ask.user", "eval", "run_code",
                 "inspector_attach", "inspector_send", "inspector_events",
                 "inspector_detach"}
    tools = set(chat_tool_counts(chat))
    if tools & forbidden or any(name.startswith("inspector.") for name in tools):
        raise RunError("browser benchmark profile exposed a forbidden tool")


def infra_note(chat):
    return any(not re.fullmatch(r"reached the \d+-step limit", note.strip(), re.I)
               for note in chat_notes(chat))


def max_round_failure(chat):
    return any(re.fullmatch(r"reached the \d+-step limit", note.strip(), re.I)
               for note in chat_notes(chat))


def snapshot_row(rows, output, metadata, complete=False, error=None):
    public_fields = {"id", "seed", "status", "score", "done", "raw_reward",
                     "reward", "seconds", "rounds", "usage", "tool_counts",
                     "action_failures", "chat", "model", "effort", "viewport",
                     "screenshot", "screenshot_pixels", "screenshot_scale"}
    by_id = {result["id"]: {key: value for key, value in result.items()
                            if key in public_fields} for result in rows}
    selected = set(metadata["selected_ids"])
    expanded = []
    for task in catalog():
        if task["id"] in by_id:
            expanded.append(by_id[task["id"]])
        else:
            expanded.append({"id": task["id"], "seed": 0,
                             "status": "uncompleted" if task["id"] in selected else "not_selected",
                             "score": None, "reason": "not run"})
    data = {"metadata": metadata, "complete": complete, "infra_error": error,
            "scored": sum(r.get("score") is not None for r in rows), "results": expanded}
    path = output / "results.json"
    temp = path.with_suffix(".json.tmp")
    temp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")
    temp.replace(path)
    successes = sum(r.get("score") == 1 for r in rows)
    failures = sum(r.get("score") == 0 for r in rows)
    lines = ["# Search Ask MiniWoB++ baseline", "",
             f"- Complete: {'yes' if complete else 'no'}",
             f"- Model: `{MODEL}` at `{EFFORT}`",
             f"- Tasks scored: {data['scored']} / {metadata['selected_count']}",
             f"- Successes: {successes}", f"- Failures or timeouts: {failures}",
             f"- Score: {successes / data['scored']:.4f}" if data['scored'] else "- Score: pending",
             f"- Infrastructure error: {error or 'none'}", "", "| Task | Seed | Status | Score | Seconds | Rounds | Action failures | Chat |", "|---|---:|---|---:|---:|---:|---|---|"]
    for result in expanded:
        score = "" if result.get("score") is None else str(result["score"])
        failures_by_tool = result.get("action_failures") or {}
        failures_text = ", ".join(f"{name}:{count}" for name, count in sorted(failures_by_tool.items()))
        lines.append(f"| `{result['id']}` | {result['seed']} | {result['status']} | {score} | {result.get('seconds', 0):.1f} | {result.get('rounds', 0)} | {failures_text} | `{result.get('chat') or ''}` |")
    (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_task(task, agent, world, url, output, timeout):
    if not agent.call("ui.ask", new=True, timeout=ASK_TIMEOUT).get("newChat"):
        raise RunError("this Search build does not support per-task chat isolation")
    opened = bench.bench_cli(world, ["open", url], timeout=30).stdout.strip()
    if not opened:
        raise RunError("bench open returned no tab id")
    tab = opened.splitlines()[-1].strip()
    started = time.monotonic()
    try:
        ready(world, tab)
        viewport = eval_value(world, tab,
                              "({width:window.innerWidth,height:window.innerHeight})")
        if viewport != VIEWPORT:
            raise RunError("MiniWoB page did not receive the official 332x214 viewport")
        goal = reset_episode(world, tab, task["subdomain"])
        if not bench.bench_eval(world, tab, "WOB_DONE_GLOBAL === false")[1]:
            raise RunError("MiniWoB did not begin from an active episode")
        sent = agent.call("ui.ask", send=f"{goal}\n\nUse Search tab {tab} to complete the task.", timeout=ASK_TIMEOUT)
        chat_id = sent.get("chat")
        if not chat_id:
            raise RunError("ui.ask send returned no chat id")
        deadline = time.monotonic() + timeout
        terminal, current = wait_status(agent, chat_id, deadline, tab)
        timed_out = terminal is None
        if timed_out:
            bench.bench_eval(world, tab, "WOB_DONE_GLOBAL === true")
            agent.call("ui.ask", stop=True, timeout=ASK_TIMEOUT)
            stop_deadline = time.monotonic() + 12
            stopped = False
            while time.monotonic() < stop_deadline:
                current = status(agent)
                if current.get("chat") != chat_id:
                    raise RunError("Ask status belongs to a different chat")
                check_model_status(current)
                if not current.get("running"):
                    stopped = True
                    break
                time.sleep(0.2)
            if not stopped:
                raise RunError("Ask did not stop after the per-task timeout")
        path = chat_file(world, chat_id)
        _, _, chat = bench.wait_turn(str(path), 6, until="reply")
        if not chat:
            raise RunError("Ask chat did not persist after the turn stopped")
        assert_browser_profile(chat)
        action_failures = tool_failure_counts(chat)
        if infra_note(chat):
            raise RunError("provider or service error recorded in Ask chat")
        counts = chat_tool_counts(chat)
        metrics = audit_after_turn(world, chat_id,
                                   cancelled=(terminal is True or timed_out))
        if any(category == "harness" for category in metrics["failure_categories"]):
            raise RunError("Ask harness reported a failed turn")
        if (metrics["failed_turns"] and
                (any(category not in ("limit", None)
                     for category in metrics["failure_categories"] if category != "none")
                 or not max_round_failure(chat))):
            raise RunError("Ask turn ended with an infrastructure error")
        done = bench.bench_eval(world, tab, "WOB_DONE_GLOBAL === true")[1]
        raw = eval_value(world, tab, "WOB_RAW_REWARD_GLOBAL")
        final_viewport = eval_value(world, tab,
                                    "({width:window.innerWidth,height:window.innerHeight})")
        if final_viewport != VIEWPORT:
            raise RunError("MiniWoB page viewport changed during the task")
        if timed_out:
            state, score = "timeout", 0
        elif score_episode(done, raw):
            state, score = "success", 1
        else:
            state, score = "failure", 0
        shot = output / "screenshots" / f"{task['subdomain']}.png"
        shot.parent.mkdir(parents=True, exist_ok=True)
        bench.bench_cli(world, ["shot", tab, str(shot)], timeout=25)
        header = shot.read_bytes()[:24]
        if header[:8] != b"\x89PNG\r\n\x1a\n":
            raise RunError("benchmark screenshot is not a PNG")
        image_width, image_height = struct.unpack(">II", header[16:24])
        status_model = current.get("model")
        return {"id": task["id"], "seed": 0, "status": state,
                "score": score, "done": done, "raw_reward": raw,
                "reward": eval_value(world, tab, "WOB_REWARD_GLOBAL"),
                "seconds": time.monotonic() - started, "rounds": metrics["rounds"],
                "usage": metrics, "tool_counts": counts, "chat": chat_id,
                "action_failures": action_failures,
                "model": status_model or MODEL, "effort": current.get("effort", EFFORT),
                "viewport": viewport, "screenshot": str(shot),
                "screenshot_pixels": {"width": image_width, "height": image_height},
                "screenshot_scale": image_width / viewport["width"]}
    finally:
        bench.bench_cli(world, ["close", tab], check=False, timeout=15)


def choose_tasks(tasks, selected):
    if not selected:
        return tasks
    wanted = {word.strip() for word in selected.split(",") if word.strip()}
    result = [task for task in tasks if task["id"] in wanted or task["subdomain"] in wanted]
    unknown = wanted - {task["id"] for task in result} - {task["subdomain"] for task in result}
    if unknown:
        raise RunError("unknown task ID or subdomain: " + ", ".join(sorted(unknown)))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-existing", metavar="WORLD",
                        help="use an already running benchmark-profile Search world; do not wipe, launch, stage keys, or stop it")
    parser.add_argument("--tasks", default="", help="comma-separated task IDs or subdomains (partial run)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help="per-task Ask wall-clock deadline in seconds")
    parser.add_argument("--port", type=int, default=0, help="loopback MiniWoB HTTP port, 0 selects a free port")
    args = parser.parse_args(argv)
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")

    all_tasks = catalog()
    tasks = choose_tasks(all_tasks, args.tasks)
    world = bench.sanitize_world(args.reuse_existing) if args.reuse_existing else effective_world()
    if args.reuse_existing and (not world or world == "test"):
        parser.error("--reuse-existing needs a non-test world name")
    run_id = f"{world}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    output = HERE / "results" / run_id
    output.mkdir(parents=True, exist_ok=False)
    metadata = {"run_id": run_id, "world": world, "runner_pid": os.getpid(), "model": MODEL,
                "effort": EFFORT, "seed": 0, "episode_ms": EPISODE_MS,
                "max_rounds": MAX_ROUNDS, "timeout_seconds": args.timeout,
                "viewport": VIEWPORT,
                "selected_count": len(tasks), "selected_ids": [task["id"] for task in tasks],
                "catalog_count": len(all_tasks),
                "browsergym_commit": CATALOG_COMMIT, "miniwob_commit": MINIWOB_COMMIT,
                "started": datetime.now(timezone.utc).isoformat(),
                "reuse_existing": bool(args.reuse_existing),
                "app": str(REPO / ".build/debug/Search"), "port": None}
    tracked_inputs = [REPO / ".build/debug/Search", REPO / "Runtime/ask/harness.js",
                      REPO / "Runtime/ask/drive.js", pathlib.Path(__file__).resolve()]
    tracked_inputs.extend(sorted((REPO / 'Runtime/ask/skills').rglob('SKILL.md')))
    metadata["input_sha256"] = {str(path.relative_to(REPO)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in tracked_inputs if path.is_file()}
    metadata["macos"] = platform.mac_ver()[0]
    rows = []
    error = None
    agent = None
    app = None
    app_log = None
    server = None
    temp = None
    staged_auth = None
    try:
        binary = REPO / ".build/debug/Search"
        if not args.reuse_existing:
            if not binary.is_file() or not os.access(binary, os.X_OK):
                raise RunError("build .build/debug/Search before running the benchmark")
            close_previous_debug(binary)
            binary = bundle_debug(binary)
            metadata['app'] = str(binary)
            metadata['source_sha256'] = dict(metadata['input_sha256'])
            runner_name = str(pathlib.Path(__file__).resolve().relative_to(REPO))
            metadata['input_sha256'] = {runner_name: metadata['source_sha256'][runner_name]}
            contents = binary.parent.parent
            bundled_inputs = [binary, contents / 'Info.plist', contents / 'Resources/ask/harness.js', contents / 'Resources/ask/drive.js']
            bundled_inputs.extend(sorted((contents / 'Resources/ask/skills').rglob('SKILL.md')))
            for path in bundled_inputs:
                metadata['input_sha256'][str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
            bench.wipe_world(world, bench.webkit_container(binary))
            suite = bench.suite_for(world)
            bench.stage_defaults(suite, "codex", "gpt-6-luna")
            bench.defaults_write(suite, "ask.effort", "-string", EFFORT)
            bench.defaults_write(suite, "ask.maxRounds", "-int", str(MAX_ROUNDS))
            staged_auth = stage_codex(world)
            app_log = open(output / "app.log", "ab", buffering=0)
            app = launch_debug(binary, world, app_log)
            metadata['app_pid'] = app.pid
        else:
            metadata["app"] = "reused"

        agent = bench.wait_for_agent(world, timeout=60)
        port = args.port or free_port()
        metadata["port"] = port
        temp = tempfile.TemporaryDirectory(prefix="search-miniwob-")
        root = clone_miniwob(pathlib.Path(temp.name) / "src")
        server = start_server(root, port)
        metadata["asset_url"] = f"{MINIWOB_REPO.removesuffix('.git')}/tree/{MINIWOB_COMMIT}/miniwob/html"
        print(f"[run] world={world} tasks={len(tasks)}/{len(all_tasks)} model={MODEL} effort={EFFORT}")
        agent.call("ui.ask", open=True, timeout=ASK_TIMEOUT)
        if not args.reuse_existing:
            offscreen = json.loads(bench.bench_cli(world, ["pages", "on"], timeout=20).stdout)
            if offscreen.get("pages") is not True:
                raise RunError("Search benchmark windows did not move off screen")
            metadata["offscreen_ui"] = True

        # One unscored request confirms the exact model; there is no fallback.
        if not agent.call("ui.ask", new=True, timeout=ASK_TIMEOUT).get("newChat"):
            raise RunError("this Search build does not support fresh chats")
        sent = agent.call("ui.ask", send="Reply with the single word READY", timeout=ASK_TIMEOUT)
        preflight_chat = sent.get("chat")
        if not preflight_chat:
            raise RunError("preflight send returned no chat id")
        terminal, preflight_status = wait_status(agent, preflight_chat,
                                                 time.monotonic() + 60)
        if terminal is None:
            agent.call("ui.ask", stop=True, timeout=ASK_TIMEOUT)
            raise RunError("Codex preflight timed out")
        prechat = bench.read_chat(chat_file(world, preflight_chat))
        if infra_note(prechat):
            raise RunError("Codex preflight failed")
        responses = bench.agent_texts(prechat)
        if not responses or responses[-1].strip().rstrip(".") != "READY":
            raise RunError("Codex preflight did not return READY")
        check_model_status(preflight_status)
        assert_browser_profile(prechat)
        preflight_metrics = audit_after_turn(world, preflight_chat)
        if preflight_metrics["failed_turns"]:
            raise RunError("Codex preflight turn failed")
        print("[preflight] codex/gpt-6-luna xhigh ready")

        for index, task in enumerate(tasks, 1):
            url = f"http://127.0.0.1:{port}/miniwob/{task['subdomain']}.html"
            row = run_task(task, agent, world, url, output, args.timeout)
            rows.append(row)
            print(f"[{index}/{len(tasks)}] {task['id']} {row['status']} score={row['score']} {row['seconds']:.1f}s")
            snapshot_row(rows, output, metadata)
    except KeyboardInterrupt:
        error = "interrupted"
        print("[run] interrupted; saved completed task rows")
    except (RunError, AgentError, SocketGone, OSError, subprocess.SubprocessError) as exc:
        error = str(exc) if isinstance(exc, RunError) else type(exc).__name__
        if isinstance(exc, SocketGone):
            metadata['socket_error'] = str(exc)
            metadata['app_exit_code_at_failure'] = app.poll() if app else None
        print(f"[infra] {error}")
    except Exception as exc:
        error = type(exc).__name__
        print(f"[infra] {error}")
    finally:
        if server:
            stop_process(server)
        if temp:
            temp.cleanup()
        if not args.reuse_existing:
            if agent:
                try:
                    bench.bench_cli(world, ["close", "all"], check=False, timeout=15)
                except Exception:
                    pass
            stop_process(app)
            if staged_auth:
                try:
                    staged_auth.unlink()
                except FileNotFoundError:
                    pass
        if agent:
            agent.close()
        if app_log:
            app_log.close()
        metadata["finished"] = datetime.now(timezone.utc).isoformat()
        if any(not (REPO / name).is_file() or hashlib.sha256((REPO / name).read_bytes()).hexdigest() != digest
               for name, digest in metadata["input_sha256"].items()):
            error = error or "benchmark inputs changed during the run"
        scored = {row["id"] for row in rows}
        expected = {task["id"] for task in all_tasks}
        complete = (error is None and len(tasks) == len(all_tasks)
                    and scored == expected
                    and all(row.get("score") is not None for row in rows))
        snapshot_row(rows, output, metadata, complete=complete, error=error)
        print(f"[run] results {output / 'results.json'}")
        print(f"[run] summary {output / 'summary.md'}")
    return 0 if error is None else 2


if __name__ == "__main__":
    sys.exit(main())
