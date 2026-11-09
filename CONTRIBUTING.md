# Contributing to Perspica

Thank you for helping. This guide covers how to report problems, set up a development machine, check
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

Never post text, documents or screen pictures that you do not want to make public. Perspica's logs
do not contain translated text in normal use, but read them before you attach them.

## Development setup

### Requirements

| Tool | Version | Notes |
|---|---|---|
| macOS | 26 or later, on Apple silicon | |
| Xcode | 26 or later | Swift 6 toolchain; no Xcode project, only SwiftPM |
| llama.cpp | Homebrew `llama.cpp` | Provides `llama-server` |
| uv | Homebrew `uv` | Installs the PDF worker |

### First run

```sh
brew install llama.cpp uv
cd app
tools/make-signing-identity.sh   # once; keeps Accessibility and Screen Recording across rebuilds
swift build
swift test
./make-app.sh install
```

Download a model in the app, or point development runs at a GGUF you already have with
`YAKU_DEV_MODEL=/path/to/model.gguf`.

## Checks

A change is ready when all of these hold:

```sh
cd app
swift build            # 0 warnings
swift build -c release
swift test
```

If you changed `pdf-worker/`, run its tests with the worker's Python (the one the app installed,
or any Python 3.12 with `pdf-worker/requirements.txt` installed):

```sh
"$HOME/Library/Application Support/Yaku/pdf-worker/bin/python" -m unittest discover -s pdf-worker/tests
```

## Checking in the real app

Tests do not show a window. For anything a user can see or feel, drive the real app. The
`.agents/skills/verify-yaku/` folder holds a helper that builds the release binary, stops your
installed copy (only one instance can run), starts the app with `--demo-*` options against a private
scratch data folder, captures windows and log lines, and puts everything back:

```sh
V=.agents/skills/verify-yaku/scripts/yaku-verify
$V doctor
$V build
$V begin my-change
$V shot manager-translate WAIT=20 --demo-surface manager --demo-page translate --demo-state done
$V end                      # the evidence stays in docs/checks/shots/verify/
```

`.agents/skills/verify-yaku/features/` describes how to reach and check each feature. Run the helper
outside any sandbox; SwiftPM, `screencapture` and `open` need it.

## Code style

- Swift 6 language mode. UI code is `@MainActor`; `YakuCore` types are `Sendable` and have no UI.
- No third-party Swift packages. If one becomes necessary, explain why in the pull request first.
- UI text is Japanese. Code, comments, commit messages and these docs are English.
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

## License

By contributing you agree that your contribution is released under the [MIT License](LICENSE).
