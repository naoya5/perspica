# SPEC and performance completion audit

Audit date: 2026-11-10. This report tracks every original audit bullet, splitting compound requirements and cross-referencing repeated findings.

**Not a macOS completion or performance claim.** All 72 original acceptance rows have individual source evidence below. Portable core tests and Python tests run on Linux; the actual macOS app has not been compiled or exercised. “Implemented, Mac unverified” means source evidence only, not a successful app build, UI proof, or measured speedup.

Owners: Engine (engine/data/security), UI (application/presentation), PDF (worker/queue), Overlay (screen/OCR). Joint rows require both caller and implementation.

## Actual validation

- From the repository root, `PYTHONPATH="$TEST_DEPS" python3 -m unittest discover -s pdf-worker/tests`: **37 passed, zero skipped, 3.092s**. `TEST_DEPS` names an isolated installation of `pymupdf==1.26.7`; covers generated PDF font classification, local HTTP/SSE/auth/keepalive/reconnect, truncated streams, chunking/context/bounds, and dual-setting forwarding through a PDF-library stand-in. Tokenizer cases cover actual-count contract, missing/busy endpoint fallback, authentication rejection, cutoff, cancellation and avoiding duplicate successful counts.
- Earlier runs: system Python 27 discovered, 22 passed, five font tests skipped (pymupdf absent); isolated dependency suite 29 passed. Superseded for the current PDF snapshot by the dependency-complete run above.
- Independent deterministic randomized splitting check: **500 cases passed**, seed 710, inputs up to 9999 mixed-script characters. Normalized paragraph contents preserved exactly; each chunk <=1200 weighted characters and <=1800 UTF-8 bytes. Runtime 4.0s. No actual model/tokenizer quality inferred.
- Independent portable Swift 6.1.2 run: `SWIFT_BIN="$SWIFT_TOOLCHAIN/usr/bin" app/tools/linux-core-check.sh "$SCRATCH"`: **40 tests passed, zero compiler warnings**; fresh build 9.12s, tests 7.446s. Builds only `PFML3`, `CompletionRequest`, `RequestBudget`, `EngineScheduling` (including liveness policy), `EngineProxy`, `RotatingLogFile`, `EngineStartupWait` and their scheduler/budget/proxy/log/startup tests. `SWIFT_TOOLCHAIN` and `SCRATCH` name an isolated Linux toolchain and disposable test package. It does not compile `EngineManager`, `EngineClient`, `SelectionManager`, SwiftData, AppKit or UI code.
- Independent tree-sitter Swift parse: **52 of 53 changed/new Swift files parsed cleanly**. The remaining file, `EngineSchedulingTests.swift`, triggers a tree-sitter-swift 0.7.4 diagnostic at `if let ticket = try? await t.value`, but the same file compiles and its tests pass in the real Swift run above. Existing UI source validator: **38 files parsed, 12 source invariants passed**. Uses tree-sitter 0.26.1 and tree-sitter-swift 0.7.4 in an isolated temporary installation. These are syntax/string checks, **not app type checking or behavioral tests**.
- `git diff --check`: passed on the final source snapshot.
- **Not run:** full macOS `swift build`/`swift test`, AppKit/Vision/SwiftData execution, real worker installation, PLaMo/BabelDOC translation, permissions, VoiceOver, screenshots, CPU/memory/timing benchmarks. Linux portable Swift cannot substitute for these; `xcrun`, `screencapture` and `footprint` are absent.

## Remaining verification

- Portable tests cover scheduler priority/cancellation, retry-before-output, exact shared restart, request budgeting, proxy lifecycle and strict log limits. The final regressions also retain a live busy engine after health timeouts and reject startup health success after the 15-second deadline. Actual manager/client lifecycle remains Mac-unverified.
- Status-icon drag-exit cleanup, manager transfer debounce suppression, manager-only swap cancellation, foreground permission snapshots, overlay configured target/long cache, and keyboard block copy were repaired after independent review. They remain unverified on a Mac.
- Overlay typed engine failures now preserve their reason and provide chapter-13 model/retry/log actions. Source rechecked; interaction remains Mac-unverified.
- All macOS runtime acceptance and numeric gates remain unverified. All nine performance benefits remain unmeasured.

