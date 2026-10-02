#!/bin/sh
# Run offline checks with `sdk/check_baseline.sh`. Pass WORLD for the live
# request lifecycle check; set SEARCH_ECHO_WORLD for local input regressions.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$ROOT"
swiftc Sources/Search/AgentRequests.swift sdk/test_agent_requests.swift -o "$TMP/request-check"
swiftc Sources/Search/BenchmarkSignals.swift sdk/test_benchmark_signals.swift -o "$TMP/signal-check"
"$TMP/signal-check"
"$TMP/request-check"

(cd Runtime/ask && bun install --frozen-lockfile)
bun Runtime/ask/test/harness.unit.bun.js
bun Runtime/ask/test/harness.profile.bun.js
JSDOM="$ROOT/Runtime/ask/node_modules/jsdom/lib/api.js" bun Runtime/ask/drive.test.js
python3 Runtime/ask/bench/check.py
bun Tests/Guard/harness.bun.js
JSDOM="$ROOT/Runtime/ask/node_modules/jsdom/lib/api.js" bun Tests/GuardPage/guard-page.test.js
(cd sdk && python3 -m unittest test_search_agent)
python3 sdk/test_search_mcp.py

if [ "$#" -gt 0 ]; then
	python3 sdk/check_request_lifecycle.py "$@"
fi
if [ -n "${SEARCH_ECHO_WORLD:-}" ]; then
	python3 Tests/Agent/input_check.py "$SEARCH_ECHO_WORLD"
fi
