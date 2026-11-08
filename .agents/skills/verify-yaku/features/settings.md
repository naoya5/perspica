# Settings window

Six tabs: 一般, ショートカット, エンジン, PDF, 画面翻訳, プライバシー. The window height follows each tab's content.

## Sub-features

- `settings-tabs` shows each tab with a header, cards and footers.
- `settings-height` resizes the window to the tab's content when the tab changes.
- `settings-privacy` erases history and cache.

## How to get to it (user POV)

- ⌘, while a Yaku window is focused, or 「設定…」 in the menu bar menu.

## Driving it with yaku-verify

- **Each tab.** Run `$V shot settings-<tab> WAIT=8 --appearance light --demo-surface settings --demo-tab <tab> --demo-quit-after 60` with `<tab>` one of `一般 ショートカット エンジン PDF 画面翻訳 プライバシー`. Repeat in dark.
- **Height.** Read `$V log 'settings: window '` after each shot. The M7 heights are 一般 534, ショートカット 445, エンジン 515, PDF 554, 画面翻訳 378, プライバシー 384 (width 560).
- **PDF worker installed state.** Add `--demo-pdf-worker installed` to the PDF tab.
- **Accessibility looks.** Add `--demo-reduce-motion`, `--demo-reduce-transparency` or `--demo-increase-contrast`. These change only Yaku's drawing, not the system setting.

## Gotchas

- The PDF tab's 開発用 row shows the scratch folder path. That is expected under `--data-dir`.
- The erase button in プライバシー acts on the scratch data only, because of `--data-dir`. Still, do not click it on a real instance.
