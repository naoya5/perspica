# PDF translation

A dropped PDF is translated with its layout kept, by a Python worker (pdf2zh-next / BabelDOC) that calls the same local engine. The output `<name>-ja.pdf` (and optionally a side-by-side version) is written next to the source.

## Sub-features

- `pdf-queue` queues a job and shows progress in the manager PDF page.
- `pdf-output` writes the translated PDF.
- `pdf-cancel` stops a running job.
- `pdf-worker-install` installs the worker into Application Support on first use.

## How to get to it (user POV)

- Drop a PDF on the panel, the menu bar icon or the manager PDF page.
- Panel quick button 「PDF を開く…」.

## Driving it with yaku-verify

Preconditions: the worker is installed (`~/Library/Application Support/Yaku/pdf-worker/bin/python` exists) or you pass `--pdf-python <path>`. Use a disposable copy of a PDF in `/tmp`.

- **One page, fast.** Copy a PDF to `/tmp/yaku-verify-pdf/paper.pdf`. Run `$V shot pdf-job WAIT=60 --demo-pdf /tmp/yaku-verify-pdf/paper.pdf --pdf-pages 1 --demo-quit-after 120`. `--pdf-pages` is a page list, so `1` means page 1 only.
- **Proof.** `$V log 'pdf: (queued|done|failed)'` shows `pdf: done paper.pdf in …s → …-ja.pdf`, and that file exists next to the source.
- **Cancel.** Add `--demo-cancel-after 10`. The log shows the job cancelled and no worker process is left (`pgrep -f '[t]ranslate_pdf.py'` is empty; the brackets stop pgrep from matching its own shell).
- **Full timing.** `app/tools/measure-m6-pdf.sh` drives the worker without the app, so it needs no `begin`. Start a private engine (the llama-server line in `docs/checks/M6.md` 5.3, port 5199, a random `--api-key`), export `YAKU_ENGINE_URL` and `YAKU_ENGINE_API_KEY`, and run it on a copy of the 15-page attention paper. Compare against the previous code by pointing `WORKER_DIR` at `git archive <rev> pdf-worker` output, alternating the two sides. Stop the engine by its pid afterwards.

## Gotchas

- `WAIT` must cover the job. The shot is taken once, after the wait.
- Paragraphs are translated inside pdf2zh-next's spawned child (`use_in_process_translator` in `translate_pdf.py`), not one Python per paragraph. `pdf.log` says `Yaku: paragraphs are translated in process`. If that line is missing, the hook did not run and the run is back on the slow path.
- Never drop a user's real document. Work on a copy in `/tmp`.
