import io
import json
import os
import subprocess
import sys
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import search_mcp


class FakeAgent:
    def __init__(self, world=None):
        self.world = world
        self.closed = False
        self.calls = []

    def call(self, op, **args):
        self.calls.append((op, args))
        if op == "tabs.open":
            return {"id": "abcd1234"}
        return {"ok": True}

    def tabs(self):
        return [{"id": "abcd1234"}]

    def screenshot(self, *args, **kwargs):
        return {"format": "png", "data": "aGVsbG8=", "path": "/tmp/shot.png"}

    def drag(self, *args, **kwargs):
        self.calls.append(("sdk.drag", args, kwargs))
        return {"ok": True}

    def save_pdf(self, tab):
        self.calls.append(("sdk.save_pdf", (tab,), {}))
        return {"id": "pdf-1", "kind": "pdf"}

    def artifacts(self, tab=None):
        self.calls.append(("sdk.artifacts", (tab,), {}))
        return [{"id": "pdf-1", "kind": "pdf"}, {"id": "dl-1", "kind": "download"}]

    def downloads(self, tab=None):
        self.calls.append(("sdk.downloads", (tab,), {}))
        return [{"id": "dl-1", "kind": "download"}]

    def artifact_read(self, artifact_id, offset=0, length=48_000):
        self.calls.append(("sdk.artifact_read", (artifact_id,), {"offset": offset, "length": length}))
        return {"data": "JVBERg==", "nextOffset": offset + length}

    def close(self):
        self.closed = True

    def highlight(self, tab, target, **args):
        from search_agent import Agent
        return Agent.highlight(self, tab, target, **args)

    def clear_highlight(self, tab):
        from search_agent import Agent
        return Agent.clear_highlight(self, tab)


def request(server, value):
    server.handle(value)
    return json.loads(server.output.getvalue().splitlines()[-1])


class SearchMCPTests(unittest.TestCase):
    def test_attention_tools_use_sdk_and_preserve_options(self):
        server, agent = self.server()
        search_mcp.call_agent(agent, "highlight", {"tab": "t1", "target": "css:#result", "duration": 4, "scroll": False})
        search_mcp.call_agent(agent, "clear_highlight", {"tab": "t1"})
        self.assertEqual(agent.calls, [
            ("page.highlight", {"tab": "t1", "css": "#result", "duration": 4, "scroll": False}),
            ("page.clearHighlight", {"tab": "t1"}),
        ])
        self.assertIn("browser_highlight", search_mcp.TOOL_MAP)
        self.assertIn("browser_clear_highlight", search_mcp.TOOL_MAP)

    def server(self):
        agent, output = FakeAgent(), io.StringIO()
        server = search_mcp.MCPServer(agent, output, io.StringIO())
        server.initialized = True
        return server, agent

    def test_typed_browser_calls_and_native_image(self):
        server, agent = self.server()
        opened = request(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "browser_open", "arguments": {"url": "https://example.com"}}})
        self.assertEqual(opened["result"]["content"][0]["text"], '{\n  "id": "abcd1234"\n}')
        self.assertEqual(agent.calls, [("tabs.open", {"url": "https://example.com"})])
        shot = request(server, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "browser_screenshot", "arguments": {"tab": "abcd1234"}}})
        self.assertEqual(shot["result"]["content"][0], {"type": "image", "data": "aGVsbG8=", "mimeType": "image/png"})

    def test_drag_maps_paths_and_locator_objects_to_drive_payload(self):
        server, agent = self.server()
        request(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "browser_drag", "arguments": {"tab": "t1", "source": {"loc": "role:button[name=\"Move\"]"}, "to": [80, 120], "steps": 12, "path": [[40, 60], [60, 90]], "modifiers": ["shift"]}}})
        self.assertEqual(agent.calls, [("act.drag", {"tab": "t1", "source": {"loc": "role:button[name=\"Move\"]"}, "to": [80, 120], "steps": 12, "path": [[40, 60], [60, 90]], "modifiers": ["shift"]})])

    def test_artifact_tools_map_to_session_sdk_methods(self):
        server, agent = self.server()
        def call(ident, name, args):
            return request(server, {"jsonrpc": "2.0", "id": ident, "method": "tools/call", "params": {"name": name, "arguments": args}})
        call(1, "page_save_pdf", {"tab": "t1"})
        call(2, "browser_artifacts", {"tab": "t1"})
        call(3, "browser_downloads", {})
        call(4, "artifact_read", {"id": "pdf-1", "offset": 10, "length": 256})
        self.assertEqual(agent.calls, [
            ("sdk.save_pdf", ("t1",), {}),
            ("sdk.artifacts", ("t1",), {}),
            ("sdk.downloads", (None,), {}),
            ("sdk.artifact_read", ("pdf-1",), {"offset": 10, "length": 256}),
        ])

    def test_python_namespace_is_persistent_and_stdio_closes_agent(self):
        agent, output = FakeAgent(), io.StringIO()
        server = search_mcp.MCPServer(agent, output, io.StringIO())
        lines = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "search_python", "arguments": {"code": "counter = 41\nprint(counter)"}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search_python", "arguments": {"code": "counter += 1\nprint(counter)"}}},
        ]
        server.serve(io.StringIO("\n".join(json.dumps(line) for line in lines) + "\n"))
        replies = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(replies[0]["result"]["protocolVersion"], search_mcp.VERSION)
        self.assertEqual(replies[1]["result"]["content"][0]["text"], "41\n")
        self.assertEqual(replies[2]["result"]["content"][0]["text"], "42\n")
        self.assertTrue(agent.closed)

    def test_invalid_args_and_unknown_method_are_jsonrpc_errors(self):
        server, _ = self.server()
        bad = request(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "browser_open", "arguments": {"url": 12}}})
        self.assertEqual(bad["error"]["code"], -32602)
        bad_drag = request(server, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "browser_drag", "arguments": {"tab": "t1", "source": {"role": "button"}, "to": [10, 20]}}})
        self.assertEqual(bad_drag["error"]["code"], -32602)
        unknown = request(server, {"jsonrpc": "2.0", "id": 3, "method": "bogus"})
        self.assertEqual(unknown["error"]["code"], -32601)

    def test_real_script_process_uses_stdin_and_keeps_stdout_protocol_only(self):
        script = textwrap.dedent("""
            import runpy, sys, types
            class FakeAgent:
                def __init__(self, world=None): pass
                def close(self): pass
                def tabs(self): return [{"id": "abcd1234"}]
                def call(self, op, **args): return {"pong": True}
            module = types.ModuleType("search_agent")
            module.Agent = FakeAgent
            module.AgentError = Exception
            sys.modules["search_agent"] = module
            sys.argv = [sys.argv[1]]
            runpy.run_path(sys.argv[0], run_name="__main__")
        """)
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "browser_tabs", "arguments": {}}},
        ]
        result = subprocess.run([sys.executable, "-c", script, os.path.join(os.path.dirname(__file__), "search_mcp.py")], input="\n".join(json.dumps(item) for item in messages) + "\n", text=True, capture_output=True, check=True)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], [1, 2, 3])
        self.assertIn("search_python", [item["name"] for item in replies[1]["result"]["tools"]])
        self.assertEqual(json.loads(replies[2]["result"]["content"][0]["text"]), {"tabs": [{"id": "abcd1234"}]})


if __name__ == "__main__":
    unittest.main()
