#!/usr/bin/env python3
"""MCP stdio bridge for Search's existing persistent Python Agent session."""

import contextlib
import io
import json
import sys

from search_agent import Agent

VERSION = "2025-11-25"


def field(kind, description, **extra):
    return {"type": kind, "description": description, **extra}


def tool(name, description, method, properties, required=(), annotations=None):
    return {
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": list(required),
            "additionalProperties": False,
        },
        "_method": method,
        "annotations": annotations or {"openWorldHint": True},
    }


TAB = field("string", "Tab id or id prefix.")
TARGET = field("string", "Snapshot ref or locator: e.g. e4, css:button, text:Save, role:button[name='Save'].")
READ = {"readOnlyHint": True, "openWorldHint": True}
WRITE = {"readOnlyHint": False, "openWorldHint": True, "destructiveHint": False}

TOOLS = [
    tool("browser_tabs", "List browser tabs and their metadata.", "tabs", {} , annotations=READ),
    tool("browser_open", "Open an agent tab. It stays out of history and session restoration.", "open", {"url": field("string", "URL to open."), "foreground": field("boolean", "Select the new tab."), "fresh": field("boolean", "Open without user cookies or extensions.")}, ("url",), WRITE),
    tool("browser_attach", "Attach to a tab. User tabs require consent through the Ask panel first.", "attach", {"tab": TAB}, ("tab",), WRITE),
    tool("browser_detach", "Release this session's hold on a tab.", "detach", {"tab": TAB}, ("tab",), WRITE),
    tool("browser_close", "Close an agent tab opened by this session.", "close", {"tab": TAB}, ("tab",), WRITE),
    tool("browser_select", "Bring an owned or attached tab to the front.", "select", {"tab": TAB}, ("tab",), WRITE),
    tool("browser_highlight", "Temporarily outline an element for review. Does not select the tab. Respects Settings > Ask; never work around ATTENTION_DISABLED with JavaScript.", "highlight", {"tab": TAB, "target": TARGET, "duration": field("number", "Seconds before expiry.", minimum=1, maximum=30, default=8), "scroll": field("boolean", "Scroll target into view.", default=True)}, ("tab", "target"), WRITE),
    tool("browser_clear_highlight", "Dismiss this session's temporary outline.", "clear_highlight", {"tab": TAB}, ("tab",), WRITE),
    tool("browser_navigate", "Navigate an owned or attached tab.", "go", {"tab": TAB, "url": field("string", "Destination URL.")}, ("tab", "url"), WRITE),
    tool("browser_history", "Move backward, forward, or reload a tab.", "history", {"tab": TAB, "action": field("string", "History action.", enum=["back", "forward", "reload"])}, ("tab", "action"), WRITE),
    tool("browser_wait", "Wait for a page to finish loading.", "wait", {"tab": TAB, "seconds": field("number", "Optional timeout in seconds.")}, ("tab",), READ),
    tool("browser_snapshot", "Read a semantic snapshot with element refs.", "snapshot", {"tab": TAB, "scope": field("string", "viewport or full.", enum=["viewport", "full"]), "boxes": field("boolean", "Include element boxes."), "max_chars": field("integer", "Maximum snapshot length.", minimum=1)}, ("tab",), READ),
    tool("browser_text", "Read visible page text.", "text", {"tab": TAB}, ("tab",), READ),
    tool("browser_screenshot", "Capture a page image. Returns native MCP image content when available.", "screenshot", {"tab": TAB, "marks": field("boolean", "Mark interactive elements."), "width": field("number", "Output width in pixels.", minimum=1)}, ("tab",), READ),
    tool("browser_click", "Click an element by ref or locator.", "click", {"tab": TAB, "target": TARGET, "tier": field("string", "Input tier.", enum=["auto", "js", "event"]), "button": field("string", "Mouse button.", enum=["left", "middle", "right"]), "double": field("boolean", "Double click."), "modifiers": field("array", "Modifier keys.", items={"type": "string", "enum": ["cmd", "shift", "ctrl", "opt"]})}, ("tab",), WRITE),
    tool("browser_fill", "Set a field's value.", "fill", {"tab": TAB, "target": TARGET, "text": field("string", "Value to set.")}, ("tab", "target", "text"), WRITE),
    tool("browser_type", "Type text with native key events.", "type", {"tab": TAB, "target": TARGET, "text": field("string", "Text to type."), "delay": field("number", "Delay between characters in milliseconds.", minimum=0)}, ("tab", "target", "text"), WRITE),
    tool("browser_press", "Press a key or chord, optionally focusing a target first. Search runs on macOS; use cmd for editing shortcuts.", "press", {"tab": TAB, "key": field("string", "Key name or chord, such as Enter, ArrowDown, or cmd+a."), "target": TARGET, "modifiers": field("array", "Modifier keys.", items={"type": "string", "enum": ["cmd", "shift", "ctrl", "opt"]})}, ("tab", "key"), WRITE),
    tool("browser_hover", "Move the pointer over a ref or locator.", "hover", {"tab": TAB, "target": TARGET}, ("tab",), WRITE),
    tool("browser_scroll", "Scroll a page or element.", "scroll", {"tab": TAB, "target": field("string", "Element ref/locator or page.", default="page"), "dx": field("number", "Horizontal pixels."), "dy": field("number", "Vertical pixels."), "to_text": field("string", "Scroll a matching string into view.")}, ("tab",), WRITE),
    tool("browser_choose", "Choose values in a select element.", "choose", {"tab": TAB, "target": TARGET, "values": field("array", "Selected option values.", items={"type": "string"})}, ("tab", "target", "values"), WRITE),
    tool("browser_check", "Set a checkbox or radio state.", "check", {"tab": TAB, "target": TARGET, "on": field("boolean", "Whether it should be checked.", default=True)}, ("tab", "target"), WRITE),
    tool("browser_submit", "Submit a form, optionally selecting an element within it.", "submit", {"tab": TAB, "target": TARGET}, ("tab",), WRITE),
    tool("browser_click_at", "Click at page coordinates.", "click_at", {"tab": TAB, "x": field("number", "Horizontal page coordinate."), "y": field("number", "Vertical page coordinate.")}, ("tab", "x", "y"), WRITE),
    tool("browser_drag", "Drag from a locator or viewport point to another locator or point. Optional path points keep the gesture continuous for drawing.", "drag", {"tab": TAB, "source": {"anyOf": [{"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, {"type": "object", "properties": {"ref": {"type": "string"}, "css": {"type": "string"}, "loc": {"type": "string"}, "text": {"type": "string"}}, "additionalProperties": False}]}, "to": {"anyOf": [{"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}, {"type": "object", "properties": {"ref": {"type": "string"}, "css": {"type": "string"}, "loc": {"type": "string"}, "text": {"type": "string"}}, "additionalProperties": False}]}, "steps": field("integer", "Interpolation steps.", minimum=1, maximum=64), "path": field("array", "Intermediate viewport points in one continuous stroke.", items={"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}), "modifiers": field("array", "Modifier keys.", items={"type": "string", "enum": ["cmd", "shift", "ctrl", "opt"]})}, ("tab", "source", "to"), WRITE),
    tool("page_save_pdf", "Save the current page as a session-scoped PDF artifact.", "save_pdf", {"tab": TAB}, ("tab",), WRITE),
    tool("browser_artifacts", "List this session's saved PDFs and completed downloads.", "artifacts", {"tab": TAB}, (), READ),
    tool("browser_downloads", "List completed downloads owned by this session.", "downloads", {"tab": TAB}, (), READ),
    tool("artifact_read", "Read a session-scoped artifact as a base64 chunk.", "artifact_read", {"id": field("string", "Artifact id."), "offset": field("integer", "Byte offset.", minimum=0), "length": field("integer", "Chunk size.", minimum=1, maximum=65536)}, ("id",), READ),
    tool("browser_eval", "Evaluate JavaScript in the page. This is privileged and has page access.", "eval", {"tab": TAB, "js": field("string", "JavaScript source.")}, ("tab", "js"), {"readOnlyHint": False, "openWorldHint": True, "destructiveHint": True}),
    tool("browser_code", "Run JavaScript with Search's page driver helpers.", "code", {"tab": TAB, "js": field("string", "JavaScript source.")}, ("tab", "js"), WRITE),
    tool("browser_console", "Read recent console messages.", "console", {"tab": TAB}, ("tab",), READ),
    tool("browser_frames", "List page frames.", "frames", {"tab": TAB}, ("tab",), READ),
]
TOOL_MAP = {item["name"]: item for item in TOOLS}


def call_agent(agent, method, args):
    if method == "tabs":
        return {"tabs": agent.tabs()}
    if method == "open":
        opened = agent.call("tabs.open", url=args["url"], **{k: v for k, v in args.items() if k != "url"})
        return {"id": opened.get("id")}
    if method in ("attach", "detach", "close", "select"):
        return getattr(agent, method)(args["tab"])
    if method == "highlight":
        return agent.highlight(args["tab"], args["target"], duration=args.get("duration", 8), scroll=args.get("scroll", True))
    if method == "clear_highlight":
        return agent.clear_highlight(args["tab"])
    if method == "go":
        return agent.go(args["tab"], args["url"])
    if method == "history":
        return getattr(agent, args["action"])(args["tab"])
    if method == "wait":
        return agent.wait(args["tab"], args.get("seconds"))
    if method == "snapshot":
        return agent.snapshot(args["tab"], scope=args.get("scope", "viewport"), boxes=args.get("boxes", False), max_chars=args.get("max_chars"))
    if method == "text":
        return agent.text(args["tab"])
    if method == "screenshot":
        return agent.screenshot(args["tab"], marks=args.get("marks", False), width=args.get("width"))
    if method == "click":
        return agent.click(args["tab"], args.get("target"), **{k: v for k, v in args.items() if k not in ("tab", "target")})
    if method == "fill":
        return agent.fill(args["tab"], args["target"], args["text"])
    if method == "type":
        return agent.type(args["tab"], args["target"], args["text"], delay=args.get("delay"))
    if method == "press":
        return agent.press(args["tab"], args["key"], target=args.get("target"), modifiers=args.get("modifiers"))
    if method == "hover":
        return agent.hover(args["tab"], args.get("target"))
    if method == "scroll":
        return agent.scroll(args["tab"], args.get("target", "page"), dx=args.get("dx"), dy=args.get("dy"), to_text=args.get("to_text"))
    if method == "choose":
        return agent.select_option(args["tab"], args["target"], args["values"])
    if method == "check":
        return agent.check(args["tab"], args["target"], on=args.get("on", True))
    if method == "submit":
        return agent.submit(args["tab"], args.get("target"))
    if method == "click_at":
        return agent.click_at(args["tab"], args["x"], args["y"])
    if method == "drag":
        drag_args = {key: args[key] for key in ("steps", "path", "modifiers") if key in args}
        if isinstance(args["source"], dict) or isinstance(args["to"], dict):
            return agent.call("act.drag", tab=args["tab"], source=args["source"], to=args["to"], **drag_args)
        return agent.drag(args["tab"], args["source"], args["to"], **drag_args)
    if method == "save_pdf":
        return agent.save_pdf(args["tab"])
    if method == "artifacts":
        return agent.artifacts(args.get("tab"))
    if method == "downloads":
        return agent.downloads(args.get("tab"))
    if method == "artifact_read":
        return agent.artifact_read(args["id"], offset=args.get("offset", 0), length=args.get("length", 48_000))
    if method == "eval":
        return {"value": agent.eval(args["tab"], args["js"])}
    if method == "code":
        return agent.code(args["tab"], args["js"])
    if method == "console":
        return {"messages": agent.console(args["tab"])}
    if method == "frames":
        return {"frames": agent.frames(args["tab"])}
    raise ValueError(f"unsupported browser operation: {method}")


class MCPServer:
    def __init__(self, agent, output, errors=None):
        self.agent = agent
        self.output = output
        self.errors = errors or sys.stderr
        self.initialized = False
        self.closed = False
        self.namespace = {"agent": agent, "__name__": "__search_agent__"}

    def send(self, value):
        self.output.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
        self.output.flush()

    def error(self, ident, code, message, data=None):
        err = {"code": code, "message": message}
        if data is not None:
            err["data"] = data
        self.send({"jsonrpc": "2.0", "id": ident, "error": err})

    def handle(self, request):
        if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
            self.error(request.get("id") if isinstance(request, dict) else None, -32600, "Invalid Request")
            return
        has_id = "id" in request
        ident = request.get("id")
        if has_id and (isinstance(ident, bool) or not isinstance(ident, (str, int))):
            self.error(None, -32600, "Invalid Request: id must be a string or integer")
            return
        method = request["method"]
        params = request.get("params", {})
        if not isinstance(params, dict):
            if has_id:
                self.error(ident, -32602, "Invalid params")
            return

        if method == "notifications/initialized":
            self.initialized = True
            return
        if method.startswith("notifications/"):
            # MCP cancellation is not forwarded: Agent.call is synchronous from
            # this server's transport loop, so a notification can't interrupt it.
            return
        if not has_id:
            return
        if method == "initialize":
            init = params
            if not isinstance(init.get("protocolVersion"), str) or not isinstance(init.get("capabilities"), dict) or not isinstance(init.get("clientInfo"), dict):
                self.error(ident, -32602, "Invalid initialize params")
                return
            self.send({"jsonrpc": "2.0", "id": ident, "result": {
                "protocolVersion": VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "search-agent", "version": "1.0.0", "description": "Drive Search through its existing agent session."},
                "instructions": "The browser session persists for this process. Use browser tools or search_python; closing stdin ends the session and releases its agent tabs.",
            }})
            return
        if not self.initialized:
            self.error(ident, -32002, "Server not initialized")
            return
        if method == "ping":
            self.send({"jsonrpc": "2.0", "id": ident, "result": {}})
        elif method == "tools/list":
            self.send({"jsonrpc": "2.0", "id": ident, "result": {"tools": [
                {k: v for k, v in item.items() if not k.startswith("_")} for item in TOOLS
            ] + [script_tool()]}})
        elif method == "tools/call":
            self.tool_call(ident, params)
        else:
            self.error(ident, -32601, f"Method not found: {method}")

    def tool_call(self, ident, params):
        name = params.get("name")
        args = params.get("arguments", {})
        if not isinstance(name, str) or not isinstance(args, dict):
            self.error(ident, -32602, "tools/call requires a tool name and object arguments")
            return
        if name == "search_python":
            if set(args) != {"code"} or not isinstance(args.get("code"), str):
                self.error(ident, -32602, "search_python requires a string code argument")
                return
            stdout = io.StringIO()
            stderr = io.StringIO()
            try:
                actual_dunder_stdout = sys.__stdout__
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    sys.__stdout__ = stdout
                    try:
                        exec(compile(args["code"], "<search_python>", "exec"), self.namespace)
                    finally:
                        sys.__stdout__ = actual_dunder_stdout
                content = [{"type": "text", "text": stdout.getvalue() or "Script completed."}]
                if stderr.getvalue():
                    content.append({"type": "text", "text": "stderr:\n" + stderr.getvalue(), "annotations": {"audience": ["user"]}})
                self.send({"jsonrpc": "2.0", "id": ident, "result": {"content": content, "isError": False}})
            except Exception as exc:
                self.errors.write(f"search_python: {type(exc).__name__}: {exc}\n")
                self.send({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": stdout.getvalue() + f"{type(exc).__name__}: {exc}"}], "isError": True}})
            return
        spec = TOOL_MAP.get(name)
        if not spec:
            self.error(ident, -32602, f"Unknown tool: {name}")
            return
        schema = spec["inputSchema"]
        props = schema["properties"]
        if set(args) - set(props) or set(spec["inputSchema"]["required"]) - set(args):
            self.error(ident, -32602, f"Invalid arguments for {name}")
            return
        for key, value in args.items():
            rule = props[key]
            kind = rule.get("type")
            valid = {
                "string": lambda x: isinstance(x, str),
                "integer": lambda x: isinstance(x, int) and not isinstance(x, bool),
                "number": lambda x: isinstance(x, (int, float)) and not isinstance(x, bool),
                "boolean": lambda x: isinstance(x, bool),
                "array": lambda x: isinstance(x, list),
            }.get(kind, lambda x: True)(value)
            if not valid or ("enum" in rule and value not in rule["enum"]):
                self.error(ident, -32602, f"Invalid argument: {key}")
                return
            if kind in ("integer", "number") and (("minimum" in rule and value < rule["minimum"]) or ("maximum" in rule and value > rule["maximum"])):
                self.error(ident, -32602, f"Invalid argument: {key}")
                return
            if "anyOf" in rule:
                variants = rule["anyOf"]
                point = (isinstance(value, list) and len(value) == 2
                         and all(isinstance(n, (int, float)) and not isinstance(n, bool) for n in value))
                locator = (isinstance(value, dict) and bool(value)
                           and set(value) <= {"ref", "css", "loc", "text"}
                           and all(isinstance(v, str) for v in value.values()))
                if not (point or locator):
                    self.error(ident, -32602, f"Invalid argument: {key}")
                    return
            if kind == "array" and (("minItems" in rule and len(value) < rule["minItems"]) or ("maxItems" in rule and len(value) > rule["maxItems"])):
                self.error(ident, -32602, f"Invalid argument: {key}")
                return
            item_type = rule.get("items", {}).get("type")
            if kind == "array" and item_type == "string":
                item_rule = rule["items"]
                if any(not isinstance(item, str) or ("enum" in item_rule and item not in item_rule["enum"]) for item in value):
                    self.error(ident, -32602, f"Invalid argument: {key}")
                    return
            if kind == "array" and item_type == "array":
                item_rule = rule["items"]
                point_rule = item_rule.get("items", {})
                if any(not isinstance(point, list) or ("minItems" in item_rule and len(point) < item_rule["minItems"]) or ("maxItems" in item_rule and len(point) > item_rule["maxItems"]) or (point_rule.get("type") == "number" and any(not isinstance(number, (int, float)) or isinstance(number, bool) for number in point)) for point in value):
                    self.error(ident, -32602, f"Invalid argument: {key}")
                    return
        try:
            result = call_agent(self.agent, spec["_method"], args)
            content = []
            if name == "browser_screenshot" and isinstance(result, dict) and isinstance(result.get("data"), str):
                content.append({"type": "image", "data": result["data"], "mimeType": "image/" + result.get("format", "png")})
                result = {k: v for k, v in result.items() if k != "data"}
            if result is not None:
                content.append({"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=2) if not isinstance(result, str) else result})
            self.send({"jsonrpc": "2.0", "id": ident, "result": {"content": content or [{"type": "text", "text": "OK"}], "isError": False}})
        except Exception as exc:
            self.errors.write(f"{name}: {type(exc).__name__}: {exc}\n")
            self.send({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": str(exc)}], "isError": True}})

    def serve(self, source):
        try:
            for line in source:
                if not line.strip():
                    continue
                try:
                    request = json.loads(line)
                except json.JSONDecodeError as exc:
                    self.error(None, -32700, "Parse error", str(exc))
                    continue
                try:
                    self.handle(request)
                except Exception as exc:
                    self.errors.write(f"MCP request failed: {type(exc).__name__}: {exc}\n")
                    if isinstance(request, dict) and "id" in request:
                        self.error(request.get("id"), -32603, "Internal error")
        finally:
            self.agent.close()
            self.closed = True


def script_tool():
    return {
        "name": "search_python",
        "description": "Execute Python in a persistent local namespace with the connected `agent` object. Variables survive between calls. Prints are returned as text. Runs with this user's OS permissions; it is not a sandbox.",
        "inputSchema": {"type": "object", "properties": {"code": field("string", "Python source to execute.")}, "required": ["code"], "additionalProperties": False},
        "annotations": {"readOnlyHint": False, "openWorldHint": True, "destructiveHint": True},
    }


def main(world=None, source=None, output=None, errors=None, agent_factory=Agent):
    agent = agent_factory(world)
    server = MCPServer(agent, output or sys.stdout, errors or sys.stderr)
    server.serve(source or sys.stdin)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write(f"search-mcp: {type(exc).__name__}: {exc}\n")
        raise SystemExit(1)
