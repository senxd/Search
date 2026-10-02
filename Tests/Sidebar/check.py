"""Compile real sidebar/model/mode code with small value stubs. Run: python3 Tests/Sidebar/check.py"""
import pathlib, subprocess, sys, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
def section(file, start, end):
    text = (root / file).read_text()
    return text[text.index(start):text.index(end, text.index(start))]
visible = section("Sources/Search/Browser.swift", "    var visibleItems: [TabItem]", "    func group(for tab:")
model = section("Sources/Search/Mind.swift", "struct AskModel:", "// MARK: - the engine")
pin = section("Sources/Search/AskParts.swift", "@MainActor\nfinal class AskPin:", "// MARK: - the composer box")
mode = section("Sources/Search/AskPolicy.swift", "enum AskMode:", "/// How heavy an op")
code = r'''import Foundation
import SwiftUI
import Combine
enum Motion { static let glide = Animation.linear }
struct Tab { var id = UUID(); var groupID: UUID?; var bench = false }
struct TabGroup { var id = UUID(); var expanded = true }
enum TabItem { case tab(Tab), group(TabGroup) }
final class Browser {
 var tabs: [Tab] = []; var groups: [TabGroup] = []; var lookups = 0
 func group(for tab: Tab) -> TabGroup? { lookups += groups.count; return groups.first { $0.id == tab.groupID } }
''' + visible + "}\n" + model + mode + pin + r'''
let browser = Browser()
browser.groups = (0..<1000).map { _ in TabGroup() }
browser.tabs = browser.groups.flatMap { group in (0..<4).map { _ in Tab(groupID: group.id) } }
let start = Date()
for _ in 0..<30 { precondition(browser.visibleItems.count == 5000) }
fputs(String(format: "visibleItems: %.2f ms for 30 × 4000 tabs", Date().timeIntervalSince(start) * 1000) + "\n", stderr)
precondition(browser.lookups == 0, "sidebar performs a linear group lookup per tab")
browser.groups[0].expanded = false
precondition(browser.visibleItems.count == 4996)
browser.tabs.append(Tab(groupID: nil, bench: true))
precondition(browser.visibleItems.count == 4996)
precondition(AskMode(rawValue: "read") == nil)
precondition(AskMode.guard.label == "Confirm")
let legacy = try JSONDecoder().decode(AskMode.self, from: Data("\"read\"".utf8))
precondition(legacy == .guard)
let roundTrip = try JSONDecoder().decode(AskMode.self, from: JSONEncoder().encode(AskMode.full))
precondition(roundTrip == .full)
precondition(AskModel(provider: "codex", model: "gpt-6-luna").label == "GPT-6 Luna")
precondition(AskModel(provider: "openrouter", model: "z-ai/glm-5.3-flash").label == "GLM-5.3 Flash")
precondition(AskModel(provider: "openrouter", model: "anthropic/claude-sonnet-4.5").label == "Claude Sonnet 4.5")
precondition(AskModel(provider: "openrouter", model: "org/unknown-model").label == "Unknown Model")
MainActor.assumeIsolated {
    let pin = AskPin()
    var old = AskPin.Geo(gap: 600, top: 100, content: 1100, view: 400)
    pin.read(AskPin.Geo(gap: 0, top: 0, content: 1100, view: 400), old)
    var publishes = 0
    let subscription = pin.objectWillChange.sink { publishes += 1 }
    for _ in 0..<500 {
        var new = old; new.top += 0.1; new.gap -= 0.1
        pin.read(old, new); old = new
    }
    precondition(publishes == 0, "scrolling in the middle republishes unchanged edge flags")
    pin.read(old, AskPin.Geo(gap: 0, top: 700, content: 1100, view: 400))
    precondition(pin.atBottom && pin.pinned)
    withExtendedLifetime(subscription) {}
}
print("Sidebar grouping, mode migration, model labels, and scroll invalidation passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    source = pathlib.Path(tmp) / "check.swift"; source.write_text(code)
    binary = pathlib.Path(tmp) / "check"
    subprocess.run(["swiftc", "-O", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

# Optional live backend checks against a disposable, already-running probe world.
if len(sys.argv) > 1:
    sys.path.insert(0, str(root / "sdk"))
    from search_agent import Agent, AgentError
    world = sys.argv[1]
    assert world not in ("", "main", "1"), "an isolated test world is required"
    with Agent(world, timeout=15) as agent:
        for op, key in [("agent.mode", "to"), ("subscribe", "mode")]:
            for invalid in ("read", 0, True, None, [], {}):
                try:
                    agent.call(op, **{key: invalid})
                    raise AssertionError(f"{op} accepted invalid mode {invalid!r}")
                except AgentError as error:
                    assert "guard|full" in str(error), error
        for mode in ("guard", "full"):
            assert agent.call("agent.mode", to=mode)["mode"] == mode
            assert agent.call("subscribe", mode=mode)["subscribed"]
            assert agent.call("agent.mode")["mode"] == mode
    print("Live agent.mode and subscribe reject Read/wrong types and accept Confirm/Full")
