# PDF translation

A dropped PDF is translated inside the app with its layout kept (`app/Sources/YakuCore/NativePDF`): the content stream is read, glyphs are grouped into paragraphs, paragraphs go to the same local engine at PDF priority, the translated paragraphs' text operators are removed and the Japanese is typeset into their boxes. Inline formulas are kept as the original glyphs. The outputs `<name>.ja.pdf` and, when 「対訳版も作る」 is on, `<name>.ja.対訳.pdf` (original left, translation right) are written next to the source.

## Sub-features

- `pdf-queue` queues a job and shows progress in the manager PDF page.
- `pdf-output` writes the translated PDF (and the side-by-side one).
- `pdf-cancel` stops a running job.

## How to get to it (user POV)

- Drop a PDF on the panel, the menu bar icon or the manager PDF page.
- Panel quick button 「PDF を開く…」.

## Driving it with yaku-verify

Use a disposable copy of a public PDF in a private temporary folder. The Attention paper (https://arxiv.org/pdf/1706.03762v7, single column) is the reference: put it at `fixtures/attention.pdf` in the repository root (not committed). For two-column layouts use the ResNet paper (https://arxiv.org/pdf/1512.03385v1) as `fixtures/resnet.pdf`; `YAKU_TEST_PDF=<path>` points the engine run and `NativePDFDebugDump` at it.

- **One page, fast.** Copy the PDF to `$TMPDIR/yaku-verify-pdf/paper.pdf`. Run `$V run pdf-job WAIT=40 --demo-pdf $TMPDIR/yaku-verify-pdf/paper.pdf --pdf-pages 4 --demo-quit-after 90`. `--pdf-pages` is a 1-based page list (`1,3-5`), so `4` means page 4 only; the other pages are copied unchanged.
- **Proof.** `$V log 'pdf:'` shows `pdf: N paragraphs, M left as they were, K formula fallback(s)` and `pdf: done paper.pdf in …s → …paper.ja.pdf`, and the files exist next to the source. Render pages to PNG (PDFKit `PDFPage.thumbnail(of:for:)`) and look at them: body text replaced, figures and display formulas untouched, inline formulas in place, no English left under the Japanese.
- **Full timing.** Without `--pdf-pages` the 15-page paper must finish in under 120 s (SPEC 14). Measured 2026-11-14 with the 0.8B model: 74 s.
- **Cancel.** Add `--demo-cancel-after 10`. The log shows `pdf: cancelled`.

## Without the app

`swift test --filter NativePDFTranslatorTests` runs the whole pipeline with a fake engine. For a real one, start a private engine (`LLAMA_API_KEY=<random> llama-server -m "$YAKU_DEV_MODEL" -c 16384 --parallel 4 -ngl 99 -fa on --host 127.0.0.1 --port 5199 --alias plamo-3-translate --no-webui --log-disable &`, stop it by its pid afterwards). With `YAKU_TEST_ENGINE_URL=http://127.0.0.1:5199` and `YAKU_TEST_ENGINE_KEY` set, `translatesWithTheRealEngine` translates the whole paper (`YAKU_TEST_PAGES=0,3` limits it) and prints the time and output path. `YAKU_DEBUG_PAGE=<0-based page> swift test --filter NativePDFDebugDump` prints how a page was split into paragraphs (role, translate or not, bounds, text with formulas in braces).

## Gotchas

- `WAIT` must cover the job. The capture is taken once, after the wait.
- Never drop a user's real document. Work on a copy under `$TMPDIR`.
- The PDF translator is clean room: do not read or port another PDF library's source while fixing it.