### Integration regressions found during independent engine review

These supplement the original inventory; they must not be omitted by claiming the original fixes alone are complete.

| Check | Status | Required regression evidence |
|---|---|---|
| SSE EOF without terminal DONE | Source repair reviewed; Mac stream unverified | Cut a stream after partial text while engine still appears alive; no success/cache/history commit of incomplete result |
| Restart before asynchronous process-exit callback | Portable cached-state/shared-restart/busy-live regressions pass; Mac lifecycle unverified | Kill actual server, observe socket failure before lifecycle callback; exactly one shared restart before first output, never duplicate already emitted output |
| Token fitting overhead and prior-two history | Portable Swift + Python regressions pass; real tokenizer unverified | Exact tokenizer fallback; bounded trimming calls for large glossary; keep two complete preceding pairs whenever feasible without dropping source; requestTooLarge surfaced honestly |
| Slow/disconnected proxy client | Portable streaming/disconnect tests pass; real PDF unverified | Bounded socket send wait; downstream disconnect cancels upstream and releases scheduler slot |
| Proxy shutdown/auth/cancellation bookkeeping | Source reviewed + portable tests pass | No shutdown of reused descriptors; reject missing/incorrect Bearer before body read; no cancelled-waiter ID accumulation |

### Source evidence for history, cache, settings and logs

- `app/Sources/Yaku/App/AppDelegate.swift`: startup calls `pruneHistory` without a `keepHistory` gate; foreground refresh reads both AX and screen permission snapshots.
- `app/Sources/Yaku/Data/TranslationStore.swift`: history inserts have no count trimming; finite retention alone removes expired rows, while `maximumCache = 5000` applies only to cache. Clearing returns failure on unsuccessful persistence.
- `app/Sources/Yaku/Translation/TranslationCoordinator.swift` and `app/Sources/Yaku/Overlay/OverlayTranslator.swift`: whole-source cache keys and completed joined output are used for short and multi-chunk text. Overlay glossary/cache/history operations are batched.
- `app/Sources/Yaku/System/AppPaths.swift`, `app/Sources/Yaku/Engine/EngineManager.swift` and `app/Sources/Yaku/PDF/PDFWorkerProcess.swift`: all three logs use `RotatingLogFile` runtime rotation, with child output captured through the shared rotating pipe. Six portable tests cover exact 5,242,880-byte boundaries, single writes larger than three files, repeated small writes and oversized legacy migration. Each retained file stays <=5MB and the newest 15MB is preserved; native process-pipe wiring remains Mac-unverified.
- `app/Sources/Yaku/Engine/EngineManager.swift`: uses `EngineStartupWait` with a launch-anchored 15-second deadline for both unreachable and 503-loading states, with no 180-second loading extension. Probes and pauses are clamped to remaining time; late 200 responses are rejected. Seven portable fake-clock tests cover boundaries, loading/unreachable failures, client overrun and process death. Actual macOS elapsed deadline behavior remains unverified.
- Removed unused `AppSettings.launchAtLogin`, `crashedUnexpectedly`, `EngineWatchdog.waitForServerPid` and `HUDController.toggleSourceDisplay`. The separate private `EngineManager.waitForServerPid()` remains live and necessary.
- `SPEC.md` changes only the stale PDF dependency description to the actual pinned 2.10.2/BabelDOC setup. Performance, accuracy, priority, token and UX requirements were not relaxed.

## Exhaustive acceptance inventory

“PDF tests + Mac unverified” validates only the Python behavior named in the row. Native Swift queue behavior is never covered by those tests. “Perf source only” means the intended work reduction appears in source, with no measured benefit.
## 1. Original priority bug table

