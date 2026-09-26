# Ask benchmark suite

End-to-end scenarios for the in-app Ask agent, per
`Runtime/ask/design/benchmarks.md`. Everything here runs inside a probe
world only — `run.py` always sets `SEARCH_PROBE` and never touches the
real browser.

## Layout

- `fixtures/` — self-contained HTML pages served from `127.0.0.1:<port>`
  by a `python3 -m http.server` the runner owns.
- `scenarios/` — one JSON per catalog scenario (see the design doc for
  the format: `prompt`, `setup.tabs[]` with `via` bench|agent|user,
  `drive` steps, `verify` kinds, `timeout`, `skipIf`, `tags`).
- `run.py` — stdlib + `sdk/` runner (details below).
- `shots/` — one `bench winshot` PNG per scenario.
- `results-<ts>.json`, `summary-<ts>.md`, `chats-<ts>/`,
  `app-<ts>.log` — one set per run.

## Running

```
python3 Runtime/ask/bench/run.py [--model openai/gpt-6-luna] [--suite form,ui]
    [--world NAME] [--reuse] [--app build/Search.app|.build/debug/Search]
    [--port 8877] [--keys PATH] [--timeout 90]
```

A run: wipes the fresh.sh triad for the world (app folder, defaults
suite, WebKit FNV-1a store) unless `--reuse`; writes `bench`,
`welcomed`, `ask.mode=full`, `ask.model` into the probe defaults suite;
stages `ask.keys.json` (real world or `--keys`, chmod 600, contents
never read); launches the binary with `SEARCH_PROBE`; waits for
`agent.sock` + ping; serves fixtures; opens the Ask rail; runs a
preflight turn (openrouter 400/404 → codex fallback, one relaunch);
then per scenario: `ui.ask{new:true}` → setup tabs → `ui.ask{send}` →
drive steps → chat-file wait (newest role ∈ {agent,note} + 1.5 s mtime
quiet) → verify over `./bench` → `winshot` → `close all`. Results land
beside the runner.

`--suite` matches scenario names and tags; `smoke` tags the three
mechanics scenarios (`form-fill`, `nav-title`, `stop-mid`). Under
`--model echo` the suite exercises every transport and guardrail but
most scenarios fail verification on purpose — echo can't act.

Guardrails: timeout → `ui.ask{stop}` + `reason:"timeout"`; SocketGone →
`crash`, one relaunch then abort; no scenario retries; a rate-limit
note → one 20 s backoff + resend (`rateLimited:true`). `skipIf
noImages` follows the provider's `images` flag; `skipIf offline`
follows a real-site probe at run start.

Requires the sibling `ui.ask{new}` in Drive.swift for per-scenario chat
isolation; without it the runner reports `isolation:"shared"` and keeps
going.
