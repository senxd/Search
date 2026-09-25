---
name: install
description: >
  Rebuild Search and reinstall it into /Applications with the same patch
  swap the in-app updater performs — the bundle changes hands by rename and
  nothing the user owns is touched. Use after completing a feature or fix
  when the installed browser should run it, and when they run /install.
triggers:
  - user
  - model
allowed-tools:
  - read
  - exec
---

# Install Search into /Applications

Run this after a feature or fix is complete and verified, when the installed browser should pick it up. It mirrors what the updater does (`Swap` in `Sources/Search/Updater.swift`): the new bundle replaces the old one by two renames, and nothing outside the bundle is read, moved or rewritten. The installed app is usually ad-hoc signed, which the updater refuses to patch — this skill is how a dev build gets in.

## Build

`./build.sh` from the repo root — a release build at `build/Search.app`, Developer ID signed when a certificate is in the keychain, ad-hoc otherwise. `CFBundleVersion` is a timestamp that only goes up, so the build is always newer than what is installed. Never install a `swift build` binary or a `.build/` product straight into /Applications — only the assembled bundle.

## Off limits

The swap touches the bundle only. Never delete, move, rewrite, or "clean":

- `~/Library/Application Support/Search/` — session, pins, history
- the `com.officecommun.search` defaults suite — settings
- `~/Library/WebKit/com.officecommun.search/` — cookies and sign-ins
- the keychain — passwords. Keeping the bundle id and signing identity is what lets the new build read the old build's items
- test worlds: `~/Library/Application Support/Search (test)` and `Search (NAME)`, suites `com.officecommun.search.test*`

## Swap

Two renames, the same as `Swap.swap`. Never `rm -rf` the installed app first — if the install fails halfway there is no browser left. Never `cp -R` into the existing bundle either — that merges stale files into it.

1. Sanity-check the fresh bundle: `CFBundleIdentifier` in `build/Search.app/Contents/Info.plist` is `com.officecommun.search`.
2. If `/Applications/Search.app.old` exists, remove it first — but only after confirming its plist has the same bundle id. It is the previous swap's aside.
3. `mv /Applications/Search.app /Applications/Search.app.old`
4. `ditto build/Search.app /Applications/Search.app` (or `mv` — `build/` is on the same volume, so a move is a rename).
5. If step 4 fails, `mv /Applications/Search.app.old /Applications/Search.app` — there must always be a working bundle.
6. Remove `.old` once nothing runs from it; otherwise leave it — the app sweeps it on quit and next launch, and deleting it under a running process is the one way to corrupt a session.

A running Search survives the swap: the kernel follows the rename, so the open process keeps running from `.old` until it quits, and the next launch is the new build. Do not quit it unless the user asked for a relaunch. Never `killall` or `osascript quit` — the name and bundle id are shared with test-world processes. To relaunch cleanly, terminate only the process whose executable path is `/Applications/Search.app/Contents/MacOS/Search`, wait for it to exit so session state is written, then `open /Applications/Search.app`.

## Verify

`codesign -dv /Applications/Search.app` and read `CFBundleShortVersionString` / `CFBundleVersion` from its Info.plist — the version should match `./VERSION` and the build should be newer than what was there. Report version, build number, and signing identity.
