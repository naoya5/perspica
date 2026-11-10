"""Exercise the worker entry point with lightweight PDF-library stand-ins."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

WORKER = pathlib.Path(__file__).resolve().parents[1] / "translate_pdf.py"

HARNESS = r'''
import asyncio, importlib.util, json, sys, types
from unittest.mock import Mock
path, output, no_dual = sys.argv[1:]
spec = importlib.util.spec_from_file_location("translate_pdf", path)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
def initialize():
    assert ("--no-dual" in sys.argv) == (no_dual == "yes")
    return object()
config = types.ModuleType("pdf2zh_next.config")
config.ConfigManager = lambda: types.SimpleNamespace(initialize_config=initialize)
async def stream(settings, pdf):
    yield {"type": "finish", "translate_result": types.SimpleNamespace(
        mono_pdf_path="mono.pdf", dual_pdf_path=None if no_dual == "yes" else "dual.pdf", total_seconds=1)}
high_level = types.ModuleType("pdf2zh_next.high_level")
high_level.do_translate_async_stream = stream
babeldoc = types.ModuleType("babeldoc")
babeldoc.assets = types.ModuleType("babeldoc.assets")
babeldoc.assets.assets = types.ModuleType("babeldoc.assets.assets")
babeldoc.assets.assets.warmup = Mock()
sys.modules.update({"pdf2zh_next.config": config, "pdf2zh_next.high_level": high_level,
    "babeldoc": babeldoc, "babeldoc.assets": babeldoc.assets,
    "babeldoc.assets.assets": babeldoc.assets.assets})
worker.use_in_process_translator = Mock()
arguments = ["input.pdf", "--engine-url", "http://127.0.0.1:1234", "--output", output,
    "--primary-font-family", "sans-serif"]
if no_dual == "yes": arguments.append("--no-dual")
args = worker.parse_args(arguments)
command = worker.clitranslator_command(args)
assert "--prompt-version 2" in command
sys.exit(asyncio.run(worker.run(args)))
'''


class WorkerOptionTests(unittest.TestCase):
    def test_dual_setting_reaches_pdf_configuration(self):
        with tempfile.TemporaryDirectory() as output:
            for no_dual in ("yes", "no"):
                with self.subTest(no_dual=no_dual):
                    result = subprocess.run([sys.executable, "-c", HARNESS,
                                             str(WORKER), output, no_dual],
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    done = json.loads(result.stdout.splitlines()[-1])
                    self.assertEqual(done["dual"], "" if no_dual == "yes" else "dual.pdf")
