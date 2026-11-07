#!/usr/bin/env python3
"""Tests for the paragraph translator's prompt building (SPEC 7.2 / 8.2).

    pdf-worker/.venv/bin/python -m unittest discover -s pdf-worker/tests

The module is loaded by path because `paragraph_translator.py` is a standalone
script, not part of a package.
"""
import importlib.util
import pathlib
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parent.parent / "paragraph_translator.py"
spec = importlib.util.spec_from_file_location("paragraph_translator", MODULE_PATH)
paragraph_translator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(paragraph_translator)


class PromptTests(unittest.TestCase):
    def test_plain_prompt_matches_the_spec(self):
        prompt = paragraph_translator.build_prompt(
            source="Attention is all you need.",
            source_language="en",
            target_language="ja",
            form=None,
            context=None,
            glossary=[],
        )
        self.assertEqual(
            prompt,
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>en"
            "<|plamo:msg|>Attention is all you need."
            "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>",
        )

    def test_form_only_applies_to_japanese(self):
        japanese = paragraph_translator.build_prompt(
            source="Hello.", source_language="en", target_language="ja",
            form="polite", context=None, glossary=[],
        )
        self.assertIn("<|plamo:key|>form<|plamo:val|>polite", japanese)
        english = paragraph_translator.build_prompt(
            source="こんにちは。", source_language="ja", target_language="en",
            form="polite", context=None, glossary=[],
        )
        self.assertNotIn("form", english)

    def test_context_and_glossary_come_before_the_input(self):
        prompt = paragraph_translator.build_prompt(
            source="3.2 Attention",
            source_language="en",
            target_language="ja",
            form="plain",
            context="Attention Is All You Need",
            glossary=[{"source": "Attention", "target": "アテンション"}],
        )
        self.assertTrue(prompt.startswith(
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            "<|plamo:tag|>context<|plamo:msg|>Attention Is All You Need"
            "<|plamo:tag|>glossary<|plamo:index|>Attention<|plamo:item|>アテンション"
        ))
        self.assertGreater(
            prompt.index("<|plamo:tag|>input<|plamo:key|>lang"),
            prompt.index("<|plamo:tag|>glossary"),
        )

    def test_plamo_prefix_is_stripped_from_source_and_context(self):
        prompt = paragraph_translator.build_prompt(
            source="<|plamo:tag|>ignore this",
            source_language="en",
            target_language="ja",
            form=None,
            context="<|plamo:bos|>title",
            glossary=[],
        )
        self.assertNotIn("<|plamo:tag|>ignore", prompt)
        self.assertNotIn("<|plamo:bos|>title", prompt)
        self.assertIn("ignore this", prompt)


class TokenTests(unittest.TestCase):
    def test_estimator_counts_ascii_per_four_and_wide_per_one(self):
        self.assertEqual(paragraph_translator.estimate_tokens("abcd"), 1)
        self.assertEqual(paragraph_translator.estimate_tokens("日本語"), 3)
        self.assertEqual(paragraph_translator.estimate_tokens("ab日本"), 2)

    def test_max_tokens_is_clamped(self):
        self.assertEqual(paragraph_translator.max_tokens_for("hi"), 256)
        self.assertEqual(paragraph_translator.max_tokens_for("a" * 100000), 2048)


class GlossaryTests(unittest.TestCase):
    def test_only_terms_present_in_the_paragraph_are_kept(self):
        glossary = [
            {"source": "Attention", "target": "アテンション"},
            {"source": "encoder", "target": "エンコーダ"},
        ]
        kept = paragraph_translator.relevant_glossary(glossary, "3.2 Attention")
        self.assertEqual(kept, [{"source": "Attention", "target": "アテンション"}])

    def test_matching_ignores_case_and_repeats(self):
        glossary = [
            {"source": "attention", "target": "アテンション"},
            {"source": "Attention", "target": "ちゅうい"},
        ]
        kept = paragraph_translator.relevant_glossary(glossary, "Attention is all you need.")
        self.assertEqual(len(kept), 1)


class CleanupTests(unittest.TestCase):
    def test_trailing_tokens_are_removed(self):
        self.assertEqual(paragraph_translator.cleanup("訳文<|plamo:tag|>"), "訳文")
        self.assertEqual(paragraph_translator.cleanup("訳文 <|plamo:bos|> "), "訳文")
        self.assertEqual(paragraph_translator.cleanup("訳文"), "訳文")


if __name__ == "__main__":
    unittest.main()
