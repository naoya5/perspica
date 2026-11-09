# Screen translation

⌃⌥O dims the screen and offers ウィンドウ | 範囲 | 画面全体. Yaku reads the text with Vision and lays the translation over the original, block by block.

## Sub-features

- `screen-picker` chooses a window, a region or the whole screen.
- `screen-ocr` reads and groups the text into blocks.
- `screen-overlay` draws each translation over its block.
- `screen-permission` asks for Screen Recording the first time.

## How to get to it (user POV)

- Press ⌃⌥O, or the panel quick button 「画面を翻訳 ⌃⌥O」.

## Driving it with yaku-verify

- **Samples.** Build the sample pages once with `swift app/tools/make-samples.swift $TMPDIR/yaku-samples`. They are `article`, `columns`, `ui`, a mixed-language page and a bulleted doc page.
- **Overlay.** Run `$V shot overlay-article WAIT=12 --demo-image $TMPDIR/yaku-samples/article.png --demo-quit-after 40`. The picture is drawn in a window and the translation is laid over it through the real OCR and overlay path.
- **Blocks only.** The JSON goes to stdout, which the helper discards, so run the binary directly inside a `$V begin` / `$V end` pair: `app/.build/arm64-apple-macosx/release/Yaku --data-dir <state>/data --demo-image $TMPDIR/yaku-samples/article.png --demo-dump-blocks > "<evidence folder>/blocks.json"`. It exits on its own. This checks the grouping without judging pixels.
- **Picker.** Run `$V shot overlay-picker WAIT=6 --demo-surface overlay-picker --demo-quit-after 40`.
- **Timing.** The log has the first-block and all-blocks times. Baseline: first block 0.36-0.61 s, Vision alone 0.32-0.56 s (measured 2026-11-07/08 on an M-series MacBook).

## Gotchas

- A real ⌃⌥O needs Screen Recording permission for the installed app, not the release binary. The demo image path avoids the permission.
- Code-like lines are left untranslated on purpose (`CodeLikeText`). Do not report them as misses.