| ID | Requirement | Owner | Status | Acceptance evidence |
|---|---|---|---|---|
| B01 | Never capture password-field content, including clipboard fallback | Engine | Implemented, Mac unverified | AXTextField + AXSecureTextField subrole and conservative secure handling; Mac password field selection produces neither request nor history |
| B02 | HUD above selection includes HUD height and gap, no overlap | UI | Implemented, Mac unverified | Geometry test at lower screen edge, real screenshot with tall HUD |
| B03 | Overlay expansion width is relative, bounded by neighbor minus 8pt or capture right edge | Overlay | Implemented, Mac unverified | Nonzero-x and offset capture geometry tests; no neighbor/no-overlap and multi-line non-expansion |
| B04 | PDF progress accumulates against last published value, so 0.2% increments visibly advance | PDF | Implemented, Mac unverified | Sequence test of five 0.002 increments, stage changes, terminal 1.0 |
| B05 | Manager PDF drop presents first-use component confirmation | UI + PDF | Implemented, Mac unverified | Missing worker: drop queues only after consent, cancellation leaves no job |
| B06a | HUD Tab retranslates with original context | UI | Implemented, Mac unverified | Inspect retained context and request; Mac Tab path |
| B06b | HUD retry retranslates with original context | UI | Implemented, Mac unverified | Error then retry request retains app/window/surrounding text |
| B06c | HUD language change retranslates with original context | UI | Implemented, Mac unverified | Language action retains original selection context |
| B07 | Expired history pruned on launch even when keepHistory is false | Engine + UI | Implemented, Mac unverified | Seed expired/recent rows, disable history, relaunch scratch store |
| B08a | Overlay no-text banner buttons receive clicks | Overlay | Implemented, Mac unverified | Real no-text state close action |
| B08b | Overlay error banner buttons receive clicks | Overlay | Implemented, Mac unverified | Real error retry/close actions |
| B08c | Overlay permission banner buttons receive clicks | Overlay | Implemented, Mac unverified | System Settings action and close |
| B09 | Closing overlay during capture/OCR cancels downstream work | Overlay | Implemented, Mac unverified | Close at capture, OCR, grouping and translation boundaries; no invisible requests/windows |
| B10 | Paste fallback does not always return success when replacement fails | Engine | Implemented, Mac unverified | PID/focus/secure guard before AX write and paste; wrong/changed focus, noneditable field, denied post, failed AX verification; no false success |
| B11 | Clear history/cache reports actual failures, not unconditional success | Engine + UI | Implemented, Mac unverified | Inject failed SwiftData/cache/PDF-temp deletion; visible failure; successful scratch deletion |

## 2. Original UI mismatch bullets

| ID | Requirement | Owner | Status | Acceptance evidence |
|---|---|---|---|---|
| U01a | Status icon itself registers direct PDF file drops | UI | Implemented, Mac unverified | Native drag destination registration, enter/exit cleanup and real icon drop (not just hover-open panel) |
| U01b | Notch itself registers direct PDF file drops | UI | Implemented, Mac unverified | Native drag destination registration and real notch drop |
| U02 | Engine failures also show red failure dot; opening panel clears it | UI | Implemented, Mac unverified | Start failure and unexpected termination, then panel open |
| U03a | Panel drop state replaces contents with rounded-18 quaternary inset per SPEC | UI | Implemented, Mac unverified | Light/dark drop screenshots and invalid file rejection |
| U03b | Panel drop hover lights the edge | UI | Implemented, Mac unverified | Hover enter/exit, reduced motion behavior |
| U04 | Outside click in own manager/settings window dismisses unpinned panel | UI | Implemented, Mac unverified | Local and global clicks; pin still preserves panel |
| U05 | Panel “open in manager” transfers current source/translation/languages/form | UI | Implemented, Mac unverified | Current completed and partial translations preserved in manager |
| U06a | Panel lists waiting PDF jobs, not only current item | UI + PDF | Implemented, Mac unverified | Queue several jobs while first running |
| U06b | Old successful PDF does not hide newer failure | UI + PDF | Implemented, Mac unverified | Success then failure, both actionable |
| U07 | Source input grows 1–6 lines before first translation | UI | Implemented, Mac unverified | Empty to six and seven lines, no translation required |
| U08a | HUD dismisses when selection scrolls | UI | Implemented, Mac unverified | Local/global scroll while HUD open |
| U08b | Option source display is sized for source, not clipped to translation | UI | Implemented, Mac unverified | Long source and short translation, press/release Option |
| U09a | Manager language changes do not mutate panel state | UI | Implemented, Mac unverified | Different language selections across surfaces |
| U09b | Manager swap does not mutate panel state | UI | Implemented, Mac unverified | Swap manager direction while panel state stays intact |
| U10 | Default target setting applies beyond PDFs | UI + Overlay | Implemented, Mac unverified | Fresh panel, manager, HUD, overlay target defaults; explicit source/target choice still respected |
| U11 | Notch setting applies live without relaunch | UI | Implemented, Mac unverified | Toggle off/on on notched Mac, destination/monitors cleanly removed/recreated |
| U12 | Engine memory setting displays actual memory, not port | UI + Engine | Implemented, Mac unverified | Compare shown value with process memory; stopped/unavailable state sane |
| U13 | Retry PDF during another job is queued, never silently ignored | PDF + UI | Implemented, Mac unverified | Failed job retry while running/queued work exists |
| U14 | Overlay dismisses within 200ms despite continuous scrolling | Overlay | Implemented, Mac unverified | First event deadline, repeated events do not postpone; real timing |
| U15 | Overflow block is clickable across its full expanded background | Overlay | Implemented, Mac unverified | Click top/original and bottom/overflow regions, source/Option hit testing |

