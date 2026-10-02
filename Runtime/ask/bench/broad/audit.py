#!/usr/bin/env python3
"""Aggregate completed broad runs without publishing benchmark prompts or traces."""
import collections
import json
from pathlib import Path
import statistics
import sys


def usage(rows, requests=None):
    total = collections.Counter()
    for row in rows:
        value = row.get("usage") or {}
        total["missing_usage"] += not bool(row.get("usage"))
        total["input_tokens"] += value.get("input_tokens", 0)
        total["cached_tokens"] += value.get("input_tokens_details", {}).get("cached_tokens", 0)
        total["output_tokens"] += value.get("output_tokens", 0)
        total["reasoning_tokens"] += value.get("output_tokens_details", {}).get("reasoning_tokens", 0)
    total["uncached_input_tokens"] = total["input_tokens"] - total["cached_tokens"]
    if requests is not None:
        total["unreported_requests"] = max(0, requests - len(rows) + total["missing_usage"])
    return dict(total)


def repeated_reads(observations):
    seen, counts = set(), collections.Counter()
    for observation in observations:
        op, result = observation["op"], observation["result"]
        content = result.get("snapshot", result.get("text"))
        if op not in {"page.snapshot", "page.text"} or not isinstance(content, str):
            continue
        identity = (op, result.get("url"), content)
        if identity in seen:
            counts[op] += 1
        seen.add(identity)
    return dict(counts)


def audit(folder):
    metadata = json.loads((folder / "metadata.json").read_text())
    assert metadata.get("selected_complete"), "audit only completed benchmark runs"
    scores = json.loads((folder / "results.json").read_text())
    assert len(scores) == metadata["expected"]
    assert len({(r["suite"], r["task_id"]) for r in scores}) == len(scores)
    assert all("score" in r for r in scores), "infrastructure failures are not task failures"
    records = [json.loads(line) for line in (folder / "harness.audit.jsonl").read_text().splitlines()]
    chats = collections.defaultdict(list)
    for row in records:
        chats[row.get("chat")].append(row)
    requests = [r for r in records if r["kind"] == "request"]
    assert all((r["model"], r["effort"]) == ("gpt-6-luna", "xhigh") for r in requests)
    rows = []
    scored_chats = set()
    for result in scores:
        directory = folder / result["suite"] / result["task_id"]
        trace = json.loads((directory / "trace.json").read_text())
        judge = json.loads((directory / "judge.json").read_text())
        scored_chats.update([trace["id"], judge["id"]])
        executor_rounds = [r for r in chats[trace["id"]] if r["kind"] == "round"]
        judge_rounds = [r for r in chats[judge["id"]] if r["kind"] == "round"]
        executor_requests = [r for r in chats[trace["id"]] if r["kind"] == "request"]
        judge_requests = [r for r in chats[judge["id"]] if r["kind"] == "request"]
        assert all(sum(r["kind"] == "done" for r in chats[seat]) == 1 for seat in [trace["id"], judge["id"]]), "missing or duplicate harness completion"
        observations = trace.get("observations", [])
        sizes = collections.Counter()
        for observation in observations:
            op = observation["op"]
            response = json.dumps(observation["result"], ensure_ascii=False)
            sizes[op] += len(response)
        cards = [t for m in trace.get("chat", {}).get("messages", []) for t in m.get("tools", [])]
        denied = sum(t.get("failed", False) for t in cards)
        row = {k: result[k] for k in ["task_id", "suite", "score", "perfect", "seconds", "timeout", "limit", "tools"]}
        row.update(executor=usage(executor_rounds, len(executor_requests)), judge=usage(judge_rounds, len(judge_requests)),
                   rounds=len(executor_rounds), requests=len(executor_requests),
                   peak_request_bytes=max((r["bodyBytes"] for r in executor_requests), default=0),
                   judge_requests=len(judge_requests),
                   judge_peak_request_bytes=max((r["bodyBytes"] for r in judge_requests), default=0),
                   peak_images=max((r.get("imageCount", 0) for r in executor_rounds), default=0),
                   repeated_reads=repeated_reads(observations), response_characters=dict(sizes), failed_cards=denied,
                   tool_counts=dict(collections.Counter(r["op"] for r in observations)))
        rows.append(row)
    summary = {"metadata": metadata, "request_profiles": dict(collections.Counter(str((r["model"], r["effort"])) for r in requests)), "suites": {}}
    for suite in sorted({r["suite"] for r in rows}):
        selected = [r for r in rows if r["suite"] == suite]
        picked = []
        # Highest cost, successful, failed and timed-out trajectories in each suite.
        for candidates in [selected, [r for r in selected if r["perfect"]],
                           [r for r in selected if not r["perfect"]], [r for r in selected if r["timeout"]]]:
            for row in sorted(candidates, key=lambda r: r["executor"]["input_tokens"], reverse=True)[:2]:
                if row["task_id"] not in picked:
                    picked.append(row["task_id"])
        summary["suites"][suite] = {"tasks": len(selected), "mean_score": statistics.mean(r["score"] for r in selected),
            "perfect": sum(r["perfect"] for r in selected), "timeouts": sum(r["timeout"] for r in selected),
            "step_limits": sum(r["limit"] for r in selected), "median_seconds": statistics.median(r["seconds"] for r in selected),
            "executor": dict(sum((collections.Counter(r["executor"]) for r in selected), collections.Counter())),
            "judge": dict(sum((collections.Counter(r["judge"]) for r in selected), collections.Counter())), "sample": picked}
    other = [r for r in records if r.get("chat") not in scored_chats]
    summary["other_attempts_and_preflight"] = usage([r for r in other if r["kind"] == "round"],
        sum(r["kind"] == "request" for r in other))
    summary["all_provider_usage"] = usage([r for r in records if r["kind"] == "round"], len(requests))
    summary["sessions"] = rows
    (folder / "audit.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k != "sessions"}, indent=2))
    return summary


if __name__ == "__main__":
    audit(Path(sys.argv[1]).resolve())
