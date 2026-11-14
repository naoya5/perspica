# AGENTS.md

The working guide for coding agents (Claude Code, Codex and others) and for human contributors.
`CLAUDE.md` imports this file, so every tool reads the same rules.

## What Perspica is

Perspica is a menu-bar translator for macOS that runs entirely on the Mac. It translates selected
text, typed text, PDFs and text on the screen with PLaMo 3 Translate (GGUF), which runs in a
`llama-server` child process bound to `127.0.0.1`. Translated text never leaves the Mac.

Stack: Swift 6, SwiftUI + AppKit, no third-party Swift packages, macOS 26 or later. PDF translation
is native Swift (`app/Sources/YakuCore/NativePDF`) on Core Graphics, Core Text and PDFKit, with no
third-party PDF code. Keep it clean room: never read or port another PDF library's source.

The app was called Yaku until 2026-11-09. Its bundle identifier is now `app.perspica`,
with data under `Application Support/Perspica` and logs under `Logs/Perspica`.
Normal launches migrate old data once without overwriting destination files; old defaults,
conflicts and the non-relocatable PDF environment remain as backups. macOS permissions must
be granted again after the identifier change. Swift modules (`Yaku`, `YakuCore`), the executable,
the signing identity and the `verify-yaku` skill keep their internal names.

## Repository map

| Path | What |
|---|---|
| `app/Sources/YakuCore` | Logic with no UI: the PFML3 prompt, the engine client and SSE parsing, chunking, glossary, language detection, OCR grouping, and the native PDF translator (`NativePDF/`). Unit-tested. |
| `app/Sources/Yaku` | The app: engine lifecycle and watchdog, selection capture, screen OCR overlay, model downloads, PDF queue, every window and surface. |
| `app/Tests/YakuCoreTests` | Swift Testing tests for `YakuCore`. |
| `app/make-app.sh` | Builds, bundles and signs `Perspica.app`; `install` copies it to `~/Applications`. |
| `app/tools/` | Signing setup, capture and measurement scripts used during development. |
| `SPEC.md` | The design specification (Japanese). |
| `docs/perf-review-2026-11-09.md` | Measured performance, the fixes and the hypotheses that were rejected (Japanese). |
| `.agents/skills/verify-yaku/` | How to drive the real app to prove a change. `.claude/skills` links here. |

## Commands

```sh
cd app
swift build                       # keep it at 0 warnings
swift test                        # Swift Testing
./make-app.sh install             # build, sign and replace ~/Applications/Perspica.app
tools/make-signing-identity.sh    # once per machine, so permissions survive rebuilds
```

The PDF tests use the public Attention paper at `fixtures/attention.pdf` in the repository root
(not committed; download https://arxiv.org/pdf/1706.03762v7) and skip without it.
`YAKU_DEBUG_PAGE=<0-based page> swift test --filter NativePDFDebugDump` prints how a page was
split into paragraphs.

## Before you call a change done

- Drive the real app with the `verify-yaku` skill and keep the evidence (screenshots, log lines,
  numbers). Passing tests alone is not done.
- Only one instance runs at a time (`Perspica.lock`, plus an existing legacy `Yaku.lock`),
  shared with the user's installed app and other worktrees. Never kill a process by name.
- Never touch real history, caches, settings or logs. Demo runs always pass `--data-dir`
  (the helper does this); their logs live under that directory's `logs/`.
- Inside the Claude Code sandbox, SwiftPM, `screencapture` and `open` fail. Run them outside it.

## Rules every change keeps

- Translated and source text never leave the Mac. The only network code is the model downloader
  (Hugging Face).
- No translated or source text in logs: lines that carry user text go through `AppLog.content`, which
  writes only in `--data-dir` runs or with `YAKU_LOG_CONTENT=1`.
- No paths from your own machine in code or docs. Development-only inputs come from the
  environment (`YAKU_DEV_MODEL`) or from the source location (`#filePath`).
- UI text is Japanese. Code and comments are English. Public docs may be Japanese or English;
  the default README is Japanese and `README.en.md` is the English entry point.