## 3. Original engine/PDF/data mismatch bullets

| ID | Requirement | Owner | Status | Acceptance evidence |
|---|---|---|---|---|
| E01 | Dual PDF disabled means not generated, not merely discarded | PDF | PDF tests + Mac unverified | Pinned upstream 2.10.2 option/source evidence; worker arguments plus real output/time comparison (also P09) |
| E02 | Requested dual PDF placement failure cannot report success | PDF | Implemented, Mac unverified | Missing/unwritable dual output, fallback directories, rollback/retry behavior |
| E03 | One shared scheduler enforces interactive > overlay > PDF, global maximum four | Engine + PDF + Overlay | Portable tests pass; Mac callers unverified | Real callers all route via scheduler; fill four PDF slots then interactive/overlay; priority and max-inflight test; cancellation releases slots |
| E04 | Full prompt + reserved output fits 4096 tokens for every engine request | Engine + PDF | Portable Swift + Python tests pass; real tokenizer unverified | Actual tokenizer or conservative provable upper bound, context/glossary/history included; pathological Unicode and long input tests; no silent source truncation |
| E05a | Long PDF paragraphs split per SPEC | PDF | PDF tests + Mac unverified | >1200 non-Japanese and >600 Japanese; sentence/paragraph boundaries and unsplittable text |
| E05b | PDF chunks carry previous translated context | PDF | PDF tests + Mac unverified | Last two source/translation pairs in subsequent requests, document title preserved |
| E05c | PDF translation uses streaming | PDF | PDF tests + Mac unverified | SSE partial frames, Unicode boundaries, cancellation, final stop cleanup |
| E06 | One crash recovery applies to screen and PDF callers, not only interactive | Engine + PDF + Overlay | Portable regressions pass; Mac lifecycle unverified | Engine exits before/during each caller, exactly one restart then surfaced failure on repeated crash |
| E07 | Long translations cached | Engine + UI | Implemented, Mac unverified | Repeated long source avoids engine and yields identical combined translation; proper model/context/glossary key |
| E08 | Forever history not capped at 5000 | Engine | Implemented, Mac unverified | >5000 history remains; cache independently stays capped 5000; expiry for finite settings |
| E09a | app.log rotates at 5MB, three files | Engine | Portable limits pass; Mac wiring unverified | Boundary-size append, reopen, max retained count and privacy |
| E09b | engine.log rotates at 5MB, three files | Engine | Portable limits pass; Mac pipe unverified | Child output streaming rotation; server text logging remains disabled |
| E09c | pdf.log rotates at 5MB, three files | Engine + PDF | Portable limits pass; Mac pipe unverified | Worker stderr rotation and user text privacy |
| E10 | Permissions rechecked on every foreground activation | Engine + UI + Overlay | Implemented, Mac unverified | Revoke/grant externally then reactivate, display updates; avoid repeated prompt |
| E11 | Startup health timeout is 15 seconds, not 180 while loading | Engine | Portable deadline tests pass; Mac timing unverified | Repeated 503 and unreachable health return failure at 15s; late 200 rejected; cancelled launch |
| E12 | SPEC worker version matches actual pinned 2.10.2 | PDF | Source agreement checked | SPEC/requirements agree; no unintended dependency upgrade |

