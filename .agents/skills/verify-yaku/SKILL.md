---
name: verify-yaku
description: Drive the real Yaku macOS menu-bar translator (SwiftUI app + llama-server engine) to prove a change works or to measure it. Use before reporting any Yaku UI, translation, PDF, screen-translation or performance change as done, when you need screenshots, translation output, app-log lines or CPU/memory numbers from the running app, or when the app "looks off".
---

# verify-yaku

Yaku has no web surface and no test endpoint. You prove behaviour by launching the real release binary with `--demo-*` launch options, which open the same windows and run the same code paths a user's click or hotkey does, then reading the screenshot, the app log and the data directory.

Everything goes through one helper. Run it **outside the Claude Code sandbox** (`dangerouslyDisableSandbox: true`): SwiftPM, `screencapture`, `footprint` and `open` all fail inside it.

```sh
V=.agents/skills/verify-yaku/scripts/yaku-verify   # from the repo root
```

## Facts that shape every run

- **One Yaku at a time.** A `flock` on `~/Library/Application Support/Yaku/Yaku.lock` refuses a second instance, even under `--data-dir`. `begin` stops the user's installed app (`~/Applications/Perspica.app`, or `Yaku.app` from before the 2026-11-09 rename until it is reinstalled) and `end` reopens it. If the lock is held by anything else, `begin` refuses. Do not work around that. Other agents work on this repo in git worktrees (`git worktree list`, for example `~/.herdr/worktrees/Yaku/ui-audit`), and every worktree shares the same lock. When `doctor` reports `BUSY`, run `$V wait-free` (returns once no other agent's Yaku has held the lock for 20 s, gives up after 900 s; the user's installed app does not count, `begin` stops it) and then retry. Never kill another agent's instance. Do not wait with `pgrep -f 'release/Yaku'`: the waiting shell's own command line matches it, so it never sees the lock free. `shot` and `cpu` also check that their own pid holds the lock before they capture, so a race with another agent fails loudly instead of capturing its window.
- **Never touch real data.** The helper always passes `--data-dir <state>/data`, where `<state>` is a private per-user folder under `$TMPDIR` (`begin` prints it). History, cache, settings and PDF jobs land there.
- **The log is shared.** `~/Library/Logs/Yaku/app.log` is the same file for every instance. The helper slices it from the line count at launch, so each `*.log` in the evidence folder holds only your run.
- **The screen must be unlocked.** While it is locked nothing is drawn, `screencapture -l` fails, and CPU reads 0.00%. `doctor` checks this.
- **A failed build leaves the old binary.** `shot`, `cpu` and `translate` refuse a release binary older than any source file. Always rebuild with `$V build`, which exits non-zero on a compile error.

## Launch

```sh
$V doctor                  # read-only: binary fresh? lock holder? screen? llama-server? model?
$V build                   # swift build -c release (+ the winid/opaque capture helpers, built into a private folder under $TMPDIR)
$V begin <run-name>        # evidence folder + stop the installed app if it runs
```

Ready means `doctor` prints `doctor: ready`. There is no long-lived server. Each `shot`, `cpu` or `translate` starts its own instance, waits, collects, and stops exactly that pid.

## Doctor

`$V doctor` answers "is this worth driving?". `STALE` means rebuild. `BUSY` means a Yaku holds the lock: the installed app is fine (`begin` handles it), anything else means another agent or a stray run, so stop and find out who. `LOCKED` means ask for the screen to be unlocked or skip visual proof and say so. `MISSING` model or `llama-server` means translation cannot run.

## Drive

```sh
# A window, captured as PNG, with its log slice
$V shot <name> [WAIT=<s>] [--appearance light|dark] <yaku args...>

# Headless translation through the real engine; prints timing and result lines
$V translate "Attention is all you need."

# CPU % (cumulative CPU-time delta) and phys_footprint of one instance
$V cpu <name> <settle-s> <window-s> <yaku args...>

$V run <name> [WAIT=<s>] <yaku args...>     # no capture: PDF jobs, headless flows, a locked screen
$V log 'demo-translate|translate first piece'   # grep this run's log slices
```

