"""Native grouped-tab reveal check in a fresh isolated dev world.
Run after swift build: python3 Tests/Sidebar/native.py
"""
import json, os, pathlib, shutil, socket, subprocess, tempfile, time, uuid
root = pathlib.Path(__file__).resolve().parents[2]
world = "sidebar-" + uuid.uuid4().hex[:8]
folder = pathlib.Path.home() / "Library/Application Support" / f"Search ({world})"
folder.mkdir(parents=True)
groups = [dict(id=str(uuid.uuid4()), name=f"Group {i+1}", colour=i%5,
               icon="folder", expanded=i%5 != 0) for i in range(40)]
tabs = [dict(url="about:blank", title=f"Tab {i+1}", name=f"Tab {i+1}",
             groupID=groups[i//10]["id"]) for i in range(400)]
(folder / "session.json").write_text(json.dumps(dict(tabs=tabs, active=399, groups=groups)))
suite = "com.officecommun.search.test." + world
for key in ("bench", "welcomed", "sidebar"):
    subprocess.run(["defaults", "write", suite, key, "-bool", "true"], check=True)
process = subprocess.Popen([str(root / ".build/debug/Search")],
                           env={**os.environ, "SEARCH_PROBE": world},
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def call(verb, **args):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(20); connection.connect(str(folder / "bench.sock"))
        connection.sendall(json.dumps(dict(do=verb, **args)).encode() + b"\n")
        result = json.loads(connection.makefile().readline())
        assert "error" not in result, result
        return result
try:
    deadline = time.monotonic() + 20
    while not (folder / "bench.sock").exists():
        assert time.monotonic() < deadline, "dev app did not start"
        time.sleep(.1)
    assert len(call("tabs")["tabs"]) == 400
    subprocess.run(["python3", str(root / "Tests/Sidebar/check.py"), world], check=True)
    with tempfile.TemporaryDirectory() as temp:
        shot = pathlib.Path(temp) / "column.png"
        call("column", path=str(shot), height=650)
        ocr = pathlib.Path(temp) / "ocr.swift"
        ocr.write_text('''import AppKit
import Vision
let image = NSImage(contentsOfFile: CommandLine.arguments[1])!
var rect = CGRect(origin: .zero, size: image.size)
let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
try VNImageRequestHandler(cgImage: cg).perform([request])
for result in request.results ?? [] { print(result.topCandidates(1).first!.string) }
''')
        text = subprocess.check_output(["swift", str(ocr), str(shot)], text=True)
        assert "Tab400" in text.replace(" ", ""), f"active last tab was not revealed:\n{text}"
        print("PASS native lazy sidebar reveals Tab 400 across 40 groups")
finally:
    process.terminate(); process.wait(timeout=15)
    shutil.rmtree(folder)
    subprocess.run(["defaults", "delete", suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
