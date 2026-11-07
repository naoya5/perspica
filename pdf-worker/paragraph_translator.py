#!/usr/bin/env python3
"""Translate one paragraph through the running Yaku engine (SPEC 7.2 / 8.2).

BabelDOC (through pdf2zh-next's `--clitranslator`) runs this once per paragraph:
the source arrives on stdin and the translation is read from stdout. The prompt
is the same PFML3 the app builds for the panel and the HUD, so a PDF paragraph
and a sentence typed into the panel go through exactly the same model path.

The engine URL comes on the command line; the API key comes from the
environment (`YAKU_ENGINE_API_KEY`), never from the command line, so it cannot
be read out of a process listing.

Only the standard library is used: one process is started per paragraph, so the
imports have to stay light.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

# --- PFML3 (kept identical to YakuCore/PFML3.swift) -------------------------

DATASET = "<|plamo:tag|>dataset<|plamo:msg|>translation"
STOP = ["<|plamo:tag|>", "<|plamo:bos|>"]
MIN_TOKENS = 256
MAX_TOKENS = 2048
API_KEY_ENV = "YAKU_ENGINE_API_KEY"


def sanitize(text: str) -> str:
    """Strips any `<|plamo:` prefix so source text cannot inject a token."""
    return text.replace("<|plamo:", "")


def estimate_tokens(text: str) -> int:
    """Same rough count as YakuCore's TokenEstimator."""
    ascii_count = 0
    wide = 0
    for character in text:
        if ord(character) < 128:
            ascii_count += 1
        else:
            wide += 1
    return ascii_count // 4 + wide


def max_tokens_for(source: str) -> int:
    return min(MAX_TOKENS, max(MIN_TOKENS, estimate_tokens(source) * 2))


def relevant_glossary(glossary: list[dict], text: str) -> list[dict]:
    """Only the entries whose source term appears in this paragraph (SPEC 5.2)."""
    haystack = text.lower()
    seen: set[str] = set()
    result: list[dict] = []
    for pair in glossary:
        needle = pair["source"].strip().lower()
        if not needle or needle in seen or needle not in haystack:
            continue
        seen.add(needle)
        result.append(pair)
    return result


def input_element(language: str | None, body: str) -> str:
    element = "<|plamo:tag|>input"
    if language:
        element += "<|plamo:key|>lang<|plamo:val|>" + language
    return element + "<|plamo:msg|>" + sanitize(body)


def output_element(language: str, form: str | None, body: str) -> str:
    element = "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + language
    # `form` only applies to Japanese output (model card).
    if form and language == "ja":
        element += "<|plamo:key|>form<|plamo:val|>" + form
    return element + "<|plamo:msg|>" + sanitize(body)


def build_prompt(
    source: str,
    source_language: str | None,
    target_language: str,
    form: str | None,
    context: str | None,
    glossary: list[dict],
) -> str:
    out = DATASET
    if context:
        out += "<|plamo:tag|>context<|plamo:msg|>" + sanitize(context)
    if glossary:
        out += "<|plamo:tag|>glossary"
        for pair in glossary:
            out += "<|plamo:index|>" + sanitize(pair["source"])
            out += "<|plamo:item|>" + sanitize(pair["target"])
    out += input_element(source_language, source)
    out += output_element(target_language, form, "")
    return out


def cleanup(text: str) -> str:
    """Removes the special tokens the model can leave at the end."""
    result = text
    while True:
        before = result
        for token in STOP:
            if result.endswith(token):
                result = result[: -len(token)]
        result = result.rstrip()
        if result == before:
            return result


# --- engine call ------------------------------------------------------------


def translate(prompt: str, source: str, engine_url: str, api_key: str | None) -> str:
    body = {
        "model": "plamo-3-translate",
        "prompt": prompt,
        "temperature": 0,
        "max_tokens": max_tokens_for(source),
        "stop": STOP,
        "stream": False,
        "cache_prompt": True,
    }
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    request = urllib.request.Request(
        engine_url.rstrip("/") + "/v1/completions",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        payload = json.load(response)
    return cleanup(payload["choices"][0]["text"])


# --- entry point ------------------------------------------------------------


def load_glossary(path: str | None) -> list[dict]:
    if not path:
        return []
    with open(path, encoding="utf-8") as handle:
        rows = json.load(handle)
    pairs: list[dict] = []
    for row in rows:
        source = str(row.get("source", "")).strip()
        target = str(row.get("target", "")).strip()
        if source:
            pairs.append({"source": source, "target": target})
    return pairs


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Yaku PDF paragraph translator")
    parser.add_argument("--to", default="ja")
    parser.add_argument("--from", dest="src", default=None)
    parser.add_argument("--form", default=None, choices=["plain", "polite"])
    parser.add_argument("--context", default=None)
    parser.add_argument("--glossary", default=None)
    parser.add_argument("--engine-url", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    text = sys.stdin.read()
    if not text.strip():
        sys.stdout.write(text)
        return 0

    glossary = relevant_glossary(load_glossary(args.glossary), text)
    prompt = build_prompt(
        source=text,
        source_language=args.src,
        target_language=args.to,
        form=args.form,
        context=args.context,
        glossary=glossary,
    )
    try:
        translation = translate(prompt, text, args.engine_url, os.environ.get(API_KEY_ENV))
    except urllib.error.URLError as error:
        sys.stderr.write(f"Yaku engine request failed: {error}\n")
        return 1
    except (KeyError, IndexError, ValueError) as error:
        sys.stderr.write(f"Yaku engine returned an unexpected body: {error}\n")
        return 1

    sys.stdout.write(translation)
    return 0


if __name__ == "__main__":
    sys.exit(main())