Surfaces and their options are in `features/`. The launch options are declared in `app/Sources/Yaku/Demo/DemoOptions.swift`; each one documents the user action it stands in for. Always give `--demo-quit-after` a value longer than your wait, so a crashed helper cannot leave an instance behind.

## Evidence

Each run writes to `docs/checks/shots/verify/<timestamp>-<run-name>/` (git-ignored, never deleted by the helper): `<name>.png`, `<name>.log`, `translate-N.log`, `cpu.txt`.

A proof:

- Goes through the user's path. `--demo-surface` opens the same window a click opens. `--demo-pdf` takes the same path a drop takes. Do not call internal setters or add test-only endpoints.
- Shows the action and the result. Capture before and after for a visual change. Capture the same composition from the previous commit first (build it in a separate worktree) and compare the two.
- Checks side effects too. Translation lands in `<state>/data/Yaku.store` (history, cache). A PDF writes `<name>-ja.pdf` next to the source. The log names every step (`engine ready`, `translate first piece … in Xs`, `pdf: done … in Xs`).
- States what was not verified. For example, VoiceOver on a real screen, or a hotkey a human must press.

Numbers: run `cpu` at least 3 times and report the range. The translating figure moves by a point between runs. Before you act on a number, change one thing and rebuild (the helper rejects stale binaries), then revert with `git checkout` and rebuild again. Baselines (2026-11-09): idle 0.00% / 34 MB, translating panel 12.6-13.5% / 35 MB, headless translate cold `engineStartup=2.59-3.59s first=0.039-0.040s`.

## Cleanup

```sh
$V end     # stops every instance this run started (by recorded pid), removes the scratch data, reopens the installed app, prints the evidence path
```

Run `end` after every attempt, including failed ones. It never kills by process name and never deletes evidence. `open` needs the sandbox off. If it fails, tell the user to run `open ~/Applications/Perspica.app`.

## Profiling

- Time Profiler: start the instance by hand inside a `begin` / `end` pair (`app/.build/arm64-apple-macosx/release/Yaku --data-dir <state>/data <args> &`), then `xcrun xctrace record --template 'Time Profiler' --attach <pid> --time-limit 10s --output <file>.trace`. Export with `xcrun xctrace export --input <file>.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'` and aggregate the XML (rows carry `thread`, `weight` and a `backtrace` of `frame name=` elements, with `id`/`ref` reuse).
- Never point `xctrace record --launch` at the release binary or `build/Yaku.app`: LaunchServices resolves the identifier `dev.naoya.yaku` and starts the user's `~/Applications/Yaku.app`, which can hang suspended after the recording. To launch under a template (the run loop and display-update tables need it), copy `build/Yaku.app` (from `app/make-app.sh`) to `/tmp`, set `CFBundleIdentifier` to `dev.naoya.yaku.profile` with PlistBuddy, re-sign ad hoc with a `com.apple.security.get-task-allow` entitlement, and launch that copy inside a `begin` / `end` pair. `end` stops the copy if it lingers.
- The SwiftUI template's own tables (`swiftui-updates`, `swiftui-causes`) stay empty for Yaku in both modes. `runloop-events` (main-thread wake-ups per second) and `hitches-updates` are recorded.

## Helpers

- `scripts/yaku-verify` is the only entry point (usage: run it with no arguments).
- `app/tools/capture-lib.sh` (`capture_windows`) picks the window with the most drawn pixels. `shot` uses it.
- `app/tools/measure_cpu.py <pid> <seconds>` does the CPU math. `cpu` uses it.
- `app/tools/measure-targets.sh` re-measures every SPEC 14 target in one go and needs `YAKU_DEV_MODEL`; `measure-pdf.sh` times the PDF worker alone against a private engine (see `features/pdf.md`). They do not stop the installed app, so run them between `$V begin` and `$V end`.
