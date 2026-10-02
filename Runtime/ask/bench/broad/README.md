# Broader agent benchmarks

This runner executes public BU-Bench-V1 and Odysseys tasks through Search's native Ask harness using `codex/gpt-6-luna`, `xhigh`. Eight independent sessions overlap inference. Native browser operations run through one FIFO because keyboard focus is shared.

## Run

Build Search with `swift build` in an isolated worktree first. The installed Search app must have a valid Codex credential. The runner stages a temporary credential with mode 0600, starts a disposable Search world, and removes that credential and closes its dev app on exit. It leaves the installed app running.

```sh
rtk proxy python3 Runtime/ask/bench/broad/check.py
rtk proxy python3 Runtime/ask/bench/broad/run.py --workers 8 --timeout 600
rtk proxy python3 Runtime/ask/bench/broad/audit.py Runtime/ask/bench/broad/results/<run>
```

`--limit N` selects N tasks per suite, rotating across BU categories and Odysseys difficulty levels. `--task-id ID` can be repeated for exact matched reruns and rejects unknown IDs. It cannot be combined with `--limit`. `--resume DIRECTORY` recovers ungraded cases from a finalized run with the same frozen app and bundled JavaScript. It validates catalog selection, saved scores and input hashes, preserves valid zero scores, and records separate worker counts and fragment provenance. It cannot be combined with other selection options or `--reuse`. For example, use `--resume results/<run> --workers 4 --timeout 600` after a host failure. A partial run never reports full catalog completion. `--reuse` connects to an existing broad-profile test world and leaves ownership of its app and credential with the caller.

## Method

BU-Bench-V1 contains 100 tasks in five categories. Its encrypted catalog and judge prompt are pinned to `browser-use/benchmark` commit `1e0e2f1ed12d3dfbdfab6b7bff415ec090ff9f74`. Odysseys contains 200 tasks, pinned to `ljang0/Odysseys` commit `837814633ef948479abb3d142458f0acdb73fa65`.

Every executor receives the task, never its grading rubric. Odysseys starts from the upstream website field. Sessions own their tabs, including popups, and have separate temporary browser stores. Default tabs within a session share its store; an explicit `fresh:true` request gets a separate private tab. Native preflight checks verify storage isolation, host restart reply routing, browser queue recovery, dialog handling, fixture boundaries and active-executor steering before model tasks start. A fixed 1440 by 900 viewport keeps screenshot coordinates consistent. The executor has 100 inference rounds and a configurable wall-clock deadline. Current runs receive one completion reminder 90 seconds before the hard deadline, capped to half the configured budget; `--completion-reserve 0` disables it. Judges receive no reminder. Recovery retains the original run's reminder policy, which was zero for the frozen baseline. Timeouts retain their partial evidence for grading. Infrastructure errors abort queued work and preserve completed outcomes instead of silently scoring errors as failures.

Native actions have a 30-second callback deadline; automatic evidence screenshots have an 8-second deadline. A missing callback cannot block the shared queue indefinitely. Read-only observation timeouts yield the remaining tool batch and let the model retry or choose another route; write and privileged timeouts preserve unknown-outcome stops. Screenshot failure retains the action result without an image. Automatic screenshots cover the first 100 observations; explicit screenshots can add later evidence. Graders sample from the available images. Pending dialogs also yield the remaining batch while allowing a later query and answer. Cancellation and approval stops take precedence and end the run. Cancellation resolves each operation once, and later native replies cannot complete it again. `preflight.json` preserves the native checks for each run. Owned benchmark tabs capture dialogs automatically. The JS-dialog check verifies that state, early action replies, dialog answers, resumed JavaScript, and immediate cancellation cleanup. Production agents retain explicit opt-in.

