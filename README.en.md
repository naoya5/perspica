# Perspica

Perspica is a menu-bar translator for macOS that runs entirely on your Mac. Select text anywhere and
press a key, type into a panel, drop a PDF, or point it at text on the screen. Translation runs
locally with [PLaMo 3 Translate](https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF), and
the text never leaves the Mac.

[日本語](README.md) · [Website](https://naoya5.github.io/perspica/) · Built with PLaMo

> The app's interface is in Japanese. It translates between 53 languages, with Japanese and English
> as the main pair.

The first publication will contain source code on GitHub only. Prebuilt app distribution is
planned for later. See the [task list](docs/release-tasks.md) for the remaining work.

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

There are no prebuilt downloads. You build the app from this repository, which takes a few minutes.

## Install

```sh
brew install llama.cpp
git clone https://github.com/naoya5/perspica.git
cd perspica/app
tools/make-signing-identity.sh   # once; keeps permissions across rebuilds
./make-app.sh install            # builds, signs and copies ~/Applications/Perspica.app
open ~/Applications/Perspica.app
```

`make-signing-identity.sh` creates a self-signed code-signing identity in a keychain of its own.
You can skip it; the app is then signed ad hoc, and you must grant macOS permissions again after every
rebuild. These instructions build the app for your own Mac. The app is not notarized.
Before distributing a built copy, separately check signing/notarization and the
[applicable licensing conditions](docs/release-licenses.md).

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

The three global shortcuts can be changed in **設定 > ショートカット**. Drop a PDF on the menu bar
icon, the panel, the manager window or the notch, or use Finder's **Open With**. The translated PDF
keeps the original layout and is saved next to the original (or in `~/Downloads` if that folder is
not writable).

## Permissions

Perspica asks for a permission right before the feature that needs it. If you decline, that feature
shows the reason and a button that opens System Settings.

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
- The app uses the network only to download a model from Hugging Face. PDFs are translated inside
  the app too; nothing extra is downloaded for them.
- The engine listens only on `127.0.0.1` and requires a random key that changes every launch.
- History and the translation caches stay on your Mac. Turn history off in **設定 > プライバシー**.
- Logs record what the app did and how long it took, not what you translated. Development runs
  started with `--data-dir` also log text, for debugging; set `YAKU_LOG_CONTENT=0` to turn that off.
- **設定 > プライバシー > 履歴とキャッシュを消す** erases history, the translation cache and the logs.
- Builds up to 2026-11-13 translated PDFs with a Python worker. The app deletes its leftover files
  (`Perspica/pdf-worker` and `Perspica/pdf-worker-home`) at launch. Builds before 2026-11-10 also
  let it keep a cache in `~/.cache/pdf2zh_next`. If you do not use pdf2zh-next on its own, delete
  that folder.

## Where data lives

| What | Where |
|---|---|
| Models, history and cache | `~/Library/Application Support/Perspica/` |
| Logs | `~/Library/Logs/Perspica/` (`app.log`, `engine.log`) |
| Settings | `defaults read app.perspica` |
| Database | `Perspica.store` in the Application Support folder above |
| macOS app cache, if created | `~/Library/Caches/app.perspica/` |
| Translated PDFs | Next to the original, or `~/Downloads` if that folder is not writable |

The bundle identifier is `app.perspica`; the single-instance lock is `Perspica.lock`.

### Updating from Yaku

Normal startup moves data from `~/Library/Application Support/Yaku/` and logs from
`~/Library/Logs/Yaku/` to the new folders. An on-disk journal lets the migration resume after an
interruption. Files already at the new location win; conflicting legacy files remain untouched.
The store and its sidecar files are renamed to `Perspica.store` and its sidecars.

Only known settings are copied once from `dev.naoya.yaku` to `app.perspica`, without replacing
values already in the new domain. Managed paths are updated, and the old settings remain as a backup.

The old PDF worker's Python environment cannot be relocated. It stays in the old `Yaku/` folder
as a backup. PDF translation no longer uses it.

If an old `Yaku.lock` exists, the app also uses it to prevent an old build and a new build from
running together. A clean install does not create a legacy Yaku folder. The bundle identifier has
changed, so grant macOS permissions again, including Accessibility and Screen Recording, even if
you use the same signing certificate.

Development and verification runs using `--data-dir` never migrate real data or settings. Their
logs stay in `<data-dir>/logs/`, separate from normal logs.

Swift modules and the executable (`Yaku`, `YakuCore`), `YAKU_DEV_MODEL` and the `verify-yaku` skill
keep their old names.

## Troubleshooting

| Problem | Try |
|---|---|
| The engine cannot be found | `brew install llama.cpp`. The app looks for `llama-server` in `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`. |
| ⌃⌥J does nothing | Check **System Settings > Privacy & Security > Accessibility**. After updating from Yaku or rebuilding with ad hoc signing, remove Perspica there and add it again. |
| A global key clashes with another app | Change it in **設定 > ショートカット**. |
| Anything else | Read `~/Library/Logs/Perspica/app.log`, then open an issue. |

## Uninstall

1. Quit Perspica from the menu bar menu.
2. Delete `~/Applications/Perspica.app`.
3. To remove models, history, logs and settings as well, run the following commands. This cannot
   be undone.

   ```sh
   rm -rf "$HOME/Library/Application Support/Perspica" "$HOME/Library/Logs/Perspica" \
     "$HOME/Library/Caches/app.perspica"
   defaults delete app.perspica
   ```

4. If you granted Accessibility or Screen Recording, remove Perspica from
   **System Settings > Privacy & Security**.

The commands above do not remove the old Yaku settings, the old PDF worker environment or
conflicting legacy files left by migration. If you no longer need them, inspect
`~/Library/Application Support/Yaku/` and `~/Library/Logs/Yaku/` before deleting their contents.
Remove old settings with `defaults delete dev.naoya.yaku`.

## Build from source

Run from the repository root.

```sh
cd app
swift build          # debug build, 0 warnings expected
swift test           # unit tests
./make-app.sh        # build/Perspica.app without installing
cd ..
```

[AGENTS.md](AGENTS.md) describes the code layout and the rules every change keeps.
[SPEC.md](SPEC.md) is the full design specification (in Japanese). For development runs that must
not touch your real data, start the binary with `--data-dir`, and give it a model with
`YAKU_DEV_MODEL`.

```sh
YAKU_DEV_MODEL=/path/to/model.gguf \
  app/build/Perspica.app/Contents/MacOS/Yaku --data-dir "$TMPDIR/perspica-demo" --demo-surface panel
```

## Contributing

Bug reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Report security
problems privately as described in [SECURITY.md](SECURITY.md).

## License and credits

Perspica's code is under the [MIT license](LICENSE). Polly the mascot, the app icon and the
movie are not; see [ARTWORK.md](ARTWORK.md). PDF translation is implemented in Swift on
Apple's system frameworks, with no AGPL or other third-party PDF library. The model and the engine
keep their own licenses.

Release checks are not complete. See the [release tasks](docs/release-tasks.md),
[distribution and source scope](docs/source-distribution-scope.md),
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and
[release licensing checklist](docs/release-licenses.md).

- Translation model: PLaMo 3 Translate by Preferred Networks, under the PLaMo Community License.
  Built with PLaMo.
- Engine: [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT), installed separately with
  Homebrew.
- PDF translation: Perspica's own Swift code (Core Graphics, Core Text, PDFKit). Translated PDFs
  embed subsets of the Hiragino fonts that ship with macOS.
