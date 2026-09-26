#!/usr/bin/env python3
"""run.py — the Ask benchmark harness (design/benchmarks.md).

    python3 Runtime/ask/bench/run.py [--model openai/gpt-6-luna] [--suite form,ui]
        [--world NAME] [--reuse] [--app build/Search.app|.build/debug/Search]
        [--port 8877] [--keys PATH] [--timeout 90]

One fresh probe world per run (`bench-<ts>` or --world); each scenario is a
prompt posted through `ui.ask {send}` — the real composer path — with a
machine-checkable verify over bench.sock. Two doors, like the design says:

  * agent.sock via sdk/search_agent.py for ui.ask {open,new,send,steer,stop}
    and tabs.open — the runner's own session, whose tabs the in-app agent
    cannot drive;
  * bench.sock, driven by the ./bench script as a subprocess, for
    everything else: setup tabs, eval/tabs verification, winshot,
    close all. Verify reads the CLI's printed contract — `eval` prints
    {value}, `tabs` prints `⚗/● mark · id · title · url` — so the whole
    harness exercises the same door a shell script would.

Turns are tracked through the chat file, not the socket: `ui.ask send`
answers {open, ok, chat:<uuid>} and Mind persists
<world>/chats/<uuid>.json on send ([you]), on the final agent message, and
on done-with-error ([note]). A turn is over when the newest message role is
agent|note and the file's mtime has been quiet for QUIET seconds.

Never touches the real world: SEARCH_PROBE is always set (a run without it
would be the real browser), and the only thing read from the real world is
a copy of ask.keys.json. A bundle-less binary (`.build/debug/Search`) has
no bundle id, so WebKit files its site data in the shared
~/Library/WebKit/Search + ~/Library/HTTPStorages/Search* — the wipe
clears those too (basenames asserted `Search`/`Search.*` only).
"""

import argparse
import fnmatch
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent                     # Runtime/ask/bench
REPO = HERE.parents[2]                                     # repository root
sys.path.insert(0, str(REPO / "sdk"))

from search_agent import Agent, AgentError, SocketGone, world_folder  # noqa: E402

FIXTURES = HERE / "fixtures"
SCENARIOS = HERE / "scenarios"
SHOTS = HERE / "shots"
BENCH = REPO / "bench"

REAL_HOME = os.path.expanduser("~/Library/Application Support/Search")
REAL_KEYS = os.path.join(REAL_HOME, "ask.keys.json")
WEBKIT_DIR = os.path.expanduser("~/Library/WebKit")
HTTP_STORAGES = os.path.expanduser("~/Library/HTTPStorages")
WEBKIT_STORES = os.path.join(WEBKIT_DIR,
                             "com.officecommun.search/WebsiteDataStore")

QUIET = 1.5          # mtime quiet interval that ends a turn
SEND_TIMEOUT = 20    # ui.ask ops that should answer fast

# harness.js's PROVIDERS table — `images` feeds skipIf:noImages, the
# default model feeds --model <provider> shorthand and the codex fallback.
PROVIDERS = {
    "openrouter": {"images": True, "default": "z-ai/glm-5.3-flash"},
    "codex": {"images": True, "default": "gpt-6-luna"},
    "devin": {"images": False, "default": "devin"},
    "echo": {"images": False, "default": "echo"},
}

# Guardrails (design/benchmarks.md §Guardrails): a note matching the first
# buys one 20 s backoff + resend; the second decides the codex fallback.
RATE_LIMIT = re.compile(r"429|rate.?limit|5\d\d", re.IGNORECASE)
BAD_MODEL = re.compile(
    r"^openrouter (400|404)|no endpoints|not a valid model", re.IGNORECASE)


# ------------------------------------------------------------------ world

def sanitize_world(name):
    """Store.world's own rule — lowercase ascii [a-z0-9-], ""/"1" → test."""
    world = "".join(
        c for c in str(name).lower() if c.isascii() and (c.isalnum() or c == "-"))
    return "test" if world in ("", "1") else world


def suite_for(world):
    return ("com.officecommun.search.test" if world == "test"
            else f"com.officecommun.search.test.{world}")


def probe_store_uuid(world):
    """Store.probeStore(1) — FNV-1a/32 of the world name inside the fixed
    5E4C…-…-4000-8000-…0001 identifier (fresh.sh:23-35 byte-for-byte)."""
    h = 0
    if world != "test":
        h = 2166136261
        for byte in world.encode("utf-8"):
            h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
    return "5E4C%04X-%04X-4000-8000-000000000001" % (h >> 16, h & 0xFFFF)


