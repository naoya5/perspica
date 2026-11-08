# Manager window

The manager is a normal window with a sidebar: 翻訳, PDF, 履歴, 用語集, モデル. The sidebar foot shows the engine state.

## Sub-features

- `manager-history` lists past translations with direction and relative time, and opens one in the detail pane.
- `manager-glossary` edits terms and imports or exports them.
- `manager-models` lists the three PLaMo models with one status badge each, and asks for the licence before a download.
- `manager-pdf` lists PDF jobs (see pdf.md).

## How to get to it (user POV)

- Panel quick button 「履歴」.
- Menu bar menu 「管理画面を開く」.

## Driving it with yaku-verify

- **Each page.** Run `$V shot manager-<page> WAIT=10 --appearance light --demo-surface manager --demo-page <page> --demo-quit-after 60`, where `<page>` is `history`, `glossary`, `models` or `pdf`. Repeat with `--appearance dark`.
- **Licence sheet.** Run `$V shot manager-license WAIT=10 --demo-surface manager --demo-page models --demo-download 0.8b --demo-download-gate --demo-quit-after 60`. The sheet `PLaMo Community License` appears with `同意して取得する`. Nothing is downloaded.
- **Layout check.** In every page the right edge of the content keeps the same 20 pt margin as the left. The sidebar is about 196 pt. The 2026-11-08 review found HSplitView pushing the right pane 15 pt out of the window, so compare with `M7-manager-*.png`.

## Gotchas

- History in a fresh scratch folder is empty. Translate first (translate.md), or the page shows the empty-state placeholder.
- History search fetches the newest 1000 rows and filters them in memory, while up to 5000 are kept. A search can miss older matches (perf review 2026-11-09).
- `--demo-download` without `--demo-download-gate` really downloads a multi-GB model. Do not use it for verification.