Each task gets a separate, tool-free Luna xhigh grading session. BU uses the pinned upstream judge prompt. Odysseys scores every supplied rubric independently in one response. Graders receive browser observations, the final answer, and at most ten screenshots spaced across the trajectory. BU reports binary success; Odysseys reports mean rubric credit and perfect-task success. These are adapted scores. The grading model, pooled Odysseys rubrics, screenshot sampling, public-only execution constraints, deadline and runtime differ from official leaderboard methods, so scores are not directly comparable.

Agent instructions prohibit sign-in, account creation, purchases, publishing and contacting others. BU InteractionTests executors receive two generated samples, a text file and a PNG, when forms accept any file of that type and the task specifies no particular content. Native file choosers accept only exact regular files owned by that run, on HTTPS browser-use.github.io stress-test form pages. Other suites receive no sample files. Host files, other runs' files, aliases, traversal and symlink escapes remain blocked. Empty selections explicitly cancel. The fixture directory is private and removed on release or setup failure. Native gates also block file navigation and arbitrary screenshot paths. The disposable world does not inherit the user's signed-in website sessions.

The broad profile omits `surface_tab` and `ask_user` from its tool schemas and instructions because it has no interactive user. Results stay in the isolated session and the agent reports deliverables through `done`. Normal Search sessions keep both tools. Broad snapshots omit CSS paths by default, retain refs and named role handles, and cap optional action snapshots at 16,000 characters. Explicit `cssLocators:true` and snapshot budgets remain available. Raw SDK defaults keep full locators. Model tool results keep complete JSON, action metadata and an explicit model truncation flag within the 24,000-character context budget; full native observations remain in the private trace.

## Stateless continuation

The updated Codex path replays complete Responses output between tool rounds, preserving opaque encrypted reasoning, assistant phase, item IDs and argument bytes. The final completed output determines which calls execute. Explicit commentary-only or reasoning-only output continues within the round budget; final answers and legacy unphased replies finish normally. Sparse streams retain completed item evidence. A two-round mocked check verifies replay order, deduplication and legacy chat-history compatibility. This change applies within one active task; saved Ask messages still persist visible text and tools rather than raw reasoning items across later user turns.

The full baseline run uses its archived build and bundled JavaScript. Source fixes made during that run require a separate rerun before claiming an effect on task scores or token usage.

## Evidence and privacy

Ignored `results/` folders retain task IDs, full private traces, screenshots, judgments, per-task numeric results, metadata and provider audit records. BU's decrypted prompts and raw traces must stay private under its upstream instructions. Do not commit or publish these folders. Aggregate findings may name task IDs and report statistics without reproducing protected prompts or rubrics.

The audit checks run completeness, unique IDs and model/effort consistency. It reports executor and judge tokens separately. Cached input is part of input tokens; reasoning is part of output tokens. Request sizes are UTF-8 bytes. The original `historyBytes` metric is a JSON character count with image data replaced by placeholders, so it must not be treated as provider tokens or encoded request size.

Token totals include responses with reported provider usage. `unreported_requests` also counts canceled or failed requests that produced no round metrics; their usage is unknown, rather than zero. This is separate from a completed round with missing usage. The audit reports preflight and unscored-attempt usage separately and includes them in all-provider totals, including across recovery fragments.

## Sources

- [BU benchmark and judge](https://github.com/browser-use/benchmark/tree/1e0e2f1ed12d3dfbdfab6b7bff415ec090ff9f74)
- [Odysseys dataset and grading implementation](https://github.com/ljang0/Odysseys/tree/837814633ef948479abb3d142458f0acdb73fa65)
- [Aside's account of its browser agent](https://aside.com/blog/how-we-built-the-sota-browser-agent-that-outperforms-fable)

- [OpenAI stateless conversation state](https://developers.openai.com/api/docs/guides/conversation-state)
- [OpenAI reasoning continuation](https://developers.openai.com/api/docs/guides/reasoning#preserve-reasoning-across-calls)

- [OpenAI assistant phase guidance](https://developers.openai.com/api/docs/guides/deployment-checklist#set-up-the-assistant-phase-parameter)