def app_bundle_id(binary):
    """The CFBundleIdentifier the resolved binary runs with — the fact
    Store.ownContainer reads as Bundle.main.bundleIdentifier. Only an
    <X>.app/Contents/MacOS/<exe> beside an Info.plist has one; a bare
    .build/debug/Search has none."""
    contents = binary.parent.parent      # <X>.app/Contents for …/MacOS/<exe>
    info = contents / "Info.plist"
    if binary.parent.name != "MacOS" or contents.name != "Contents" \
            or not info.is_file():
        return None
    try:
        with open(info, "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except (OSError, ValueError):
        return None


def webkit_container(binary):
    """The name WKWebsiteDataStore.default() files under for this binary:
    its bundle id when it has one of its own, or its process name when it
    has no bundle — a bundle-less .build/debug/Search shares
    ~/Library/WebKit/Search + ~/Library/HTTPStorages/Search* across every
    world it ever runs, so wiping only the probe-uuid store leaves each
    probe's site data behind for the next. None for the real bundle id:
    a probe of it lands in the probe-uuid store instead."""
    bid = app_bundle_id(binary)
    if bid == "com.officecommun.search":
        return None
    return bid or binary.name


def wipe_shared_webkit(name):
    """~/Library/WebKit/<name> plus ~/Library/HTTPStorages/<name>{,.*} —
    the shared .default() container of a bundle-less or own-bundle test
    binary. Every basename removed must be exactly <name> or <name>.<rest>
    (Search.binarycookies & co) so nothing here can ever reach the real
    app's com.officecommun.search container."""
    assert name and name != "com.officecommun.search", \
        "refusing to touch the real app's WebKit container"
    assert "/" not in name, f"{name!r} is a basename, not a path"
    for base, pat in ((WEBKIT_DIR, name), (HTTP_STORAGES, name + "*")):
        for path in sorted(Path(base).glob(pat)):
            stem = path.name
            if stem != name and not stem.startswith(name + "."):
                continue                     # SearchExtra is not ours
            if "com.officecommun.search" in stem:
                continue                     # belt, on top of the assert
            try:
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()
            except OSError:
                pass
            if not path.exists():
                print(f"[world] wiped {path}")


def wipe_world(world, container=None):
    """The fresh.sh triad: app folder, defaults suite, WebKit store. A
    binary without the real bundle id (Store.ownContainer) never touches
    the probe-uuid store — its site data lands in the shared <container>
    stores, which go too."""
    folder = world_folder(world)
    assert folder != REAL_HOME, "refusing to wipe the real world"
    shutil.rmtree(folder, ignore_errors=True)
    subprocess.run(["defaults", "delete", suite_for(world)],
                   capture_output=True)
    shutil.rmtree(os.path.join(WEBKIT_STORES, probe_store_uuid(world)),
                  ignore_errors=True)
    print(f"[world] wiped {folder}")
    if container:
        wipe_shared_webkit(container)


def defaults_write(suite, key, *args):
    subprocess.run(["defaults", "write", suite, key, *args],
                   check=True, capture_output=True)


def stage_defaults(suite, provider, model):
    """bench+welcomed are the doc's two; ask.mode=full is required because a
    .guard chat parks every destructive/privileged op on an approval card
    nobody is there to answer (Drive.serve → Policy.check → parkApproval —
    'no timeout, a parked finish is first-class'). ask.model is the JSON
    AskModel as -data hex, read once at Mind init."""
    defaults_write(suite, "bench", "-bool", "true")
    defaults_write(suite, "welcomed", "-bool", "true")
    defaults_write(suite, "ask.mode", "-string", "full")
    write_model_default(suite, provider, model)


def write_model_default(suite, provider, model):
    blob = json.dumps({"provider": provider, "model": model},
                      separators=(",", ":")).encode()
    defaults_write(suite, "ask.model", "-data", blob.hex())


def stage_keys(world, keys_path):
    """Copy ask.keys.json into the world dir, chmod 600. The contents are
    never read — a missing source is fine for providers that need nothing."""
    src = keys_path or REAL_KEYS
    dst = os.path.join(world_folder(world), "ask.keys.json")
    if not os.path.exists(src):
        print(f"[keys] no {src} — continuing without (echo needs none)")
        return False
    if keys_path or not os.path.exists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
    os.chmod(dst, 0o600)
    print(f"[keys] staged {dst} (0600)")
    return True


# ------------------------------------------------------------------ model

def provider_for(model_arg):
    """harness.js providerFor(): 'provider/model' names both; a bare
    provider name takes its default; anything else is an openrouter id
    (slashes and all — 'openai/x' is model 'openai/x')."""
    ident = ((model_arg or "").strip()
             or "openrouter/" + PROVIDERS["openrouter"]["default"])
    if "/" not in ident:
        if ident in PROVIDERS:
            return ident, PROVIDERS[ident]["default"]
        return "openrouter", ident
    head, rest = ident.split("/", 1)
    if head in PROVIDERS:
        return head, rest or PROVIDERS[head]["default"]
    return "openrouter", ident


# ------------------------------------------------------------------ bench

class BenchError(Exception):
    pass


def bench_tabs(world):
    """`./bench tabs` parsed back into dicts — each line is
    `{mark} {id}  {title}  {url}{group}{state}` with mark ⚗=bench,
    ●=active, space=plain; the url is the first token with a scheme."""
    out = bench_cli(world, ["tabs"])
    tabs = []
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        tab = {"bench": line.startswith("⚗"), "active": line.startswith("●")}
        parts = line[1:].lstrip().split("  ")
        tab["id"] = parts[0].strip() if parts else ""
        tab["title"] = parts[1].strip() if len(parts) > 1 else ""
        tail = "  ".join(parts[2:]) if len(parts) > 2 else ""
        tab["url"] = next(
            (tok for tok in tail.split()
             if "://" in tok or tok.startswith(("about:", "data:"))), "")
        tabs.append(tab)
    return tabs


def bench_eval(world, tab, js):
    """`./bench eval` — the {value} answer printed; truthy per the doc.
    The predicate is coerced in the page — `!!(…)` — so a falsy value
    can't reach us as something truthy-looking over the wire ('0',
    'false', an empty-but-present string): the only answers are exactly
    'true' and 'false' ('null' when the tab hands nothing back)."""
    out = bench_cli(world, ["eval", tab, f"!!({js})"])
    text = out.stdout.strip()
    return text, text == "true"


def bench_cli(world, args, timeout=40, check=True):
    """The ./bench script itself — for verbs whose printed output is the
    contract (open → id, winshot → path, close all)."""
    cmd = [sys.executable, str(BENCH), "--world", world] + [str(a) for a in args]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True,
                             timeout=timeout, cwd=str(REPO))
    except subprocess.TimeoutExpired:
        if check:
            raise BenchError(f"bench {' '.join(args)} timed out")
        return None
    if check and out.returncode != 0:
        raise BenchError(
            f"bench {' '.join(args)} failed: "
            f"{out.stderr.strip() or out.stdout.strip()}")
    return out


