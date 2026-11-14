# Contributing to Perspica

This guide covers how to report problems, set up a development machine, check
a change and send a pull request. The rules every change keeps are in [AGENTS.md](AGENTS.md); coding
agents and people follow the same file.

## Before you start

| You want to | Do this |
|---|---|
| Report a bug | Open an issue with the [bug report form](https://github.com/naoya5/perspica/issues/new/choose). |
| Suggest a feature | Open a feature request first and wait for a reply before you write code. |
| Report a security problem | Do not open a public issue. Follow [SECURITY.md](SECURITY.md). |
| Fix a typo or a small bug | Send a pull request directly. |

Issues and pull requests can be written in English or Japanese.

Never post text, documents or screenshots that you do not want to make public. Perspica's logs
do not contain translated text in normal use, but read them before you attach them.

## Development setup

### Requirements

| Tool | Version | Notes |
|---|---|---|
| macOS | 26 or later, on Apple silicon | |
| Xcode | 26 or later | Swift 6 toolchain; no Xcode project, only SwiftPM |
| llama.cpp | Homebrew `llama.cpp` | Provides `llama-server` |

### First run

Run from the repository root.

```sh
brew install llama.cpp
cd app
tools/make-signing-identity.sh   # once; keeps Accessibility and Screen Recording across rebuilds
swift build
swift test
./make-app.sh install
```

Download a model in the app, or point development runs at a GGUF you already have with
`YAKU_DEV_MODEL=/path/to/model.gguf`. Always pass `--data-dir` for development runs so they do not
change real history, caches or settings, or migrate old Yaku data. See the
[Japanese README](README.md#ソースからビルドする) or [English README](README.en.md#build-from-source)
for a launch example.

## Checks

A change must pass these checks. Run each block from the repository root.

```sh
cd app
swift build            # 0 warnings
swift build -c release
swift test
```

The PDF tests need the public Attention paper at `fixtures/attention.pdf` in the repository
root (not committed; download https://arxiv.org/pdf/1706.03762v7). Without it they skip.
The PDF translator is our own Swift code: do not read, copy or port the source of other PDF
libraries (pdf.js, MuPDF, pdfium, poppler, BabelDOC and so on) when you change it.

## Checking in the real app

Tests alone do not verify the interface or performance. For anything a user can see or feel, drive the real app. The
`.agents/skills/verify-yaku/` folder holds a helper that builds the release binary, stops your
installed copy (only one instance can run), starts the app with `--demo-*` options against a private
scratch data folder, captures windows and log lines, and restores the installed copy afterward.

```sh
V=.agents/skills/verify-yaku/scripts/yaku-verify
$V doctor
$V build
$V begin my-change
$V shot manager-translate WAIT=20 --demo-surface manager --demo-page translate --demo-state done
$V end                      # the evidence stays in docs/checks/shots/verify/ (git-ignored)
```

`.agents/skills/verify-yaku/features/` describes how to reach and check each feature. Run the helper
outside any sandbox; SwiftPM, `screencapture` and `open` need it.

Normal startup uses `Perspica.lock`. When an old `Yaku.lock` exists, the app also uses it to prevent
an old Yaku build and a new Perspica build from running together. Do not delete either lock to bypass
this check, and never kill a process by name.

## Code style

- Swift 6 language mode. UI code is `@MainActor`; `YakuCore` types are `Sendable` and have no UI.
- No third-party Swift packages. If one becomes necessary, explain why in the pull request first.
- UI text and the default `README.md` are Japanese. Keep `README.en.md` in English.
  `README.ja.md` is a compatibility entry. Keep other documents in their existing language;
  code, comments and commit messages are English.
- Comments explain why, not what. Keep measured numbers next to the decision they justify.
- No paths from your own machine in code or docs, and no source or translated text in logs.

## Commits and pull requests

- One logical change per commit, with a message that says what changed for the user and why.
- Fill in the pull request template: what you ran, what you checked in the app, and what you did not
  verify. Include before and after screenshots for UI changes, using test text.

## Signing

`make-app.sh` signs with the self-signed "Yaku Signing" identity when it exists and falls back to ad
hoc signing otherwise. Both are fine for development. There is no notarized build; each user builds
their own copy.

The signing identity and keychain keep the Yaku name. The bundle identifier is now `app.perspica`,
so updating from Yaku requires macOS permissions to be granted again even with the same certificate.

## License

By contributing you agree that your contribution is released under the [MIT License](LICENSE).
External dependencies keep their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
and [docs/release-licenses.md](docs/release-licenses.md) before changing dependencies or distributing
a build.
