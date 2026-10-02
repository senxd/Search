# MiniWoB++ baseline for Search Ask

This runner evaluates the 125 tasks registered by BrowserGym MiniWoB++ through Search's native WKWebView and Ask agent. It serves pinned MiniWoB HTML locally, opens each page as a loose bench tab, starts a seeded episode, sends the exact task instruction through Ask, and scores terminal state after the agent stops.

## Pinned workload

- BrowserGym catalog: `ServiceNow/BrowserGym` commit `c05d7f38f4f788d6e4ee960512c3d5c8aabc6e42` (0.14.4).
- MiniWoB++ pages: `Farama-Foundation/MiniWoB-plusplus` commit `7fd85d71a4b60325c6585396ec4f48377d049838`, pinned in BrowserGym's setup guide.
- Catalog: [tasks.json](tasks.json), 125 registered tasks, SHA-256 `70107a629ac8f714e9fbde7c9007ae1bbfc2f5eae081e6bc22a11bbf2fa59abc`. The pinned HTML tree has five additional pages outside BrowserGym's registry: `button-delay`, `chase-circle`, `hover-shape`, `moving-items`, and `simon-says`. This runner follows the registered 125-task workload.
- MiniWoB++ is MIT licensed. BrowserGym is Apache-2.0.

The Farama README recommends Chromium because other engines can render tasks differently. Search uses WKWebView, so these results are a Search baseline and should not be compared directly with published BrowserGym scores.

## Run

The default run creates a fresh isolated Search world and packages `.build/debug/Search` as a distinct **Search Benchmark** app under `~/Library/Caches/SearchBenchmark/`, with bundle ID `com.officecommun.search.benchmark`. It runs in its own process session outside the repository build directory. Its executable is named `SearchBenchmark` to keep process-name cleanup separate from ordinary Search dev builds. Its WebKit container is separate from installed Search. It requires the debug binary to exist, codex credentials, and the Settings consent that allows the bench socket. The runner stages only the `codex` credential, with mode `0600`; it prefers `~/Library/Application Support/Search/ask.keys.json` when that file contains `codex`, otherwise it uses `~/.codex/auth.json`. It never prints credential data. The benchmark app records the sender PID of SIGTERM in `app.log` as a best-effort diagnostic, then preserves normal termination. Results include the runner PID for attribution.

```sh
python3 Runtime/ask/bench/miniwob/run.py
```

The benchmark uses `codex/gpt-6-luna`, `xhigh`, a 100-round limit, seed `0` for every task, a 332×214 page viewport, and a 180-second wall-clock limit. Model/provider errors abort the run as infrastructure failures. Agent timeouts score zero and the runner continues. Completed task failures do not make the run incomplete.

Inference requests rejected with HTTP 5xx before a model stream starts receive at most two retries, after 1 and 2 seconds. All network attempts and rejections are recorded. Authentication failures and partial streams are never retried. Episodes and browser actions are never replayed.

Before inference, the default runner uses Search's existing `bench pages on` mode to put the test application's normal windows away while its offscreen page window continues rendering. The installed Search application stays separate. Results record `offscreen_ui: true`; startup fails if a test window would remain visible on a screen. `--reuse-existing` leaves window visibility unchanged.

In MiniWoB mode, native page views stay in the active offscreen fixture window when an agent selects their browser tabs. Selection still changes the browser's active tab, while the page keeps its 332×214 viewport and native mouse-event delivery. Page-created child tabs use the same host. This hosting rule requires both an isolated test world and `SEARCH_BENCHMARK=miniwob`; ordinary Search windows keep their usual presentation behavior. A visible window in a MiniWoB process has an empty page stage, including when using `--reuse-existing`.

For a root-controlled pilot app already running with `SEARCH_BENCHMARK=miniwob`, connect without wiping, staging credentials, launching, or stopping the app:

```sh
python3 Runtime/ask/bench/miniwob/run.py --reuse-existing WORLD --tasks click-button,choose-list
```

`--tasks` accepts task IDs or subdomains and creates a partial run. Only a run that accounts for all 125 task IDs with no infrastructure errors and no skipped/uncompleted tasks is marked complete. Results and screenshots are written under `Runtime/ask/bench/miniwob/results/<run-id>/` after each task.

Agent screenshots use CSS-pixel coordinates and report their scale. The separate final-state PNG artifacts use the native display resolution, which can be Retina-sized; each result records `screenshot_pixels` and `screenshot_scale` alongside the CSS viewport.

## Reset and scoring

For each fresh page, the runner waits for `WOB_TASK_READY`, verifies the 332×214 page viewport, then runs:

```js
Math.seedrandom(0);
core.EPISODE_MAX_TIME = 1000000;
core.startEpisodeReal();
core.getUtterance();
```

Search-specific adaptation: BrowserGym drives Playwright/Chromium, while this runner hosts the pinned task HTML in Search's WKWebView. A page-side reset adapter follows BrowserGym's [human-display wrapper](https://github.com/ServiceNow/BrowserGym/blob/c05d7f38f4f788d6e4ee960512c3d5c8aabc6e42/browsergym/miniwob/src/browsergym/miniwob/base.py#L62-L110), applies the fixed seed and episode timeout before `core.startEpisodeReal()`, and reads the exact task utterance for the Ask message. BrowserGym's [task wrappers](https://github.com/ServiceNow/BrowserGym/blob/c05d7f38f4f788d6e4ee960512c3d5c8aabc6e42/browsergym/miniwob/src/browsergym/miniwob/all.py#L138-L162) for `click-menu-2` and [`use-colorwheel-2`](https://github.com/ServiceNow/BrowserGym/blob/c05d7f38f4f788d6e4ee960512c3d5c8aabc6e42/browsergym/miniwob/src/browsergym/miniwob/all.py#L644-L664) reshape their utterances; this adapter reproduces those two phrasings from the same page elements. The agent receives no reward globals or task-specific answer hints. Engine and layout differences remain a measurement limitation.

The 1,000,000 ms task timer follows BrowserGym's wrapper. Ask has its own 180-second wall deadline. Once `WOB_DONE_GLOBAL` becomes true, the runner stops Ask before reading `WOB_RAW_REWARD_GLOBAL`; the model never receives score globals. Score is `1` exactly when a terminal episode has `WOB_RAW_REWARD_GLOBAL > 0`, matching BrowserGym's MiniWoB `validate()` rule. Timeout or a completed non-positive reward scores `0`. The runner does not retry.

Four catalog tasks are marked nondeterministic by BrowserGym: `miniwob.click-pie`, `miniwob.click-pie-nodelay`, `miniwob.terminal`, and `miniwob.visual-addition`. They remain in the full baseline and use the same fixed seed.

Run static checks with:

```sh
python3 Runtime/ask/bench/miniwob/check.py
```
