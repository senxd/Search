# Action Guard checks

All end-to-end page effects use the local fake website in
`Runtime/ask/bench/fixtures/guard.html`. No provider request, live account,
message, purchase or deletion is needed.

```sh
swift build
bun Tests/GuardPage/guard-page.test.js
bun Tests/Guard/harness.bun.js
bun Runtime/ask/drive.test.js

defaults write com.officecommun.search.test.guard-check bench -bool true
SEARCH_PROBE=guard-check .build/debug/Search
# In another terminal:
python3 Tests/Guard/check.py guard-check
```

The DOM checks need jsdom, like the existing driver tests. Set `JSDOM` to its
module path if it is not installed locally. Quit only the test Search process
when finished. The isolated probe keeps the normal application's data separate.

Verified on 2026-09-28:

- Swift build succeeded.
- Guard DOM checks and agent-loop tests passed.
- Existing driver suite passed all 132 checks.
- Native end-to-end checks passed: sign-in filters, click and Enter sends,
  destructive actions, purchases, unknown actions, overlapping categories,
  cancellation, stale recipients, refresh, JavaScript and coordinate clicks,
  and resistance to a page replacing the driver.
- Native approval screenshot saved in `evidence/approval.png`.
- Existing harness unit suite has one baseline failure: queued steer activity
  expects a delta event. The same failure reproduces without the Guard change.

The native checks call the real Drive gate and approval resolver through the
bench socket. They verify page effects before and after approval; the agent-loop
checks use a fake provider. They do not claim coverage of every website's custom
JavaScript behavior. Classification is heuristic, with an Unverified fallback.
