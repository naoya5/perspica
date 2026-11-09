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
- **Layout check.** In every page the right edge of the content keeps the same 20 pt margin as the left. The sidebar is about 196 pt. An `HSplitView` inside the window once pushed the right pane 15 pt out of the window, so check the right margin in every page.

## Gotchas

- History in a fresh scratch folder is empty. Translate first (translate.md), or the page shows the empty-state placeholder.
- History search runs in the store and reaches all kept rows (up to 5000). `--demo-search "<語>"` types into the search field, and the log says `history: search matched N row(s)`. To prove it reaches old rows, seed more than 1000 rows into the scratch `Yaku.store` (table `ZHISTORYITEM`, `Z_ENT` from `Z_PRIMARYKEY`, then raise `Z_MAX`) and search for a word only the oldest row has.
- `--demo-download` without `--demo-download-gate` really downloads a multi-GB model. Do not use it for verification.
