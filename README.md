# Perspica

Perspica is a menu-bar translator for macOS that runs entirely on your Mac. Select text anywhere and
press a key, type into a panel, drop a PDF, or point it at text on the screen. Translation runs
locally with [PLaMo 3 Translate](https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF), and
the text never leaves the Mac.

[日本語の README](README.ja.md) · Built with PLaMo

> The app's interface is in Japanese. It translates between 53 languages, with Japanese and English
> as the main pair.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Use](#use)
- [Permissions](#permissions)
- [Models](#models)
- [Privacy](#privacy)
- [Where data lives](#where-data-lives)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Build from source](#build-from-source)
- [Contributing](#contributing)
- [License and credits](#license-and-credits)

## Requirements

| | |
|---|---|
| macOS | 26 or later |
| Mac | Apple silicon. The engine runs on Metal. |
| Xcode | 26 or later (Swift 6), to build the app |
| [Homebrew](https://brew.sh) `llama.cpp` | Provides `llama-server`, the translation engine |
| `uv` | Only for PDF translation; the app uses it to install the PDF worker |

There are no prebuilt downloads. You build the app from this repository, which takes a few minutes.

## Install

```sh
brew install llama.cpp uv
git clone https://github.com/naoya5/perspica.git
cd perspica/app
tools/make-signing-identity.sh   # once; keeps permissions across rebuilds
./make-app.sh install            # builds, signs and copies ~/Applications/Perspica.app
open ~/Applications/Perspica.app
```

`make-signing-identity.sh` creates a self-signed code-signing identity in a keychain of its own.
You can skip it; the app is then signed ad hoc, and macOS asks for its permissions again after every
rebuild. The app is not notarized, so build it yourself rather than passing a copy to someone else.

On first launch a short onboarding walks you through downloading a model (see [Models](#models)).

## Use

Perspica lives in the menu bar.

| Where | Key | What it does |
|---|---|---|
| Anywhere | ⌃⌥J | Translate the selected text in a small window under the selection |
| Anywhere | ⌃⌥K | Open or close the panel |
| Anywhere | ⌃⌥O | Read the text on the screen and lay the translation over it |
| Panel | ⌘↩ | Translate |
| Panel | ⌘⇧C | Copy the translation |
| Panel | ⌘D | Swap the languages |
| Panel | ⌘O | Open a PDF |
| Panel | ⌘P | Pin the panel open |
| Panel | ⌘N | Open the manager window (history, glossary, models, PDF jobs) |
| Panel, selection window | Esc | Close |

The three global keys can be changed in **Settings > ショートカット**. Drop a PDF on the menu bar
icon, the panel, the manager window or the notch, or use Finder's **Open With**. The translated PDF
keeps the original layout and is saved next to the original (or in `~/Downloads` if that folder is
not writable).

## Permissions

Perspica asks for a permission right before the feature that needs it. If you decline, that feature
shows why and a button that opens System Settings.

| Feature | Permission |
|---|---|
| ⌃⌥J (read and replace the selection) | Accessibility |
| ⌃⌥O (capture the screen) | Screen Recording |
| PDF finished notification | Notifications |

## Models

Download a model in the manager window (**モデル**). Each download is checked against a SHA-256 hash
before it is used.

| Model | Download | Memory | Notes |
|---|---|---|---|
| PLaMo 3 Translate 0.8B (Q4_K_M) | 0.57 GB | about 1.1 GB | The default. Fast. |
| PLaMo 3 Translate 2B (Q4_K_M) | 1.81 GB | about 2.3 GB | |
| PLaMo 3 Translate 8B (Q4_K_M) | 5.28 GB | about 5.8 GB | Best quality. On a 16 GB Mac, close other apps first. |

The models are released by Preferred Networks under the
[PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-en). The app
shows a summary and asks you to agree before the first download. You can also point the app at a
GGUF you already have (**モデル > 既存のファイルを使う**).

The engine starts when you first translate and stops after 10 idle minutes (configurable), so the
model does not stay in memory while you are not using it.

## Privacy

- Translation runs on your Mac. Source and translated text are not sent anywhere.
- The app uses the network only to download a model from Hugging Face and, the first time you
  translate a PDF, to install the PDF worker with `uv` (from PyPI) along with the fonts and layout
  model it needs.
- The engine listens only on `127.0.0.1` and requires a random key that changes every launch.
- History and the translation caches stay on your Mac. Turn history off in **Settings > プライバシー**.
- Logs record what the app did and how long it took, not what you translated. Development runs
  started with `--data-dir` also log text, for debugging; set `YAKU_LOG_CONTENT=0` to turn that off.
- **Settings > プライバシー > 履歴とキャッシュを消す** erases history, both translation caches (the
  app's and the PDF worker's) and the logs.
- Builds before 2026-11-10 let the PDF worker keep a cache in `~/.cache/pdf2zh_next`. If you do not
  use pdf2zh-next on its own, delete that folder.

## Where data lives

| What | Where |
|---|---|
| Models, the PDF worker, history and cache | `~/Library/Application Support/Yaku/` |
| Logs | `~/Library/Logs/Yaku/` (`app.log`, `engine.log`, `pdf.log`) |
| Settings | `defaults read dev.naoya.yaku` |
| Translated PDFs | Next to the original |

## Troubleshooting

| Problem | Try |
|---|---|
| The engine cannot be found | `brew install llama.cpp`. The app looks for `llama-server` in `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`. |
| PDF setup fails with 「uv が見つかりません」 | `brew install uv`, then drop the PDF again. |
| ⌃⌥J does nothing | Check **System Settings > Privacy & Security > Accessibility**. After an ad hoc rebuild, remove Perspica there and add it again. |
| A global key clashes with another app | Change it in **Settings > ショートカット**. |
| Anything else | Read `~/Library/Logs/Yaku/app.log`, then open an issue. |

## Uninstall

1. Quit Perspica from the menu bar menu.
2. Delete `~/Applications/Perspica.app`.
3. To remove models, history, logs and settings as well:

   ```sh
   rm -rf ~/Library/Application\ Support/Yaku ~/Library/Logs/Yaku
   defaults delete dev.naoya.yaku
   ```

4. If you granted Accessibility or Screen Recording, remove Perspica from
   **System Settings > Privacy & Security**.

## Build from source

```sh
cd app
swift build          # debug build, 0 warnings expected
swift test           # unit tests
./make-app.sh        # build/Perspica.app without installing
```

[AGENTS.md](AGENTS.md) describes the code layout and the rules every change keeps.
[SPEC.md](SPEC.md) is the full design specification (in Japanese). For development runs that must
not touch your real data, start the binary with `--data-dir`, and give it a model with
`YAKU_DEV_MODEL`:

```sh
YAKU_DEV_MODEL=/path/to/model.gguf \
  app/build/Perspica.app/Contents/MacOS/Yaku --data-dir "$TMPDIR/perspica-demo" --demo-surface panel
```

## Contributing

Bug reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Report security
problems privately as described in [SECURITY.md](SECURITY.md).

## License and credits

Perspica is released under the [MIT License](LICENSE).

- Translation model: PLaMo 3 Translate by Preferred Networks, under the PLaMo Community License.
  Built with PLaMo.
- Engine: [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT), installed separately with
  Homebrew.
- PDF translation: [pdf2zh-next](https://github.com/PDFMathTranslate/PDFMathTranslate-next) and
  [BabelDOC](https://github.com/funstory-ai/BabelDOC), with PyMuPDF; all three are AGPL-3.0. They
  are not part of this repository. The app installs them on your Mac the first time you translate a
  PDF and runs them in a separate process.