# ------------------------------------------------------------------ files

def read_chat(chat_file):
    try:
        with open(chat_file, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def agent_texts(chat):
    return [m.get("text", "") for m in chat.get("messages", [])
            if m.get("role") == "agent"]


def notes(chat):
    return [m.get("text", "") for m in chat.get("messages", [])
            if m.get("role") == "note"]


def tool_cards(chat):
    out = []
    for m in chat.get("messages", []):
        if m.get("role") == "agent":
            out.extend(m.get("tools", []) or [])
    return out


def wait_turn(chat_file, timeout, until="reply"):
    """Turn over ⇔ newest role ∈ {agent,note} and mtime quiet ≥ QUIET —
    or just the quiet, for `until:"quiet"` (after a stop, when no final
    message need ever land). Returns (done, quiet_at, chat)."""
    deadline = time.monotonic() + timeout
    chat = {}
    while time.monotonic() < deadline:
        try:
            quiet = (time.time() - os.path.getmtime(chat_file)) >= QUIET
        except OSError:
            quiet = False
        if quiet:
            chat = read_chat(chat_file)
            if until == "quiet":
                return True, time.time(), chat
            messages = chat.get("messages", [])
            if messages and messages[-1].get("role") in ("agent", "note"):
                return True, time.time(), chat
        time.sleep(0.4)
    return False, None, read_chat(chat_file)


def newest_chat(chats_dir):
    """A send reply without 'chat' — take the newest chats/*.json."""
    try:
        names = [n for n in os.listdir(chats_dir) if n.endswith(".json")]
        if names:
            newest = max(names, key=lambda n: os.path.getmtime(
                os.path.join(chats_dir, n)))
            return newest[:-5]
    except OSError:
        pass
    return None


def tool_counts(chat):
    counts = {}
    for card in tool_cards(chat):
        name = card.get("name", "?")
        counts[name] = counts.get(name, 0) + 1
    return counts


# ------------------------------------------------------------------ app

def resolve_app(arg):
    """--app may name the .app bundle or the bare executable; the default
    picks the freshest of the usual two (a stale build mismeasures worse
    than a wrong default)."""
    if arg:
        c = Path(arg).expanduser()
        if not c.is_absolute():
            c = REPO / c
        binary = c / "Contents" / "MacOS" / "Search" if c.suffix == ".app" else c
        if binary.is_file() and os.access(binary, os.X_OK):
            return binary
        sys.exit(f"--app {arg}: no executable at {binary}")
    found = []
    for c in (REPO / "build" / "Search.app" / "Contents" / "MacOS" / "Search",
              REPO / ".build" / "debug" / "Search"):
        if c.is_file() and os.access(c, os.X_OK):
            found.append(c)
    if not found:
        sys.exit("no Search binary — build one (./build.sh) or pass --app")
    found.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return found[0]


def launch(binary, world, log):
    """Direct exec keeps the pid — SEARCH_PROBE names the world; without it
    this process *is* the real browser, which is exactly what must never
    happen."""
    env = dict(os.environ)
    env["SEARCH_PROBE"] = world
    return subprocess.Popen([str(binary)], env=env,
                            stdout=log, stderr=subprocess.STDOUT)


def wait_for_agent(world, timeout=60):
    """agent.sock exists and answers ping — the app is up with bench on."""
    path = os.path.join(world_folder(world), "agent.sock")
    deadline = time.monotonic() + timeout
    probe = Agent(world, timeout=10)
    while time.monotonic() < deadline:
        if os.path.exists(path):
            try:
                if probe.ping().get("pong"):
                    return probe
            except (SocketGone, AgentError, OSError):
                pass
        time.sleep(0.5)
    raise BenchError(f"agent.sock never came up within {timeout} s")


def stop_process(proc):
    if not proc or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


# ---------------------------------------------------------------- fixtures

def start_fixtures(port):
    """http://127.0.0.1:<port>/<name>.html out of fixtures/ — a plain
    http.server the runner owns."""
    proc = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(port),
         "--bind", "127.0.0.1", "--directory", str(FIXTURES)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise BenchError(f"fixture server died on port {port}")
        try:
            socket.create_connection(("127.0.0.1", port), 0.4).close()
            return proc
        except OSError:
            time.sleep(0.25)
    proc.terminate()
    raise BenchError(f"fixture server never answered on 127.0.0.1:{port}")


def resolve_url(spec, port):
    if spec.startswith("fixture:"):
        return f"http://127.0.0.1:{port}/{spec[8:]}.html"
    return spec


# ------------------------------------------------------------------ run

def main():
    ap = argparse.ArgumentParser(
        description="Benchmark Ask end-to-end (design/benchmarks.md).")
    ap.add_argument("--model", default="openrouter/z-ai/glm-5.3-flash",
                    help="provider/model, a bare provider, or an openrouter id")
    ap.add_argument("--suite", default="",
                    help="comma list — keep scenarios whose name or tag is in it")
    ap.add_argument("--world", default="",
                    help="probe world name (default bench-<ts>)")
    ap.add_argument("--reuse", action="store_true",
                    help="keep the world — skip the fresh.sh triad wipe")
    ap.add_argument("--app", default="",
                    help="build/Search.app or .build/debug/Search")
    ap.add_argument("--port", type=int, default=8877)
    ap.add_argument("--keys", default="", help="ask.keys.json to stage")
    ap.add_argument("--timeout", type=float, default=90,
                    help="per-scenario seconds when the JSON doesn't say")
    args = ap.parse_args()

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    world = sanitize_world(args.world or f"bench-{stamp}")
    suite = suite_for(world)
    provider, model = provider_for(args.model)
    model_effective = f"{provider}/{model}"
    folder = world_folder(world)
    chats_dir = os.path.join(folder, "chats")

    wanted = {w.strip() for w in args.suite.split(",") if w.strip()}
    scenarios = []
    for path in sorted(SCENARIOS.glob("*.json")):
        sc = json.loads(path.read_text(encoding="utf-8"))
        sc["tags"] = sc.get("tags", [])
        if wanted and sc["name"] not in wanted \
                and not wanted.intersection(sc["tags"]):
            continue
        scenarios.append(sc)
    if not scenarios:
        sys.exit("no scenarios match — check --suite")

    # Resolved before the wipe: which WebKit stores the run will dirty
    # depends on whether the binary carries the real bundle id.
    binary = resolve_app(args.app or None)
    container = webkit_container(binary)

    print(f"[run] world={world} suite={suite} model={model_effective}")
    print(f"[run] {len(scenarios)} scenario(s), port {args.port}")
    store_note = "kept (--reuse)" if args.reuse else "wiped below"
    if container:
        print(f"[run] {binary.name} is bundle-less / own-bundle — its site "
              f"data lands in ~/Library/WebKit/{container} + "
              f"~/Library/HTTPStorages/{container}*; {store_note}")
    else:
        print(f"[run] {binary.name} carries the real bundle id — site "
              f"data lands in the probe-uuid WebsiteDataStore; {store_note}")

    # ---- 1. the fresh world: wipe the triad unless --reuse
    if not args.reuse:
        wipe_world(world, container)
    else:
        print("[world] --reuse: keeping the world as it stands")

    # ---- 2. defaults: bench+welcomed per spec, ask.mode so the chats are
    #         born full (guard parks ops on cards nobody answers), ask.model
    stage_defaults(suite, provider, model)

    # ---- 3. keys
    stage_keys(world, args.keys or None)

    # ---- 4. launch + socket wait
    applog_path = HERE / f"app-{stamp}.log"
    applog = open(applog_path, "ab", buffering=0)
    proc = launch(binary, world, applog)
    print(f"[app] {binary} pid={proc.pid} SEARCH_PROBE={world}")
    try:
        agent = wait_for_agent(world)
    except BenchError as e:
        stop_process(proc)
        applog.close()
        sys.exit(f"[app] {e}")
    print("[app] agent.sock answers ping")

    def relaunch():
        """Kill and start again on the same world — used by the preflight
        fallback (planned) and the crash guardrail (one chance). Rebinds
        `agent`, so callers must read the current binding after it."""
        nonlocal proc, agent
        stop_process(proc)
        time.sleep(1)
        proc = launch(binary, world, applog)
        agent = wait_for_agent(world)
        agent.call("ui.ask", open=True, timeout=SEND_TIMEOUT)
        try:
            bench_cli(world, ["close", "all"], check=False, timeout=15)
        except BenchError:
            pass
        print(f"[app] relaunched pid={proc.pid}")

    # ---- 5. fixtures + the Ask rail
    rows = []
    meta = {
        "world": world, "suite": suite, "started": stamp,
        "model_requested": args.model, "model_effective": model_effective,
        "provider": provider, "images": PROVIDERS[provider]["images"],
        "isolation": "chat", "offline": False, "app": str(binary),
        "webkit_store": container or "probe-uuid",
        "mode_forced": "full",           # stage_defaults wrote ask.mode=full
        "port": args.port, "filter": sorted(wanted), "reuse": args.reuse,
        "fallback_relaunch": False,
    }
    fserver = None
    try:
        fserver = start_fixtures(args.port)
        print(f"[fixtures] http://127.0.0.1:{args.port}/ <- {FIXTURES}")
        agent.call("ui.ask", open=True, timeout=SEND_TIMEOUT)

        # The per-scenario fresh chat — a build without the Drive.ask patch
        # just ignores `new`; probe it once and flag the shared isolation.
        reply = agent.call("ui.ask", new=True, timeout=SEND_TIMEOUT)
        if not reply.get("newChat"):
            meta["isolation"] = "shared"
            print("[ask] ui.ask{new} unsupported — scenarios share one chat")

        # ---- real-site probe for skipIf:offline
        try:
            urllib.request.urlopen("https://example.com", timeout=5).close()
        except Exception:
            meta["offline"] = True
            print("[net] example.com unreachable — offline scenarios skip")

        # ---- 6. preflight: prove the model before scoring anything
        def get_agent():
            return agent

        effective, fell_back, meta["preflight_chats"] = preflight(
            get_agent, chats_dir, suite, provider, model, relaunch)
        meta["model_effective"] = effective
        meta["provider"] = effective.split("/", 1)[0]
        meta["images"] = PROVIDERS.get(meta["provider"], {}).get("images", True)
        meta["fallback_relaunch"] = fell_back

        # ---- 7. scenarios: new chat → setup → send → drive → wait →
        #         verify → winshot → close all
        crashes = 0
        aborted = False
        for sc in scenarios:
            if aborted:
                rows.append({"name": sc["name"], "ok": None, "skipped": True,
                             "seconds": 0.0, "toolCalls": {}, "chat": None,
                             "detail": "", "shot": None,
                             "reason": "aborted after second crash",
                             "model_effective": effective})
                continue
            row = run_scenario(sc, agent, world, chats_dir, args, meta)
            rows.append(row)
            mark = ("ok" if row.get("ok") is True
                    else "FAIL" if row.get("ok") is False else "skip")
            print(f"[{row['name']}] {mark} {row.get('seconds', 0):.1f}s "
                  f"{row.get('reason') or row.get('detail') or ''}")
            if row.get("crash"):
                crashes += 1
                if crashes >= 2:
                    print("[app] second crash — aborting the run")
                    aborted = True
                    continue
                try:
                    relaunch()
                except (BenchError, AgentError, SocketGone, OSError) as e:
                    print(f"[app] relaunch failed: {e}")
                    aborted = True

    except KeyboardInterrupt:
        print("\n[run] interrupted — writing what there is")
    finally:
        # ---- 8. results + cleanup
        meta["finished"] = datetime.now().isoformat(timespec="seconds")
        write_results(stamp, meta, rows, chats_dir)
        try:
            bench_cli(world, ["close", "all"], check=False, timeout=15)
        except Exception:
            pass
        if fserver:
            fserver.terminate()
        stop_process(proc)
        agent.close()
        applog.close()
        print(f"[app] stopped pid={proc.pid}; log {applog_path}")

    passed = sum(1 for r in rows if r.get("ok") is True)
    failed = sum(1 for r in rows if r.get("ok") is False)
    skipped = sum(1 for r in rows if r.get("skipped"))
    print(f"[run] {passed} passed, {failed} failed, {skipped} skipped"
          f" — results-{stamp}.json / summary-{stamp}.md")
    return 1 if failed else 0


# ---------------------------------------------------------------- preflight

def preflight(get_agent, chats_dir, suite, provider, model, relaunch):
    """'Reply with exactly: OK' — an unscored turn that proves the model
    before the suite does. An openrouter miss (400/404, no endpoints, bad
    model) rewrites ask.model to codex + the model's basename, relaunches
    once, and answers the effective id. `get_agent` reads the caller's
    current Agent — a relaunch rebinds it, so it is called fresh each
    attempt. Returns (model_effective, fell_back, chat_ids)."""
    fell_back = False
    chats = []
    for attempt in range(2):
        reply = get_agent().call(
            "ui.ask", send="Reply with exactly: OK", timeout=SEND_TIMEOUT)
        chat_id = reply.get("chat")
        if chat_id:
            chats.append(chat_id)
        chat_file = os.path.join(chats_dir, f"{chat_id}.json") if chat_id else None
        done, _, chat = wait_turn(chat_file, 60) if chat_file else (False, None, {})
        note = next((n for n in reversed(notes(chat))), "")
        if attempt == 0 and BAD_MODEL.search(note):
            basename = model.rsplit("/", 1)[-1]
            print(f"[preflight] {note.strip()[:140]}")
            print(f"[preflight] falling back to codex/{basename}")
            write_model_default(suite, "codex", basename)
            relaunch()
            fell_back = True
            provider, model = "codex", basename
            continue
        if not done:
            print("[preflight] no answer within 60 s — continuing anyway")
        else:
            last = agent_texts(chat)
            print(f"[preflight] {provider}/{model}: "
                  f"{(last[-1][:80] if last else 'note: ' + note[:80])!r}")
        break
    return f"{provider}/{model}", fell_back, chats


# ---------------------------------------------------------------- scenario

def run_scenario(sc, agent, world, chats_dir, args, meta):
    """new chat → setup tabs → send → drive → wait → verify → shot → cleanup.
    Every step is one of the doc's; nothing retries and nothing is hidden."""
    name = sc["name"]
    timeout = sc.get("timeout") or args.timeout
    row = {"name": name, "ok": False, "seconds": 0.0, "toolCalls": {},
           "chat": None, "detail": "", "shot": None,
           "model_effective": meta["model_effective"]}
    start = time.time()

    # skipIf: "noImages" (provider table) / "offline" (the run-start probe)
    skip = sc.get("skipIf")
    skips = {skip} if isinstance(skip, str) else set(skip or [])
    if "noImages" in skips and not meta["images"]:
        row.update(ok=None, skipped=True, reason="skipIf noImages")
        return row
    if "offline" in skips and meta["offline"]:
        row.update(ok=None, skipped=True, reason="skipIf offline")
        return row

    named, agent_tabs, user_tabs = {}, [], []
    timed_out = False
    chat_file, quiet_at, stop_at, stop_role, chat = None, None, None, None, {}
    try:
        agent.call("ui.ask", new=True, timeout=SEND_TIMEOUT)
        named, agent_tabs, user_tabs = setup_tabs(sc, agent, world, args.port)

        prompt = sc["prompt"].replace("{port}", str(args.port))
        reply = agent.call("ui.ask", send=prompt, timeout=SEND_TIMEOUT)
        chat_id = reply.get("chat") or newest_chat(chats_dir)
        row["chat"] = chat_id
        if chat_id:
            chat_file = os.path.join(chats_dir, f"{chat_id}.json")

        for step in sc.get("drive", []):
            if "sleep" in step:
                time.sleep(float(step["sleep"]))
            if "steer" in step:
                agent.call("ui.ask", timeout=SEND_TIMEOUT,
                           steer=str(step["steer"]).replace(
                               "{port}", str(args.port)))
            if step.get("stop"):
                # Snapshot before the request — verify's "stopped" needs
                # proof the turn was mid-flight; the newest role at this
                # instant ("you" = no reply had landed) is the cheapest.
                if chat_file:
                    msgs = read_chat(chat_file).get("messages", [])
                    stop_role = msgs[-1].get("role") if msgs else None
                agent.call("ui.ask", stop=True, timeout=SEND_TIMEOUT)
                stop_at = time.time()
            if "send" in step:
                agent.call("ui.ask", timeout=SEND_TIMEOUT,
                           send=str(step["send"]).replace(
                               "{port}", str(args.port)))

        if chat_file:
            done, quiet_at, chat = wait_turn(
                chat_file, timeout, until=sc.get("until", "reply"))
        else:
            done = False

        # One rate-limit backoff on a matching note — transport healing,
        # not a re-score: sleep 20 s and resend the same prompt.
        last_note = next((n for n in reversed(notes(chat))), "")
        if chat_file and last_note and RATE_LIMIT.search(last_note):
            row["rateLimited"] = True
            print(f"[{name}] rate-limited "
                  f"({last_note.strip()[:100]}) — 20 s backoff, resend")
            time.sleep(20)
            agent.call("ui.ask", send=prompt, timeout=SEND_TIMEOUT)
            done, quiet_at, chat = wait_turn(
                chat_file, timeout, until=sc.get("until", "reply"))

        if not done:
            timed_out = True
            try:
                agent.call("ui.ask", stop=True, timeout=SEND_TIMEOUT)
            except Exception:
                pass
            row["reason"] = "timeout"
    except SocketGone as e:
        row.update(crash=True, reason="crash", detail=str(e),
                   seconds=time.time() - start)
        return row
    except (AgentError, BenchError) as e:
        # A bench failure is only a crash when the app went with it —
        # probe the agent socket before deciding.
        try:
            agent.ping()
            row.update(reason="harness", detail=str(e))
        except SocketGone:
            row.update(crash=True, reason="crash", detail=str(e))
        except Exception:
            row.update(reason="harness", detail=str(e))
        row["seconds"] = time.time() - start
        cleanup(agent, world, agent_tabs, user_tabs)
        return row
    except Exception as e:  # noqa: BLE001 — a scenario bug mustn't kill the run
        row.update(reason="error", detail=f"{type(e).__name__}: {e}",
                   seconds=time.time() - start)
        cleanup(agent, world, agent_tabs, user_tabs)
        return row

    # verify over bench.sock — even a timed-out scenario reports what it
    # left, though ok stays false.
    ctx = {
        "chat": chat if chat else read_chat(chat_file) if chat_file else {},
        "named": named, "world": world,
        "quiet_at": quiet_at, "stop_at": stop_at, "stop_role": stop_role,
        "chat_file": chat_file,
    }
    try:
        ok, detail = verify(sc.get("verify"), ctx)
    except BenchError as e:
        ok, detail = False, f"verify error: {e}"
    row["ok"] = bool(ok) and not timed_out
    row["detail"] = detail
    row["reason"] = "timeout" if timed_out else ("" if ok else "verify")
    row["toolCalls"] = tool_counts(ctx["chat"])

    # winshot, then cleanup: close all bench tabs, close the runner's own
    # agent tabs, and hand user tabs back to a blank unpinned page.
    SHOTS.mkdir(exist_ok=True)
    shot = SHOTS / f"{name}.png"
    try:
        bench_cli(world, ["winshot", str(shot)], timeout=45)
        row["shot"] = str(shot)
    except BenchError as e:
        row["detail"] = (row["detail"] + f" | winshot: {e}").strip(" |")
    cleanup(agent, world, agent_tabs, user_tabs)
    row["seconds"] = time.time() - start
    return row


def setup_tabs(sc, agent, world, port):
    """The doc's three vias: bench = loose tabs the in-app agent may attach;
    agent = the runner's own socket tabs (verify-only, the agent can't
    drive them); user = the world's blank first tab, navigated by bench
    `go` — a real tab no grant will ever cover."""
    named, agent_tabs, user_tabs = {}, [], []
    for t in (sc.get("setup") or {}).get("tabs", []):
        url = resolve_url(t["url"], port)
        via = t.get("via", "bench")
        tid = None
        if via == "agent":
            tid = agent.open(url)
            agent_tabs.append(tid)
        elif via == "user":
            first = next((x for x in bench_tabs(world)
                          if not x.get("bench")), None)
            if not first:
                raise BenchError("no user tab for via:user")
            tid = first["id"]
            bench_cli(world, ["go", tid, url])
            user_tabs.append(tid)
        else:
            out = bench_cli(world, ["open", url])
            lines = out.stdout.strip().splitlines() if out else []
            tid = lines[-1].strip() if lines else ""
        if not tid:
            raise BenchError(f"setup tab for {t['url']} got no id")
        bench_cli(world, ["wait", tid, "10"], timeout=16, check=False)
        if t.get("pin"):
            bench_cli(world, ["pin", tid])
        if t.get("sleep"):
            out = bench_cli(world, ["sleep", tid], check=False)
            if out is not None and out.returncode == 0 \
                    and '"asleep": true' not in out.stdout:
                print(f"[setup] sleep on {tid}: {out.stdout.strip()[:120]}")
        if t.get("as"):
            named[t["as"]] = tid
    return named, agent_tabs, user_tabs


def cleanup(agent, world, agent_tabs, user_tabs):
    try:
        bench_cli(world, ["close", "all"], check=False, timeout=15)
    except BenchError:
        pass
    for tid in agent_tabs:
        try:
            agent.call("tabs.close", id=tid, timeout=10)
        except Exception:
            pass
    for tid in user_tabs:
        try:
            bench_cli(world, ["pin", tid, "off"], check=False, timeout=10)
            bench_cli(world, ["go", tid, "about:blank"], check=False, timeout=10)
        except BenchError:
            pass


# ------------------------------------------------------------------ verify

def resolve_tab(ref, named, world):
    if ref in ("first", "last"):
        tabs = bench_tabs(world)
        if not tabs:
            raise BenchError("no tabs to resolve")
        return tabs[0]["id"] if ref == "first" else tabs[-1]["id"]
    if ref in named:
        return named[ref]
    return ref


def verify(spec, ctx):
    """→ (ok, detail). Kinds per the doc: js (bench eval {value} truthy),
    chat (last agent text, or every when all:true), tool (tools[] cards),
    tabs (bench tabs fnmatch), stopped (file went quiet ≤ within after
    stop), all/any composites."""
    if not spec:
        return True, "no verify"
    kind = spec.get("kind")

    if kind == "js":
        tab = resolve_tab(spec.get("tab", "last"), ctx["named"], ctx["world"])
        value, ok = bench_eval(ctx["world"], tab, spec["js"])
        return ok, f"eval on {tab}: {value[:200]}"

    if kind == "chat":
        flags = re.IGNORECASE if spec.get("i") else 0
        flags |= re.DOTALL          # the doc's `.*` means anything, lines too
        rx = re.compile(spec["expect"], flags)
        texts = agent_texts(ctx["chat"])
        if not texts:
            return False, "no agent message"
        if spec.get("all"):
            ok = all(rx.search(t or "") for t in texts)
            detail = f"all of {len(texts)} agent texts ~ /{spec['expect']}/"
        else:
            ok = bool(rx.search(texts[-1] or ""))
            detail = f"last agent text ~ /{spec['expect']}/"
        if spec.get("negate"):
            ok = not ok
        return ok, detail + (" (negated)" if spec.get("negate") else "")

    if kind == "tool":
        name = spec.get("name") or ""
        cards = tool_cards(ctx["chat"])
        if name and name != "*":
            cards = [c for c in cards if c.get("name") == name]
        if "failed" in spec:
            cards = [c for c in cards
                     if bool(c.get("failed")) == bool(spec["failed"])]
        need = spec.get("minCalls", 1)
        return (len(cards) >= need,
                f"{len(cards)}/{need} tool cards "
                f"{name or '*'} failed={spec.get('failed', '*')}")

    if kind == "tabs":
        glob = spec.get("url", "*")
        tabs = bench_tabs(ctx["world"])
        if "bench" in spec:
            tabs = [t for t in tabs
                    if bool(t.get("bench")) == bool(spec["bench"])]
        hits = [t for t in tabs if fnmatch.fnmatch(t.get("url", ""), glob)]
        need = spec.get("min", 1)
        return (len(hits) >= need,
                f"{len(hits)}/{need} tabs url~{glob} "
                f"bench={spec.get('bench', '*')}")

    if kind == "stopped":
        if ctx["stop_at"] is None:
            return False, "no stop step ran"
        if ctx["quiet_at"] is None:
            return False, "file never went quiet"
        within = spec.get("within", 15)
        took = ctx["quiet_at"] - ctx["stop_at"]
        if took > within:
            return False, f"quiet {took:.1f}s after stop (>{within})"
        # A quiet file alone is vacuous — the turn could have finished
        # long before the stop. Evidence it was mid-flight is either the
        # file still being written after the stop request (the mtime that
        # went quiet postdates stop_at), or the newest role still "you"
        # at the instant stop was sent (no reply had landed yet).
        try:
            mtime = (os.path.getmtime(ctx["chat_file"])
                     if ctx.get("chat_file") else None)
        except OSError:
            mtime = None
        if mtime is not None and mtime > ctx["stop_at"]:
            return True, (f"quiet {took:.1f}s after stop (≤{within}; "
                          f"wrote after stop)")
        if ctx.get("stop_role") == "you":
            return True, (f"quiet {took:.1f}s after stop (≤{within}; "
                          f"turn mid-flight at stop)")
        return False, (f"turn already over at stop (role "
                       f"{ctx.get('stop_role')!r}, no writes after it) — "
                       f"the quiet is vacuous")

    if kind in ("all", "any"):
        parts = [verify(c, ctx) for c in spec.get("checks", [])]
        ok = all(p[0] for p in parts) if kind == "all" else any(p[0] for p in parts)
        return ok, "; ".join(f"{'ok' if p[0] else 'FAIL'}({p[1]})"
                             for p in parts)

    return False, f"unknown verify kind {kind!r}"


# ------------------------------------------------------------------ output

def write_results(stamp, meta, rows, chats_dir):
    passed = sum(1 for r in rows if r.get("ok") is True)
    failed = sum(1 for r in rows if r.get("ok") is False)
    skipped = sum(1 for r in rows if r.get("skipped"))
    meta.update({"passed": passed, "failed": failed,
                 "skipped": skipped, "total": len(rows)})

    results = HERE / f"results-{stamp}.json"
    results.write_text(json.dumps(
        {"meta": meta, "rows": rows}, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8")

    # the world's chats, beside the results — named by scenario where a
    # row claimed the uuid
    outdir = HERE / f"chats-{stamp}"
    by_chat = {r.get("chat"): r["name"] for r in rows if r.get("chat")}
    for cid in meta.get("preflight_chats", []):
        by_chat.setdefault(cid, "preflight")
    try:
        names = [n for n in os.listdir(chats_dir) if n.endswith(".json")]
    except OSError:
        names = []
    if names:
        outdir.mkdir(exist_ok=True)
        for n in names:
            uuid = n[:-5]
            label = by_chat.get(uuid)
            dest = outdir / (f"{label}-{uuid}.json" if label else n)
            try:
                shutil.copyfile(os.path.join(chats_dir, n), dest)
            except OSError:
                pass

    scored = len(rows) - skipped
    lines = [
        f"# Ask benchmark — {stamp}",
        "",
        f"world `{meta['world']}` · model `{meta['model_effective']}` "
        f"(requested `{meta['model_requested']}`) · isolation {meta['isolation']}"
        + (" · OFFLINE" if meta["offline"] else "")
        + (" · codex fallback" if meta.get("fallback_relaunch") else "")
        + (f" · ask.mode={meta['mode_forced']} forced"
           if meta.get("mode_forced") else "")
        + (f" · suite {','.join(meta['filter'])}" if meta["filter"] else ""),
        "",
        f"**{passed}/{scored} passed**"
        + (f" · {skipped} skipped" if skipped else "")
        + (f" · {failed} failed" if failed else ""),
        "",
        "| scenario | result | s | detail |",
        "|---|---|---|---|",
    ]
    for r in rows:
        if r.get("skipped"):
            mark, detail = "skip", r.get("reason", "")
        elif r.get("ok"):
            mark, detail = "PASS", r.get("detail", "")
        else:
            mark, detail = "FAIL", r.get("reason") or r.get("detail", "")
        lines.append(f"| {r['name']} | {mark} | {r.get('seconds', 0):.1f} | "
                     f"{str(detail).replace('|', '/')} |")
    summary = HERE / f"summary-{stamp}.md"
    summary.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
