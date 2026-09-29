# Aside's architecture article and Search

Assessment date: September 28, 2026. The article is dated June 25, 2026. Search means the current working tree, including unfinished changes. This is a source and documentation review. No comparative model run was performed.

## Assessment

Search already implements much of the browser machinery needed for an Aside competitor. The important remaining questions concern the agent's programming environment, context management, delivery of browser events, and completion of longer workflows. Better models can reduce mistakes in interpreting pages and writing tool calls. They cannot recover evidence a browser bridge never exposes, receive events the runtime never forwards, or continue a process after its state has been lost.

The article's compact evidence, asynchronous signals, background execution, and programmable orchestration are useful engineering directions. Exact API syntax, tool counts, prompt lengths, snapshot savings, and screen resolution should be evaluated with Search's current models. The article does not isolate the contribution of each choice through controlled comparisons.

## What the article establishes

Aside describes a Playwright-shaped JavaScript REPL and bash, a CDP-backed wrapper, compact snapshots, asynchronous browser signals, visual fallback, and Chromium patches for background tabs and a 1440 by 900 viewport. It reports benchmark results for combined model-and-runtime systems. These are first-party descriptions; the implementation is proprietary and the article does not publish a reproducible ablation of its architecture choices. [Aside article](https://aside.com/blog/how-we-built-the-sota-browser-agent-that-outperforms-fable).

## What remains useful as models improve

Observation quality still matters. An agent needs the correct target, frame, loading state, and result of an action. Larger context windows make more evidence available, but relevance, completeness, latency, and cost remain separate concerns. Compression should preserve what is necessary to complete the task. A shorter snapshot that removes a required label or state is a regression.

Asynchronous browser behavior is an execution problem. A popup or download can arrive while the model is working from an earlier observation. The runtime must either deliver that change or make the next operation discover it reliably. A stronger model still needs a way to know it happened.

Background work must coexist with the user. Stable rendering and correct focus/input handling prevent the user's browsing from changing the agent's target or receiving the agent's keystrokes. The appropriate viewport can vary by task. Predictability and correct coordinate mapping are the requirements.

Programmable orchestration allows loops, data transformation, branching, and batching without one model round-trip per individual action. Familiar syntax can help, but the practical test is whether it reduces failures and elapsed time while retaining review and cancellation. Unobserved page transitions remain boundaries where fresh evidence is needed.

## What has changed since publication

Official OpenAI documentation records GPT-5.6 on July 9, GPT-6 Astra on September 3, and GPT-6 Sol/Luna on September 22. The releases add programmatic tool calling and, for Astra, asynchronous tool execution and mid-turn steering. A September 25 fix addresses visual-input quality for Sol/Luna. These facts justify retesting June configurations; they do not establish a new Search-versus-Aside success ranking. [API changelog](https://developers.openai.com/api/docs/changelog).

The current computer-use guide recommends code execution for Astra, with JavaScript/Playwright among its examples. It also supports structured computer actions and retaining existing function/MCP tools. This supports testing code orchestration, while leaving room for Search's own high-level operations. The application must preserve the execution environment and enforce permissions whichever interface it chooses. [Computer-use guidance](https://developers.openai.com/api/docs/guides/tools-computer-use).

Long context and tool discovery were already available before the article. GPT-5.5 shipped in April, and its model documentation lists long context, computer use, and tool search. The current tool-search guide documents support from GPT-5.4 onward and deferred loading of tool definitions. A large catalog therefore need not put every schema into every prompt. That option does not require Search to build a discovery system for a small catalog without evidence of a cost problem. [GPT-5.5 documentation](https://developers.openai.com/api/docs/models/gpt-5.5), [Tool search](https://developers.openai.com/api/docs/guides/tools-tool-search).

A model upgrade can improve reasoning within the operations Search exposes. Provider features such as asynchronous calls, mid-turn steering, or programmatic calls require runtime integration; selecting a newer model name does not automatically add them. Search currently has its own provider adapters and loop, so these capabilities need separate verification for each supported provider.

## Where Search already matches the engineering direction

| Area | Current Search implementation | Remaining question |
|---|---|---|
| Compact observations | Semantic snapshots, refs, locator queries, scoped reads, same-origin frames and open shadow roots | Preserve relevant state and frame context under clipping; measure coverage |
| Visual fallback | Screenshots, marked screenshots, coordinate clicks, native pointer/key input | Measure performance by task and current model |
| Background rendering | Real offscreen window at a fixed 1280 by 800 size | Validate focus isolation under concurrent user activity and foreground tab attachment |
| Code execution | Whole JavaScript programs with page helpers | Page-scoped execution lacks a persistent multi-tab task environment |
| Browser events | Socket subscriptions and coalesced tab lifecycle events | No equivalent asynchronous browser-event feed found in the in-app model loop |
| Long-task context | Saved transcripts, steering, a separate routine runner | 30-message replay, 25 model-round ceiling, no token-aware compaction or active-run recovery |
| Policy and handoff | Central Drive guard and same-live-page Keep action | Approved page code has broad authority; validate policy across every entry path |

The background viewport is already implemented through the existing `Bench.house` mechanism, which also houses agent-controlled views. It uses a borderless offscreen window and avoids making it key/main. Foreground attached tabs retain their user-facing layout. This is a substantial existing match to the background-rendering goal. A Chromium fork is unnecessary to implement that goal in Search. The 1440 by 900 size still appears in OpenAI's current code-execution example, but no source reviewed establishes that it is universally better than Search's current dimensions. [Offscreen host](/Users/winter/Documents/GitHub/Search/Sources/Search/Bench.swift:2026), [Drive routing](/Users/winter/Documents/GitHub/Search/Sources/Search/Drive.swift:917), [Current example](https://developers.openai.com/api/docs/guides/tools-computer-use).

Search's normal observation/action path is already high-level. Raw inspector commands are an additional diagnostic capability. Page JavaScript is useful for batching and extraction, but its scope differs from task-level orchestration that retains variables and coordinates multiple tabs. [Tool definitions](/Users/winter/Documents/GitHub/Search/Runtime/ask/harness.js:221), [Page code](/Users/winter/Documents/GitHub/Search/Sources/Search/Drive.swift:1461).

The snapshot already includes roles, names, refs, checked/disabled state, optional coordinates, and frame ancestry in refs. I found no explicit focus-state field in emitted snapshot lines. The traversal has an 8,000-node bound, snapshots can use a caller-provided character cap, and the loop independently clips text tool results at 24,000 characters. Test whether those limits remove useful evidence before optimizing for smaller output. [Snapshot construction](/Users/winter/Documents/GitHub/Search/Runtime/ask/drive.js:313), [Tool-result clipping](/Users/winter/Documents/GitHub/Search/Runtime/ask/harness.js:801).

The event gap is narrower than an absent event system. Search already emits browser lifecycle changes to subscribed external sessions. The in-app loop receives tool results and user steering; its streamed events primarily update the native UI. An existing socket capability is not automatically model-visible context. Feeding concise, task-relevant browser changes into the current loop is a smaller candidate change than replacing the runtime. [Tab event emission](/Users/winter/Documents/GitHub/Search/Sources/Search/Drive.swift:2093), [Steering queue](/Users/winter/Documents/GitHub/Search/Runtime/ask/harness.js:966).

The context tail and model-round budget are explicit in [history replay](/Users/winter/Documents/GitHub/Search/Runtime/ask/harness.js:672) and [the loop](/Users/winter/Documents/GitHub/Search/Runtime/ask/harness.js:897). Routine launch recovery records interrupted runs as failed. These implementation limits remain relevant with a stronger model. [Routine recovery](/Users/winter/Documents/GitHub/Search/Sources/Search/Routines.swift:467).

The current Codex adapter defaults to GPT-6 Luna. This makes a current task comparison more useful than carrying over a June model ranking. [Provider defaults](/Users/winter/Documents/GitHub/Search/Runtime/ask/harness.js:603).

## Choices to retest or qualify

**Tool count.** A REPL can expose a large API behind a single tool name. Compare instruction cost, schema reliability, round-trips, recovery, and permission behavior. The number of advertised tools alone does not measure agent quality. Search's typed tools provide explicit arguments and a shared action gate; retain those advantages when testing a code interface.

**API familiarity.** Familiar browser syntax is a reasonable default. It does not establish that a current model will fail on a small, well-described custom API. Strictly typed calls may be useful for routine mutations; code may help with branching and data processing. Search can compare these paths without replacing its underlying browser driver.

**Low-level protocols.** A transport and a model's everyday interaction API solve different problems. Keep common actions concise, and expose debugger commands when a task needs diagnostics that high-level actions cannot provide. Search's raw WebKit Inspector is an optional diagnostic route alongside native actions and semantic snapshots. Removing it would reduce useful capability.

**Prompt length.** Removing conflicting or irrelevant instructions is sensible. Removing an essential instruction to achieve a token target can make behavior worse. Stable prompt text can also have a different cost from repeated page observations. Measure the actual workload.

**Visual control.** Structured observations and screenshots supply different evidence. Use screenshots for layout, canvas, and visually ambiguous state, and structured observations for inspectable controls and content. Measure their contribution per task category and model rather than choosing one universally.

**Detection and API shortcuts.** An ordinary browser session does not guarantee that a site accepts all automated behavior. A direct API request may omit UI validation, authorization steps, or application state. Treat such requests as separately authorized operations with verifiable results, rather than assuming they are equivalent to clicking the page.

## Measurement and benchmark interpretation

Headline percentages do not determine which architecture Search should use. Compare the same model, reasoning budget, task set, starting state, permissions, retries, and judging procedure. Preserve failure traces and verify deliverables.

Odysseys explicitly distinguishes rubric-average progress, perfect completion, and the holistic Online-Mind2Web judge. Its environment-step count also differs from model-call count. Search's 25 model-round ceiling is therefore not directly comparable with a benchmark's 100 environment steps. A model call can contain multiple actions. [Odysseys methodology](https://odysseysbench.com/paper), [Metric definitions](https://odysseysbench.com/leaderboard).

Browser Use's benchmark owner describes an LLM judge and reports imperfect agreement with human labels. That does not invalidate the benchmark, but it makes the judge and grading protocol part of any comparison. [BU Bench methodology](https://browser-use.com/posts/ai-browser-agent-benchmark).

## Next experiment

Use Search's existing isolated Ask benchmark runner. Start with its current typed tools and page-code path, holding the browser driver and observations constant. Repeat representative tasks with the current default model and a stronger model that is actually available in the same environment. Score final website state or deliverables, elapsed time, model rounds, token cost, needed human input, and recovery after a stale target or page transition. Record policy failures separately from task failures. [Existing runner](/Users/winter/Documents/GitHub/Search/Runtime/ask/bench/README.md:1).

Then change one factor at a time: richer observations, browser-event delivery, context compaction, or a minimal multi-tab scripting interface. This separates benefits of a stronger model from benefits of the runtime. A persistent REPL is a candidate worth testing; its superiority over Search's existing tools has not been established.

My priority order is concise browser-event delivery and complete observations, then context/budget improvements, followed by the task-scripting experiment. Keep the native browser and shared Drive layer. Reuse existing event sources, steering, storage, and benchmark machinery. Scope any new host tools to workflows that demonstrably need them.

The earlier four-project comparison remains at [browser-comparison-2026-09-28.md](/Users/winter/Documents/GitHub/Search/Runtime/ask/design/browser-comparison-2026-09-28.md).
