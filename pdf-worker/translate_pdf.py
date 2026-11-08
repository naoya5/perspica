#!/usr/bin/env python3
"""Translate a PDF into Japanese, keeping the layout, and report progress as
one JSON object per line on stdout (SPEC 8.2).

    translate_pdf.py <input.pdf> --engine-url <URL> [options]

    {"type":"progress","progress":0.42,"stage":"Translate Paragraphs"}
    {"type":"done","mono":"…","dual":"…","seconds":12.3}
    {"type":"error","message":"…"}

The paragraphs are translated by `paragraph_translator.py`, which pdf2zh-next
runs once per paragraph through `--clitranslator`. It builds the same PFML3 the
app does and posts it to the engine the app started.

The font family for the translated text comes from the source document's own
fonts (`pdf_font_family.py`), so a serif paper stays serif and a sans guide comes
back sans (M6.md 3.1). `--primary-font-family` overrides it.

The rate limit (`--qps`) is the translation speed: pdf2zh-next sleeps between
paragraphs to hold that rate (`base_translator.py`), and it also decides the
worker pool when `--pool-max-workers` is unset. The default is measured against
a 17-page document in M6.md 3.4.

pdf2zh-next and BabelDOC log to file descriptor 1, so the real stdout is kept
aside for the JSON lines and fd 1 is pointed at stderr.

The API key travels in the environment (`YAKU_ENGINE_API_KEY`), not on the
command line, and is inherited by the per-paragraph processes.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import shlex
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Take a private copy of the real stdout for the JSON lines and send everything
# else (pdf2zh-next, BabelDOC, warnings) to stderr.
_OUT = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)


def emit(**fields) -> None:
    _OUT.write(json.dumps(fields, ensure_ascii=False) + "\n")
    _OUT.flush()


def clitranslator_command(args: argparse.Namespace) -> str:
    """The command pdf2zh-next runs once per paragraph, quoted for shlex."""
    parts = [
        sys.executable,
        str(HERE / "paragraph_translator.py"),
        "--to", args.lang_out,
        "--engine-url", args.engine_url,
    ]
    if args.lang_in:
        parts += ["--from", args.lang_in]
    if args.form:
        parts += ["--form", args.form]
    if args.context:
        parts += ["--context", args.context]
    if args.glossary:
        parts += ["--glossary", args.glossary]
    return " ".join(shlex.quote(part) for part in parts)


def chosen_font_family(pdf: Path) -> str | None:
    """The font family for the translation, from the source's own fonts.

    Read from the document rather than fixed, so a serif paper stays serif and a
    sans screen guide comes back sans (M6.md 3.1). When the document gives no
    evidence the answer is sans-serif, which is what the guide measured for M6
    needs: its body is a Type 3 font with no descriptor to read, and the
    library's own fallback put the translation in a serif face.
    """
    try:
        import pdf_font_family

        answer, tally = pdf_font_family.choose(str(pdf))
        # stderr goes to the app's pdf.log (fd 1 is already pointed at it), so
        # the choice is traceable without adding a JSON event the app would
        # only ignore.
        print(f"Yaku font family: {answer} from {tally}", file=sys.stderr, flush=True)
        return answer
    except Exception as error:  # noqa: BLE001 - a guess is better than no font
        print(f"Yaku font family: could not be read ({type(error).__name__}: {error})",
              file=sys.stderr, flush=True)
        return None


async def run(args: argparse.Namespace) -> int:
    import logging

    logging.disable(logging.CRITICAL)

    from pdf2zh_next.config import ConfigManager
    from pdf2zh_next.high_level import do_translate_async_stream
    import babeldoc.assets.assets

    pdf = Path(args.pdf).resolve()
    out_dir = Path(args.output).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    argv = [
        "pdf2zh_next", str(pdf),
        "--clitranslator",
        "--clitranslator-command", clitranslator_command(args),
        "--clitranslator-timeout", str(args.clitranslator_timeout),
        "--lang-in", args.lang_in,
        "--lang-out", args.lang_out,
        "--qps", str(args.qps),
        "--pool-max-workers", str(args.pool_max_workers),
        "--no-auto-extract-glossary",
        "--watermark-output-mode", "no_watermark",
        "--output", str(out_dir),
    ]
    if args.pages:
        argv += ["--pages", args.pages]
    font_family = args.primary_font_family
    if font_family == "auto":
        font_family = chosen_font_family(pdf)
    if font_family:
        argv += ["--primary-font-family", font_family]

    sys.argv = argv
    settings = ConfigManager().initialize_config()

    emit(type="progress", progress=0.0, stage="Preparing")
    # Fetches BabelDOC's layout model and fonts on the first run (network).
    babeldoc.assets.assets.warmup()

    async for event in do_translate_async_stream(settings, pdf):
        kind = event.get("type")
        if kind in ("progress_start", "progress_update", "progress_end"):
            overall = float(event.get("overall_progress", 0) or 0)
            emit(type="progress", progress=round(overall / 100, 4), stage=event.get("stage", ""))
        elif kind == "finish":
            result = event["translate_result"]
            emit(
                type="done",
                mono=str(result.mono_pdf_path or ""),
                dual=str(result.dual_pdf_path or ""),
                seconds=round(result.total_seconds, 2),
            )
            return 0
        elif kind == "error":
            emit(type="error", message=str(event.get("error")))
            return 1
    return 1


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Yaku PDF worker")
    parser.add_argument("pdf")
    parser.add_argument("--engine-url", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--pages", default=None)
    parser.add_argument("--lang-in", default="en")
    parser.add_argument("--lang-out", default="ja")
    parser.add_argument("--form", default=None, choices=["plain", "polite"])
    parser.add_argument("--context", default=None)
    parser.add_argument("--glossary", default=None)
    parser.add_argument("--qps", type=int, default=24)
    parser.add_argument("--pool-max-workers", type=int, default=4)
    parser.add_argument("--clitranslator-timeout", type=int, default=120)
    parser.add_argument(
        "--primary-font-family",
        default="auto",
        choices=["auto", "serif", "sans-serif", "script"],
        help="font family for the translated text; `auto` reads the source PDF",
    )
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args(sys.argv[1:])
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        emit(type="error", message="cancelled")
        return 130
    except Exception as error:  # noqa: BLE001 - the app shows this message
        emit(type="error", message=f"{type(error).__name__}: {error}")
        return 1


if __name__ == "__main__":
    # Put the worker and the per-paragraph processes it starts into their own
    # process group, so the app can cancel the whole group with one signal and
    # no child is left behind (SPEC 8.2).
    try:
        os.setpgrp()
    except OSError:
        pass
    sys.exit(main())
