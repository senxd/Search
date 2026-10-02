# Broader agentic benchmark assessment

Worktree: `/Users/winter/.codex/worktrees/broader-agent-benchmarks/Search`  
Branch: `codex/broader-agent-benchmarks`  
Starting snapshot: `cab1dad499718d39f2be42b864a6c377d7d66a79`

## Method

The full baseline runs all 100 BU-Bench-V1 tasks and all 200 Odysseys tasks through Search's native Ask harness. Executors and independent tool-free graders use `codex/gpt-6-luna`, `xhigh`. Eight sessions overlap inference; native browser operations use one FIFO because keyboard focus is shared. Each session has its own temporary browser store and owns its tabs. Default tabs within a session share that store.

The task budget is 100 inference rounds and 600 seconds. Native actions have a 30-second callback deadline, and evidence screenshots have an 8-second deadline. The browser viewport is 1440 by 900. Graders receive native observations, the final answer and at most ten images distributed across the available trajectory. Automatic screenshots cover the first 100 observations; explicit screenshots can add later evidence.

BU uses the pinned upstream judge prompt and reports binary success. Odysseys evaluates every rubric in one grading response and reports mean rubric credit plus perfect-task success. These are adapted scores. The runtime, grading model, pooled Odysseys rubrics, image sampling, deadline and public-web constraints differ from official leaderboard methods.

Execution prohibits account creation, sign-in, purchases, publishing and contacting others. The disposable world does not inherit the user's website logins. Missing required deliverables fail their rubric. These constraints and unavailable live websites can limit completion independently of model ability.

The full baseline uses a frozen app and bundled JavaScript. Queue deadlines, seat storage isolation, host generations, the fixed viewport and full-answer retention were established before that freeze. Responses item replay, recoverable dialog/read handling, unavailable-tool removal, fixture uploads and the later cancellation fixes belong to the updated build. Source changes during the batch cannot affect the baseline. Matched reruns are required before attributing any score or token change to those later fixes.

## Confirmed runtime findings

Store isolation, queue deadlines, generated fixtures and unavailable-tool removal belong to the benchmark runner. Changes to cancellation, script dialog replies, host generations, Responses continuation and answer preservation also affect the shared production paths. Broad-profile automatic dialog capture remains limited to benchmark tabs.

| Finding | Fix | Verification |
| --- | --- | --- |
| A dropped native callback could hold the shared queue indefinitely. Cancellation could wait for that callback. | Bound actions and screenshots, resolve cancellation once, and ignore late replies. Read-only timeouts pause the remaining batch and permit a later retry. Unknown action outcomes end execution. | Native queue preflight and controller checks. |
| Independent seats originally shared browser storage. | Give each seat its own temporary store and retain that store across its default tabs and popups. | Native store identity and ownership checks. |
| Host restarts reused integer request IDs, so stale callbacks could reach a new host. | Key requests by host generation and request ID, and reject stale host events and replies. | Native two-host restart check. |
| An intercepted JavaScript dialog blocked its script callback. The early dialog reply also carried a flag that ended the controller. | Release the script caller when a dialog appears. Pause the remaining action batch, then allow the agent to query, answer and verify. Automatically capture dialogs on owned broad-profile tabs. | Alert/select, confirm, prompt, pending-dialog and cancellation checks. |
| Screenshot subcalls omitted the parent cancellation token. Synchronous cleanup could start another script or replace the cancellation reply with a translated error. | Propagate the token, latch the cancellation reply before cleanup, and reject inactive-token scripts at the shared entry point. | A synthetic active script reproduces the cleanup re-entry and asserts one canonical reply, no follow-up dispatch and no remaining flight or watcher. |
| The stateless Codex loop discarded full Responses items and phase metadata between tool rounds. Commentary-only output could end work. | Replay complete returned items, preserve encrypted reasoning and phase when supplied, use completed output as the call source, and continue explicit working phases within the round budget. | Stream variants, exact replay, call deduplication, phase completion and bounded-loop checks. Counts verify replay without recording opaque payloads. |
| The benchmark offered tab handover and human questions even though both were unavailable. | Remove those tools and instructions only from the broad profile. | Schema, forbidden-dispatch and normal-profile retention checks. |
| Required generic file uploads had no native fixture path. | Stage a text file and PNG for InteractionTests. Accept only exact run-owned files on the upstream synthetic form host and remove them on release. | Ownership, symlink, alias, destination, chooser-callback, cancellation and cleanup checks. |
| The final `done` summary could be lost after a streamed preamble. | Keep the full requested answer and suppress a duplicate already-streamed answer. | Full-answer, preamble and duplication checks. |

These are source and controller findings. A failed task's cause still requires its trajectory and matched rerun evidence. An expired listing, a blocked website or an unsupported answer does not establish a runtime defect.

## Benchmark validity and limits

Odysseys has no declared historical `as_of` date. Its upstream method evaluates live websites. A review found no evidence that the whole suite is frozen to 2025. Relative dates, current prices, listings, recruiting status and forecasts require a declared run date and make results sensitive to website changes.

A rubric scan identified 34 tasks that require creation or population of a CryptPad artifact. A final answer alone cannot prove an artifact exists and contains the requested work. Grading currently relies on native actions, observations and sampled images. Ten distributed images can omit a decisive intermediate view, and final tab metadata is not included in the original judge prompt.

Complete Responses item replay currently lasts for one active job. Saved Ask messages retain visible text and tool cards, so later user turns reconstruct history without the prior opaque reasoning items. That boundary is separate from the single-job benchmark path.

The first full attempt stalled in the native queue and is excluded from benchmark scores. The subsequent frozen batch preserved 285 valid graded tasks before eight host crashes canceled seven queued cases. A recovery fragment uses the identical archived executable and bundled JavaScript with four workers to finish the 15 ungraded cases. Valid zeros are preserved; infrastructure errors never become task failures. Combined usage includes the original failed attempts and preflights. No definite lifecycle leak or crash cause was established. High swap usage makes memory pressure a candidate, not a proven cause. Short pilots remain diagnostic runs rather than full-suite results.

Raw results, decrypted BU prompts, rubrics and traces stay in ignored private result folders. This report contains aggregate findings and identifiers rather than protected benchmark text.

## Sources

- [BU benchmark and judge, pinned revision](https://github.com/browser-use/benchmark/tree/1e0e2f1ed12d3dfbdfab6b7bff415ec090ff9f74)
- [Odysseys benchmark, pinned revision](https://github.com/ljang0/Odysseys/tree/837814633ef948479abb3d142458f0acdb73fa65)
- [Odysseys rubric judge](https://github.com/ljang0/Odysseys/blob/837814633ef948479abb3d142458f0acdb73fa65/scripts/python/run_full_trajectory_per_rubric.py)
- [Aside browser agent article](https://aside.com/blog/how-we-built-the-sota-browser-agent-that-outperforms-fable)
- [OpenAI conversation state](https://developers.openai.com/api/docs/guides/conversation-state)
- [OpenAI reasoning continuation](https://developers.openai.com/api/docs/guides/reasoning#preserve-reasoning-across-calls)
- [OpenAI assistant phase guidance](https://developers.openai.com/api/docs/guides/deployment-checklist#set-up-the-assistant-phase-parameter)