## 4. Accessibility and wording

| ID | Requirement | Owner | Status | Acceptance evidence |
|---|---|---|---|---|
| A01a | Reduced motion removes notch springs/scales and completion bounce | UI | Implemented, Mac unverified | Real or demo reduced-motion notch all states, fade only |
| A01b | Reduced motion removes status icon springs/scales/bounce | UI | Implemented, Mac unverified | Starting/success/failure states; no spatial animation |
| A02a | Every control reachable with Tab | UI + Overlay | Implemented, Mac unverified | Full Keyboard Access traversal all surfaces; focusable controls not decorative content |
| A02b | Shortcut recorder has VoiceOver name | UI | Implemented, Mac unverified | Accessibility inspection and VoiceOver announcement |
| A03a | Missing-model error surfaces provide “モデルを取得” | UI + Overlay | Implemented, Mac unverified | Panel/HUD/manager/overlay where applicable navigate to models |
| A03b | Engine/PDF failure surfaces provide “ログを見る” per chapter 13 | UI + Overlay + PDF | Implemented, Mac unverified | Appropriate log opens for each error, retry remains available |

## 5. Original unused-code bullet (each symbol separately)

| ID | Requirement | Owner | Status | Acceptance evidence |
|---|---|---|---|---|
| D01 | Remove or wire AppSettings.launchAtLogin | UI | Implemented, Mac unverified | No dead duplicate setting; actual SMAppService remains functional |
| D02 | Remove or wire crashedUnexpectedly | Engine | Removed; Mac lifecycle unverified | Crash recovery/error indicator still preserved |
| D03 | Remove or wire waitForServerPid | Engine | Removed unused watchdog method | Live EngineManager private PID wait remains; watchdog lifecycle still requires Mac proof |
| D04 | Remove or wire toggleSourceDisplay() | UI | Implemented, Mac unverified | Option source keyboard behavior still works |

## 6. All nine performance findings

Changes can be source-verified on Linux, but benefits remain **unmeasured** without Mac release runtime measurements. Never report estimated CPU as measured, or claim 5% attained. Existing SPEC hard gate is <15% translating with <5% aspiration, not a newly granted relaxation.

| ID | Requirement | Owner | Status | Acceptance evidence |
|---|---|---|---|---|
| P01 | Notch checks cursor position before heavy drag pasteboard read | UI | Perf source only; Mac unmeasured | Source order; on Mac off-target drag 20s CPU vs baseline |
| P02 | Hidden panel stops 30Hz text reveal work | UI | Perf source only; Mac unmeasured | Stream while panel hidden, timer/task stopped; reopen catches up; 3-run CPU range |
| P03 | Streaming text observation isolated from panel/HUD whole view | UI | Perf source only; Mac unmeasured | Observation ownership/subview diff; Time Profiler/SwiftUI invalidation evidence and 3-run CPU range |
| P04 | Unchanged glow settings do not rebuild eight animations | UI | Perf source only; Mac unmeasured | Idempotent state update, layout does not restart; animation count/profile |
| P05 | PDF progress throttle occurs before SwiftData mutation | PDF | Perf source only; Mac unmeasured | Repeated subthreshold progress yields no model write; B04 accumulation retained |
| P06a | Overlay image analysis off main thread | Overlay | Perf source only; Mac unmeasured | Task isolation and cancellation/generation guards; real thread trace and responsiveness |
| P06b | Text width/fit measurement off main thread | Overlay | Perf source only; Mac unmeasured | TextInk/OverlayFit execution isolation, safe sendability, worst-case multi-block trace |
| P07 | OCR Vision tiles bounded, not all 8/15 at once | Overlay | Perf source only; Mac unmeasured | 4K/5K task maximum and cancellation, compare accuracy/results before/after |
| P08a | Cached overlay blocks avoid per-block duplicate saves | Engine + Overlay | Perf source only; Mac unmeasured | Batched cache touch/history write with persisted final state; cache-hit write count |
| P08b | Glossary loaded once per overlay batch | Engine + Overlay | Perf source only; Mac unmeasured | Snapshot once, stable glossary key, no per-block store fetch |
| P09 | Dual-off PDF skips dual generation | PDF | Perf source only; Mac unmeasured | Same as E01, plus real timing/quality comparison |

