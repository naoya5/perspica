#!/usr/bin/env python3
"""Tests for ParagraphTranslator against a local stand-in for llama-server.

    pdf-worker/.venv/bin/python -m unittest discover -s pdf-worker/tests
"""
import http.server
import importlib.util
import json
import pathlib
import threading
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

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        Engine.requests.append((self.path, dict(self.headers), body))
        Engine.connections.add(self.client_address)
        if Engine.fail_next:
            Engine.fail_next = False
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        reply = json.dumps({"choices": [{"text": "訳文<|plamo:tag|>"}]}).encode()
        self.send_response(200)
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


if __name__ == "__main__":
    unittest.main()
