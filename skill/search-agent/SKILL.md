---
name: search-agent
description: Drive the Search browser through its Python SDK, CLI, or MCP stdio server. Use when the task calls for browser work in Search.
---

Use Search's existing browser agent session for browser tasks. The `agent` Python SDK supports persistent workflows; `./ask repl` is interactive, `./ask run FILE.py` runs a script, and `./ask mcp` serves local MCP clients. See [Runtime/ask/SDK.md](../../Runtime/ask/SDK.md) for the operation catalog and [Runtime/ask/MCP.md](../../Runtime/ask/MCP.md) for MCP setup and limits.

The browser must already be running with **Let a script drive Search** enabled. Prefer semantic snapshots and locator-based actions; refresh evidence after navigation. The SDK and MCP tools support continuous drag paths, page-to-PDF artifacts, completed-download listing, and chunked artifact reads. User tabs require consent in the Ask panel before attachment. Agent tabs belong to the session and close when it disconnects unless kept. MCP Python execution has the local user's permissions and is not sandboxed. MCP calls that need Guard approval fail with `NEEDS_UI` unless an Ask chat is open and the session opts in with `agent.call("agent.mode", to="guard", uiApproval=True)`.
