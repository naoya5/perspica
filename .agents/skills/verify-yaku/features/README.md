# Yaku verification map

This directory is the maintained source for verifying what a Yaku user can do. Read this index, then use the matching feature file as the recipe. A proof that drives one convenient entry point is incomplete when a feature file lists others; say which entry points you covered.

| Feature | File | User entry points |
|---|---|---|
| Text translation and the engine | [translate.md](translate.md) | panel input, manager 翻訳 page, headless `--demo-translate` |
| Menu bar panel and HUD | [panel-hud.md](panel-hud.md) | menu bar icon, ⌃⌥K, ⌃⌥J on selected text |
| Manager window | [manager.md](manager.md) | panel 「履歴」, menu 「管理画面を開く」 |
| Settings window | [settings.md](settings.md) | ⌘, or menu 「設定…」 |
| PDF translation | [pdf.md](pdf.md) | drop on the panel or icon, manager PDF page, 「PDF を開く…」 |
| Screen translation | [screen.md](screen.md) | ⌃⌥O, panel 「画面を翻訳」 |

## Baseline preconditions

- `$V doctor` prints `doctor: ready` (with `V=.agents/skills/verify-yaku/scripts/yaku-verify`).
- `$V begin <run-name>` has run. It stopped the installed app and created the evidence folder.
- Every instance uses the helper's scratch `--data-dir`. Never point a run at `~/Library/Application Support/Yaku`.

## Driving conventions

- Start each instance through `$V shot`, `$V cpu` or `$V translate`, never by hand, so its pid is recorded and `end` can stop it.
- Hotkeys and clicks need a human. Use the `--demo-*` option that the feature file names as the stand-in. Each option opens the same window through the same code path, and the app logs the same line.
- Give every run `--demo-quit-after` with a value longer than the wait.

## Proof and skip reporting

- Report the feature, the entry point, the exact command and the artifact paths.
- A visual change needs light and dark (`--appearance`), compared with the matching earlier milestone picture in `docs/checks/shots/`.
- A behaviour change needs the log line that proves it, read from the run's `*.log`, not from the shared app log.
- A path you could not drive (hotkey, VoiceOver, permission prompts, a locked screen) is reported as not verified, with the reason.
