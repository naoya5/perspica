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
    parser.add_argument("--qps", type=int, default=3)
    parser.add_argument("--pool-max-workers", type=int, default=3)
    parser.add_argument("--clitranslator-timeout", type=int, default=120)
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
