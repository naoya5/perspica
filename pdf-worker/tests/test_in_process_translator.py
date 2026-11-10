#!/usr/bin/env python3
"""Tests for ParagraphTranslator against a local stand-in for llama-server.

    pdf-worker/.venv/bin/python -m unittest discover -s pdf-worker/tests
"""
import http.client
import http.server
import importlib.util
import json
import os
import pathlib
import signal
import subprocess
import sys
import threading
import time
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parent.parent / "paragraph_translator.py"
spec = importlib.util.spec_from_file_location("paragraph_translator", MODULE_PATH)
paragraph_translator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(paragraph_translator)


class Engine(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests: list = []
    connections: set = set()
    fail_next = False
    incomplete = False
    long_reply = None
    replies: list = []
    counts: list = []
    tokenize_status = 404
    release = threading.Event()

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        Engine.connections.add(self.client_address)
        if self.path.endswith("/tokenize"):
            self.tokenize(body)
            return
        Engine.requests.append((self.path, dict(self.headers), body))
        if Engine.fail_next:
            Engine.fail_next = False
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        reply = ("data: " + json.dumps({"choices": [{"text": "訳"}]}) + "\n\n"
                 + "data: " + json.dumps({"choices": [{"text": "文<|plamo:tag|>", "finish_reason": "stop"}]})
                 + "\n\ndata: [DONE]\n\n").encode()
        if Engine.long_reply is not None:
            # English to Japanese: about 1.5 bytes out per source byte.
            prompt = json.loads(body)["prompt"]
            piece = prompt.split("<|plamo:tag|>input")[-1].split("<|plamo:msg|>", 1)[1]
            piece = piece.split("<|plamo:tag|>")[0]
            Engine.replies.append(Engine.long_reply * max(1, len(piece.encode()) // 2))
            reply = ("data: " + json.dumps({"choices": [{"text": Engine.replies[-1],
                                                         "finish_reason": "stop"}]})
                     + "\n\ndata: [DONE]\n\n").encode()
        if Engine.incomplete:
            reply = b'data: {"choices":[{"text":"partial"}]}\n\n'
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def tokenize(self, body):
        Engine.counts.append((self.path, dict(self.headers), body))
        if Engine.tokenize_status == "hang":
            Engine.release.wait(10)
            return
        if Engine.tokenize_status == "drop":
            # The proxy or engine going away mid-count.
            self.close_connection = True
            self.connection.shutdown(2)
            return
        status = Engine.tokenize_status
        if status == 200 and self.headers.get("Authorization") != "Bearer secret":
            status = 401
        reply = b""
        if status == 200:
            content = json.loads(body)["content"]
            # Stand-in tokenizer: one per four ASCII characters, one per other
            # character, plus BOS.
            ascii_count = sum(1 for c in content if ord(c) < 128)
            count = ascii_count // 4 + (len(content) - ascii_count) + 1
            reply = json.dumps({"count": count, "tokens": [0] * count}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


class ParagraphTranslatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Engine)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        Engine.requests = []
        Engine.connections = set()
        Engine.fail_next = False
        Engine.incomplete = False
        Engine.long_reply = None
        Engine.replies = []
        Engine.counts = []
        Engine.tokenize_status = 404

    def make(self, **options):
        translator = paragraph_translator.ParagraphTranslator(self.url, "secret", "ja", **options)
        self.addCleanup(translator.close)
        return translator

    def test_sends_the_same_body_the_cli_sent(self):
        translate = self.make(source_language="en", glossary=[{"source": "attention", "target": "注意"}])
        self.assertEqual(translate("Attention is all you need."), "訳文")
        path, headers, body = Engine.requests[0]
        prompt = paragraph_translator.build_prompt(
            "Attention is all you need.", "en", "ja", None, None,
            [{"source": "attention", "target": "注意"}],
        )
        self.assertEqual(path, "/v1/completions")
        self.assertEqual(headers["Authorization"], "Bearer secret")
        self.assertEqual(body, paragraph_translator.request_body(prompt, "Attention is all you need."))

    def test_one_connection_serves_every_paragraph_of_a_thread(self):
        translate = self.make()
        for text in ["One.", "Two.", "Three."]:
            translate(text)
        self.assertEqual(len(Engine.requests), 3)
        self.assertEqual(len(Engine.connections), 1)

    def test_a_failed_request_raises_and_the_next_call_reconnects(self):
        translate = self.make()
        translate("Before.")
        Engine.fail_next = True
        with self.assertRaises(paragraph_translator.EngineError):
            translate("Fails.")
        self.assertEqual(translate("After."), "訳文")
        self.assertEqual(len(Engine.connections), 2)

    def test_blank_text_is_returned_without_a_request(self):
        self.assertEqual(self.make()("  \n"), "  \n")
        self.assertEqual(Engine.requests, [])

    def test_truncated_stream_is_not_a_successful_translation(self):
        Engine.incomplete = True
        with self.assertRaises(paragraph_translator.EngineError):
            self.make()("Hello.")

    def test_long_translations_shrink_the_next_piece_instead_of_dropping_history(self):
        # Full-size pieces and their translations leave no room for two pairs
        # of history, so later pieces are split and both previous pairs stay.
        Engine.long_reply = "訳"
        source = "word " * 1000
        result = self.make(source_language="en")(source)
        bodies = [json.loads(request[2]) for request in Engine.requests]
        self.assertGreater(len(bodies), 5)
        sources = []
        for index, body in enumerate(bodies):
            self.assertLessEqual(len(body["prompt"].encode()) + body["max_tokens"], 4096)
            inputs = body["prompt"].split("<|plamo:tag|>input")[1:]
            self.assertEqual(len(inputs), 1 + min(2, index), f"request {index}")
            sources.append(inputs[-1].split("<|plamo:msg|>", 1)[1].split("<|plamo:tag|>")[0])
        self.assertEqual("".join(sources), source.strip())
        self.assertEqual(result, "".join(Engine.replies))

    def test_long_paragraphs_stream_sequentially_with_history_and_bounded_prompts(self):
        translate = self.make(context="題" * 5000,
                              glossary=[{"source": "日", "target": "訳" * 5000}])
        self.assertEqual(translate("日" * 1800), "訳文" * 3)
        self.assertEqual(len(Engine.requests), 3)
        bodies = [json.loads(request[2]) for request in Engine.requests]
        for body in bodies:
            self.assertTrue(body["stream"])
            self.assertLessEqual(len(body["prompt"].encode()) + body["max_tokens"], 4096)
        # Without oversized optional fields, the preceding chunk is retained.
        Engine.requests = []
        self.make()("a" * 2500)
        prompts = [json.loads(request[2])["prompt"] for request in Engine.requests]
        self.assertIn("訳文", prompts[1])
        self.assertEqual(prompts[2].count("訳文"), 2)

    def test_retries_until_a_call_succeeds(self):
        calls = []

        def flaky():
            calls.append(1)
            if len(calls) < 2:
                raise OSError("refused")
            return "ok"

        original = paragraph_translator.time.sleep
        paragraph_translator.time.sleep = lambda seconds: None
        try:
            self.assertEqual(paragraph_translator.with_retries(flaky), "ok")
        finally:
            paragraph_translator.time.sleep = original
        self.assertEqual(len(calls), 2)

    def counted(self):
        """Every completion body with its stand-in token count."""
        bodies = [json.loads(request[2]) for request in Engine.requests]
        result = []
        for body in bodies:
            content = body["prompt"]
            ascii_count = sum(1 for c in content if ord(c) < 128)
            result.append((body, ascii_count // 4 + (len(content) - ascii_count) + 1))
        return result

    def test_real_counts_keep_spec_sized_pieces_and_full_history(self):
        Engine.tokenize_status = 200
        Engine.long_reply = "訳"
        source = "word " * 1000
        result = self.make(source_language="en")(source)
        counted = self.counted()
        # Same pieces as the 1,200-character split: no byte-driven shrinking.
        self.assertEqual(len(counted), len(paragraph_translator.split_text(source)))
        over_bytes = 0
        for index, (body, tokens) in enumerate(counted):
            self.assertLessEqual(tokens + body["max_tokens"], 4096)
            over_bytes += len(body["prompt"].encode()) + 1 + body["max_tokens"] > 4096
            self.assertEqual(body["prompt"].count("<|plamo:tag|>input"), 1 + min(2, index))
        self.assertGreater(over_bytes, 0, "the byte bound alone would have shrunk these")
        sources = [body["prompt"].split("<|plamo:tag|>input")[-1].split("<|plamo:msg|>", 1)[1]
                   .split("<|plamo:tag|>")[0] for body, _ in counted]
        self.assertEqual("".join(sources), source.strip())
        self.assertEqual(result, "".join(Engine.replies))
        contents = [json.loads(body)["content"] for _, _, body in Engine.counts]
        self.assertEqual(len(contents), len(set(contents)), "a prompt was counted twice")
        for path, headers, body in Engine.counts:
            self.assertEqual(path, "/tokenize")
            self.assertEqual(headers["Authorization"], "Bearer secret")
            self.assertEqual(set(json.loads(body)), {"content"})

    def test_short_text_is_not_counted(self):
        Engine.tokenize_status = 200
        self.make()("Attention is all you need.")
        self.assertEqual(Engine.counts, [])
        self.assertEqual(len(Engine.requests), 1)

    def test_a_rejected_key_on_tokenize_fails_without_a_completion(self):
        Engine.tokenize_status = 200
        translator = paragraph_translator.ParagraphTranslator(self.url, "wrong", "ja")
        self.addCleanup(translator.close)
        with self.assertRaises(paragraph_translator.EngineError):
            translator("word " * 1000)
        self.assertEqual(Engine.requests, [])

    def test_an_engine_that_cannot_count_falls_back_to_the_byte_bound(self):
        for status in (404, 503):
            with self.subTest(status=status):
                Engine.requests, Engine.counts, Engine.replies = [], [], []
                Engine.tokenize_status = status
                Engine.long_reply = "訳"
                source = "word " * 1000
                self.make(source_language="en")(source)
                counted = self.counted()
                self.assertGreater(len(counted), len(paragraph_translator.split_text(source)))
                for index, (body, _) in enumerate(counted):
                    self.assertLessEqual(len(body["prompt"].encode()) + 1 + body["max_tokens"], 4096)
                    self.assertEqual(body["prompt"].count("<|plamo:tag|>input"), 1 + min(2, index))
                if status == 404:
                    self.assertEqual(len(Engine.counts), 1, "a missing endpoint is asked once")

    def test_a_count_cut_off_mid_request_fails_without_a_completion(self):
        Engine.tokenize_status = "drop"
        with self.assertRaises((OSError, http.client.HTTPException)):
            self.make()("word " * 1000)
        self.assertEqual(Engine.requests, [])
    def test_cancel_while_counting_stops_the_translator_with_no_output(self):
        # The app cancels with SIGTERM to the worker's group (SPEC 8.2).
        Engine.tokenize_status = "hang"
        Engine.release.clear()
        self.addCleanup(Engine.release.set)
        process = subprocess.Popen(
            [sys.executable, str(MODULE_PATH), "--engine-url", self.url, "--from", "en"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={**os.environ, paragraph_translator.API_KEY_ENV: "secret"},
        )
        process.stdin.write(("word " * 1000).encode())
        process.stdin.close()
        deadline = time.monotonic() + 10
        while not Engine.counts and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(Engine.counts, "the translator never asked for a count")
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=3), -signal.SIGTERM)
        self.assertEqual(process.stdout.read(), b"")
        process.stdout.close()
        process.stderr.close()
        self.assertEqual(Engine.requests, [])
    def test_a_busy_count_is_asked_again_and_a_good_one_is_kept(self):
        translator = self.make()
        translator._local.counts = {}
        Engine.tokenize_status = 503
        self.assertIsNone(translator._count_tokens("prompt"))
        self.assertIsNone(translator._count_tokens("prompt"))
        self.assertEqual(len(Engine.counts), 2)
        Engine.tokenize_status = 200
        first = translator._count_tokens("prompt")
        self.assertEqual(translator._count_tokens("prompt"), first)
        self.assertEqual(len(Engine.counts), 3)


if __name__ == "__main__":
    unittest.main()
