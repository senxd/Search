#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
work=$(mktemp -d /tmp/search-inspector-check.XXXXXX)
python3 Tests/Inspector/server.py &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; rm -rf "$work"' EXIT
swiftc Sources/Search/AgentInspector.swift Sources/Search/AgentInspectorArtifact.swift Tests/Inspector/main.swift -o "$work/check"
"$work/check"