The user's note about EngineClient byte-by-byte reads is explicitly **not** an evidenced CPU cause or a separate mandatory rewrite. Do not introduce an unrelated stream rewrite without evidence.


## Limits and remaining Mac verification

The 4096 request limit applies to the full prompt plus reserved output. PDF tests exercise the proxy's authenticated `/tokenize` count contract with a stand-in, not the PLaMo tokenizer itself. A cheap UTF-8-byte bound plus BOS avoids counting small prompts; real counting avoids unnecessarily tiny chunks. Missing/busy tokenizers fall back conservatively. Chunks are subdivided to retain two complete preceding pairs whenever feasible; optional history/glossary/context may be removed only when necessary to fit. Source text is never silently truncated. PDF punctuation splitting approximates sentence boundaries with a standard-library regex, not exact NLTokenizer parity. Translation quality and parity require the real model.

Use the repository's `verify-yaku` recipes in `.agents/skills/verify-yaku/`. Build release first, use scratch `--data-dir`, respect the single-instance lock, never kill by name or touch real settings/history/cache, and always end the verification run.

```sh
cd app
swift build
swift test
cd ..
V=.agents/skills/verify-yaku/scripts/yaku-verify
$V doctor
$V begin spec-performance-audit
$V build
# Drive all feature recipes and the cases in the inventory above.
$V end
```

Build must have zero warnings. Real entry points needed: status icon, panel and notch direct drop; manager PDF drop and missing-worker acceptance/decline; Finder open; panel/HUD/manager translation; screen picker/capture; settings. Cover failure/retry/cancellation, concurrent requests, >5000 forever-history rows, long text cache reuse, clearing failures, foreground permission grant/revoke, and all keyboard controls.

Run translating CPU at least three times and report the range, not one favorable number:

```sh
$V cpu translating 16 12 --demo-surface panel --demo-state translating --demo-pin --demo-quit-after 60
```

Also measure hidden-panel streaming through a real single translation, not only the looping demo. Use Time Profiler to establish the effect of observation isolation and unchanged glow updates. Off-target dragging needs a real drag measurement. Inspect 4K/5K OCR task concurrency, accuracy and responsiveness after the cap.

Run `app/tools/measure-targets.sh` with `YAKU_DEV_MODEL`, an unlocked Mac and isolated verification state. Check every SPEC 14 gate independently at its worst relevant case:

| Gate | Required result |
|---|---|
| App size excluding llama-server | <10MB |
| Idle physical footprint, excluding engine | <60MB |
| Idle CPU | <0.3% |
| Completed panel CPU | <1% |
| Glow CPU | <10% |
| Translating CPU including glow/reveal | <15%; <5% remains an aspiration, not demonstrated |
| Hotkey to panel/HUD | <50ms |
| Warm engine first text | <300ms |
| 0.8B cold engine start | <3s |
| 15-page PDF | <120s |
| Dense screen first/all blocks | <=1s / <=3s |
| Overlay disappearance under continuous scroll | <=200ms |

Take light/dark appearances against light/dark backgrounds. Test reduced motion, reduced transparency, increased contrast and VoiceOver. Run the dependency-complete Python suite with the actual worker interpreter, then reconstruct real PDFs with dual on/off and exercise missing/unwritable dual destinations and retry during another job. When claiming PDF improvement, run `app/tools/measure-pdf.sh` alternating baseline/new at least five runs, comparing paragraph/error counts and translated text as well as time.

Byte-by-byte EngineClient reading was explicitly not established as a CPU cause by the original audit. No unrelated stream rewrite or CPU claim is required on that basis.
