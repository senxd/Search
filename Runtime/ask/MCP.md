# Search MCP stdio server

`./ask mcp` exposes Search's existing `agent.sock` session over newline-delimited MCP stdio. It uses only the Python standard library and the existing `sdk/search_agent.py`; each process owns one Search session, and stdin EOF closes it and releases its agent tabs.

Run it from the repository:

```sh
./ask mcp
./ask --world bench-world mcp
```

Configure an MCP host to launch the absolute path to `ask` with arguments `mcp` (and optionally `--world`, `NAME`). The Search browser must already be running with **Settings → General → Let a script drive Search** enabled. Probe worlds use their own Search data folder and should already be running.

The server implements MCP `2025-11-25` initialization, `ping`, `tools/list`, and `tools/call`. It exposes typed browser tools for tabs, navigation, semantic snapshots, text, screenshots, page actions, and page inspection. `browser_drag` accepts locator objects or viewport points and can take intermediate `path` points for one continuous drawing gesture. `page_save_pdf`, `browser_artifacts`, `browser_downloads`, and `artifact_read` save and inspect session-owned PDFs and completed downloads. `artifact_read` returns base64 chunks; pass `id`, then increase `offset` by the returned `nextOffset` until the artifact is exhausted. Screenshots return native MCP image content when available. `search_python` runs Python in a persistent namespace with the connected `agent` object; variables survive between calls, while printed output is returned as text.

`search_python` executes on the local machine with the current user's permissions. It is not a sandbox. The MCP server does not forward cancellation notifications: browser SDK calls are synchronous, and an MCP cancellation cannot interrupt a running call. Stopping the process closes its socket session. External MCP calls have no approval card by default. To opt a socket session into Guard approvals, open an Ask chat in Search, then run `agent.call("agent.mode", to="guard", uiApproval=True)` in `search_python`. Search shows eligible destructive or privileged actions in that chat for a person to approve. The mode call returns `NEEDS_UI` if no Ask chat is open. Without this opt-in, an action needing a card fails with `NEEDS_UI`. The wire cannot grant consent to a user tab. Use the Ask panel to consent to a user tab before attaching it.

The separate interactive Python entrypoint `./ask repl` keeps the same session open until Ctrl-D or Ctrl-C. For non-interactive scripts, `./ask run FILE.py` injects the same connected `agent` object.

Protocol behavior follows the official [MCP lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), and [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) specifications.
