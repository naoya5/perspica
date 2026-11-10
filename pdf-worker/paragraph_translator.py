#!/usr/bin/env python3
"""Translate paragraphs through the running Yaku engine (SPEC 7.2 / 8.2).

`translate_pdf.py` calls `ParagraphTranslator` inside pdf2zh-next's translation
process, one call per paragraph, over one kept-alive connection per thread. Run
as a script, it translates stdin to stdout, which is what pdf2zh-next's
`--clitranslator-command` names. The prompt is the same PFML3 the app builds for
the panel and the HUD, so a PDF paragraph and a sentence typed into the panel go
through exactly the same model path.

The engine URL comes on the command line; the API key comes from the
environment (`YAKU_ENGINE_API_KEY`), never from the command line, so it cannot
be read out of a process listing. Only the standard library is used.
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import sys
import threading
import time
import urllib.parse

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


# One request's prompt and output must stay within 4,096 tokens (SPEC 7.1).
# UTF-8 bytes bound the token count from above for a byte-fallback tokenizer.
REQUEST_BUDGET = 4096
# Below this a piece is no longer split to make room for history; optional
# fields are trimmed instead.
MIN_SUBDIVIDE_BYTES = 256


def halve(source: str) -> tuple[str, str]:
    """Two contiguous halves, cut at the sentence end nearest the middle."""
    middle = len(source) // 2
    ends = [match.end() for match in re.finditer(r"[。！？]\s*|[.!?]\s+", source)
            if 0 < match.end() < len(source)]
    cut = min(ends, key=lambda end: abs(end - middle)) if ends else max(1, middle)
    return source[:cut], source[cut:]


def character_weight(character: str) -> int:
    value = ord(character)
    return 2 if any(start <= value <= end for start, end in (
        (0x3000, 0x30FF), (0x3400, 0x9FFF), (0xAC00, 0xD7AF),
        (0xF900, 0xFAFF), (0x20000, 0x2FA1F),
    )) else 1


def split_text(text: str, max_bytes: int = 1800) -> list[tuple[str, bool]]:
    """Sentence-first chunks, at most 1,200 weighted chars / `max_bytes`.

    The byte bound also covers non-CJK Unicode under the conservative token
    budget. Chunks keep intra-paragraph whitespace and rejoin without gaps.
    """
    normalized = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    chunks = []
    for paragraph in re.split(r"\n[ \t]*\n", normalized):
        if not paragraph.strip():
            continue
        group = ""
        weight = byte_count = 0
        first = True
        # Include separators in each sentence slice to preserve the source.
        for sentence in re.findall(r".*?(?:[。！？]\s*|[.!?](?:\s+|$))|.+$", paragraph, re.S):
            sentence_weight = sum(map(character_weight, sentence))
            sentence_bytes = len(sentence.encode("utf-8"))
            if group and (weight + sentence_weight > 1200 or byte_count + sentence_bytes > max_bytes):
                chunks.append((group, first))
                first = False
                group = ""
                weight = byte_count = 0
            for character in sentence:
                w = character_weight(character)
                b = len(character.encode("utf-8"))
                if group and (weight + w > 1200 or byte_count + b > max_bytes):
                    chunks.append((group, first))
                    first = False
                    group = ""
                    weight = byte_count = 0
                group += character
                weight += w
                byte_count += b
        if group:
            chunks.append((group, first))
    return chunks


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
    history: list[tuple[str, str]] | None = None,
) -> str:
    out = DATASET
    if context:
        out += "<|plamo:tag|>context<|plamo:msg|>" + sanitize(context)
    for previous_source, previous_target in (history or [])[-2:]:
        out += input_element(source_language, previous_source)
        out += output_element(target_language, None, previous_target)
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


class EngineError(Exception):
    pass


def request_body(prompt: str, source: str) -> bytes:
    body = {
        "model": "plamo-3-translate",
        "prompt": prompt,
        "temperature": 0,
        "max_tokens": max_tokens_for(source),
        "stop": STOP,
        "stream": True,
        "cache_prompt": True,
    }
    return json.dumps(body, ensure_ascii=False).encode("utf-8")


class ParagraphTranslator:
    """Translates one paragraph per call; safe to call from several threads."""

    def __init__(
        self,
        engine_url: str,
        api_key: str | None,
        target_language: str,
        source_language: str | None = None,
        form: str | None = None,
        context: str | None = None,
        glossary: list[dict] | None = None,
        timeout: float = 120,
    ):
        url = urllib.parse.urlsplit(engine_url)
        self.host = url.hostname or "127.0.0.1"
        self.port = url.port or 80
        self.path = url.path.rstrip("/") + "/v1/completions"
        self.tokenize_path = url.path.rstrip("/") + "/tokenize"
        # None until the first count: True when the engine counts, False when
        # it has no /tokenize (then only the byte bound is used).
        self._tokenizer_available: bool | None = None
        self.headers = {"Content-Type": "application/json"}
        if api_key:
            self.headers["Authorization"] = "Bearer " + api_key
        self.target_language = target_language
        self.source_language = source_language
        self.form = form
        self.context = context
        self.glossary = glossary or []
        self.timeout = timeout
        self._local = threading.local()

    @classmethod
    def from_args(cls, args: argparse.Namespace, api_key: str | None) -> "ParagraphTranslator":
        return cls(
            engine_url=args.engine_url,
            api_key=api_key,
            target_language=args.to,
            source_language=args.src,
            form=args.form,
            context=args.context,
            glossary=load_glossary(args.glossary),
        )

    def __call__(self, text: str) -> str:
        if not text.strip():
            return text
        # Counts are per call: a prompt repeats only while one paragraph is
        # being fitted, and the memory goes with the call.
        self._local.counts = {}
        try:
            return self._translate(text)
        finally:
            self._local.counts = None

    def _translate(self, text: str) -> str:
        translations = []
        history = []
        pending = split_text(text)
        if len(pending) > 1 and not self._can_count(pending[0][0]):
            # Without real counts only the byte bound is known, so pieces are
            # sized up front for two full pairs under it.
            size = self._piece_bytes(text)
            if size is not None and size < 1800:
                pending = split_text(text, max_bytes=size)
        while pending:
            source, starts_paragraph = pending.pop(0)
            context = self.context
            glossary = relevant_glossary(self.glossary, source)
            previous = history[-2:]
            prompt = build_prompt(source, self.source_language, self.target_language,
                                  self.form, context, glossary, previous)
            fit = self._fits(prompt, source)
            if (not fit and previous
                    and len(source.encode("utf-8")) > MIN_SUBDIVIDE_BYTES
                    and self._fits_with_small_piece(source, context, previous)):
                # SPEC 7.4 asks for the previous two pairs and 7.1 for the
                # 4,096 bound: a smaller piece keeps both, so split first.
                head, tail = halve(source)
                pending[:0] = [(head, starts_paragraph), (tail, False)]
                continue
            dropped = []
            while not fit:
                if previous:
                    previous = previous[1:]
                    dropped.append("history")
                elif glossary:
                    glossary = glossary[:-1]
                    dropped.append("glossary")
                elif context:
                    context = context[:len(context) // 2]
                    dropped.append("context")
                else:
                    raise EngineError("PDF paragraph exceeds the engine context window")
                prompt = build_prompt(source, self.source_language, self.target_language,
                                      self.form, context, glossary, previous)
                fit = self._fits(prompt, source)
            if dropped:
                print(f"Yaku: trimmed {', '.join(sorted(set(dropped)))} to stay within "
                      f"{REQUEST_BUDGET} tokens", file=sys.stderr, flush=True)
            translation = cleanup(self._complete(request_body(prompt, source)))
            if translations and starts_paragraph:
                translations.append("\n\n")
            translations.append(translation)
            history.append((source, translation))
        return "".join(translations)

    def _fits_with_small_piece(self, source, context, previous) -> bool:
        """Whether a short piece fits beside the full context and history, so
        splitting converges instead of only multiplying requests."""
        probe = source[:64]
        prompt = build_prompt(probe, self.source_language, self.target_language, self.form,
                              context, relevant_glossary(self.glossary, probe), previous)
        return self._fits(prompt, probe)

    def _piece_bytes(self, text: str) -> int | None:
        """The piece size that leaves room for two full history pairs.

        The history is made of earlier pieces, so it can only fit if the
        pieces are sized for it before the first request. A translation is
        assumed to be at most 1.5 bytes per source byte into Japanese (three
        UTF-8 bytes per kana or kanji) and 1 byte per byte otherwise. Returns
        None when the context and glossary leave no useful room; they are
        trimmed instead.
        """
        ratio = 1.5 if self.target_language == "ja" else 1.0
        fixed = build_prompt("", self.source_language, self.target_language, self.form,
                             self.context, relevant_glossary(self.glossary, text),
                             [("", ""), ("", "")])
        # Per piece byte: itself plus two earlier sources and translations,
        # and max_tokens of up to two thirds of its bytes.
        room = REQUEST_BUDGET - len(fixed.encode("utf-8")) - MIN_TOKENS
        size = int(room / (3 + 2 * ratio + 2 / 3))
        return size if size >= MIN_SUBDIVIDE_BYTES else None

    def _fits(self, prompt: str, source: str) -> bool:
        """SPEC 7.1: prompt (with BOS) plus max_tokens within the window.

        UTF-8 bytes bound the token count from above, so the engine is only
        asked for the real count when that cheap bound fails.
        """
        limit = REQUEST_BUDGET - max_tokens_for(source)
        if len(prompt.encode("utf-8")) + 1 <= limit:
            return True
        count = self._count_tokens(prompt)
        return count is not None and count <= limit

    def _can_count(self, source: str) -> bool:
        if self._tokenizer_available is None:
            self._count_tokens(build_prompt(source, self.source_language, self.target_language,
                                            self.form, self.context, [], []))
        return bool(self._tokenizer_available)

    def _count_tokens(self, prompt: str) -> int | None:
        """The engine's token count for `prompt`, BOS included, or None when
        the endpoint cannot count (an engine without /tokenize, or busy)."""
        if self._tokenizer_available is False:
            return None
        # One count per prompt within a call; a 503 is not kept, so a later
        # check asks again.
        known = getattr(self._local, "counts", None)
        if known is not None and prompt in known:
            return known[prompt]
        body = json.dumps({"content": prompt}, ensure_ascii=False).encode("utf-8")
        status, data = self._post(self.tokenize_path, body)
        if status == 404:
            self._tokenizer_available = False
            return None
        if status == 503:
            return None
        if status != 200:
            raise EngineError(f"tokenize HTTP {status}")
        count = json.loads(data)["count"]
        if not isinstance(count, int) or count < 0:
            raise EngineError("tokenize returned no count")
        self._tokenizer_available = True
        if known is not None:
            known[prompt] = count
        return count

    def _connection(self) -> http.client.HTTPConnection:
        connection = getattr(self._local, "connection", None)
        if connection is None:
            connection = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
            self._local.connection = connection
        return connection

    def _post(self, path: str, body: bytes) -> tuple[int, bytes]:
        connection = self._connection()
        try:
            connection.request("POST", path, body=body, headers=self.headers)
            response = connection.getresponse()
            return response.status, response.read()
        except Exception:
            connection.close()
            self._local.connection = None
            raise

    def close(self) -> None:
        """Closes the calling thread's connection."""
        connection = getattr(self._local, "connection", None)
        if connection is not None:
            connection.close()
            self._local.connection = None

    def _complete(self, body: bytes) -> str:
        connection = getattr(self._local, "connection", None)
        if connection is None:
            connection = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
            self._local.connection = connection
        try:
            connection.request("POST", self.path, body=body, headers=self.headers)
            response = connection.getresponse()
            if response.status != 200:
                response.read()
                raise EngineError(f"HTTP {response.status}")
            pieces = []
            finished = False
            for line in response:
                if not line.startswith(b"data:"):
                    continue
                payload = line[5:].strip()
                if payload == b"[DONE]":
                    finished = True
                    continue
                event = json.loads(payload)
                if "error" in event:
                    raise EngineError("Engine stream failed")
                choices = event.get("choices", [])
                if choices:
                    pieces.append(choices[0].get("text", ""))
                    finished = finished or choices[0].get("finish_reason") is not None
            if not finished:
                raise EngineError("Engine stream ended before completion")
            return "".join(pieces)
        except Exception:
            connection.close()
            self._local.connection = None
            raise


def with_retries(call, attempts: int = 3):
    """Three tries with 2 s and 4 s between, as pdf2zh-next retried the CLI."""
    for attempt in range(attempts):
        try:
            return call()
        except Exception:
            if attempt == attempts - 1:
                raise
            time.sleep(2 * (2 ** attempt))


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
    parser.add_argument("--prompt-version", choices=["2"], default="2")
    parser.add_argument("--engine-url", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    text = sys.stdin.read()
    translator = ParagraphTranslator.from_args(args, os.environ.get(API_KEY_ENV))
    try:
        translation = translator(text)
    except (OSError, http.client.HTTPException, EngineError) as error:
        sys.stderr.write(f"Yaku engine request failed: {error}\n")
        return 1
    except (KeyError, IndexError, ValueError) as error:
        sys.stderr.write(f"Yaku engine returned an unexpected body: {error}\n")
        return 1
    sys.stdout.write(translation)
    return 0


if __name__ == "__main__":
    sys.exit(main())
