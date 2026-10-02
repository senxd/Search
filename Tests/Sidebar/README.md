# Sidebar checks

Run from the repository root:

```sh
python3 Tests/Sidebar/check.py
swiftc -O -parse-as-library Sources/Search/FluidScrollArea.swift Tests/Sidebar/scroll.swift -o /tmp/search-sidebar-scroll-check
/tmp/search-sidebar-scroll-check
swift build
python3 Tests/Sidebar/native.py
```

`check.py` compiles the actual grouping, mode, label, and scroll-pin code. It checks grouping at 4,000 tabs, folded groups, removed Read mode, legacy saved-mode migration, model labels, and unchanged scroll-edge publication.

`scroll.swift` drives the actual AppKit scroll coordinator through 2,000 updates and checks the scrollbar and fade mask, including a zero-length fade.

`native.py` launches one disposable dev process with 400 tabs in 40 groups, captures the actual sidebar, and uses native OCR to verify that the selected final tab is revealed. It closes its process and removes its fixture afterward. Close any existing dev instance before running it.

For live socket validation against an already-running isolated probe world:

```sh
python3 Tests/Sidebar/check.py WORLD
```

This verifies that `agent.mode` and `subscribe` reject Read and accept Confirm (`guard` on the wire) and Full. The main installed Search application is never used.
