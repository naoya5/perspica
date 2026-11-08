#!/usr/bin/env python3
"""Tests for the PDF font-family choice (SPEC 8.2, M6.md 3.1).

    pdf-worker/.venv/bin/python -m unittest discover -s pdf-worker/tests

`choose` needs a real PDF and pymupdf, so these tests build their documents with
pymupdf rather than mocking it: the question is whether the evidence in a
document is read correctly, and a mock would only test the mock. The module is
loaded by path because `pdf_font_family.py` is a standalone script.
"""
import importlib.util
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("pdf_font_family", HERE / "pdf_font_family.py")
pdf_font_family = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pdf_font_family)

try:
    import pymupdf
except ImportError:  # pragma: no cover - the worker environment always has it
    pymupdf = None

BODY = (
    "The dominant sequence transduction models are based on complex recurrent or "
    "convolutional neural networks that include an encoder and a decoder. "
)


def build(fontname: str, directory: str, lines: int = 12) -> str:
    """A one-page PDF whose body is drawn in `fontname`."""
    document = pymupdf.open()
    page = document.new_page()
    y = 72.0
    for _ in range(lines):
        page.insert_text((72, y), BODY[:96], fontname=fontname, fontsize=11)
        y += 14
    path = pathlib.Path(directory) / f"{fontname}.pdf"
    document.save(path)
    document.close()
    return str(path)


@unittest.skipIf(pymupdf is None, "pymupdf is not installed")
class FontFamilyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="yaku-font-")

    def test_a_serif_body_chooses_serif(self):
        # The paper case: an Attention-style document must stay serif.
        answer, tally = pdf_font_family.choose(build("Times-Roman", self.directory))
        self.assertEqual(answer, "serif")
        self.assertEqual(tally["sans-serif"], 0)
        self.assertGreater(tally["serif"], 0)

    def test_a_sans_body_chooses_sans_serif(self):
        answer, tally = pdf_font_family.choose(build("Helvetica", self.directory))
        self.assertEqual(answer, "sans-serif")
        self.assertEqual(tally["serif"], 0)

    def test_a_monospaced_body_falls_back_to_the_default(self):
        # A code listing says nothing about serif or sans, so the default
        # decides rather than a coin toss between the two.
        answer, _ = pdf_font_family.choose(build("Courier", self.directory))
        self.assertEqual(answer, pdf_font_family.DEFAULT)

    def test_an_empty_document_uses_the_default(self):
        document = pymupdf.open()
        document.new_page()
        path = pathlib.Path(self.directory) / "empty.pdf"
        document.save(path)
        document.close()
        answer, tally = pdf_font_family.choose(str(path))
        self.assertEqual(answer, pdf_font_family.DEFAULT)
        self.assertEqual(tally["serif"] + tally["sans-serif"], 0)

    def test_a_missing_file_raises(self):
        with self.assertRaises(Exception):
            pdf_font_family.choose(str(pathlib.Path(self.directory) / "nope.pdf"))


class FontNameTests(unittest.TestCase):
    def test_names_that_say_serif(self):
        for name in ("Times-Roman", "Source Han Serif JP", "Georgia-Bold", "ヒラギノ明朝"):
            self.assertEqual(pdf_font_family._name_says(name), "serif", name)

    def test_names_that_say_sans(self):
        for name in ("Helvetica", "DotoBlack-Black", "Source Han Sans JP", "ヒラギノ角ゴ"):
            self.assertEqual(pdf_font_family._name_says(name), "sans-serif", name)

    def test_a_name_that_says_nothing(self):
        for name in ("Unnamed-T3", "", "ABCDEF+F0"):
            self.assertIsNone(pdf_font_family._name_says(name), name)

    def test_the_more_specific_name_wins(self):
        # "Source Han Serif" contains both "source han" and "serif"; the serif
        # list is checked first, so it is not read as a sans.
        self.assertEqual(pdf_font_family._name_says("SourceHanSerifJP-Regular"), "serif")

    def test_span_names_match_their_subset_entries(self):
        # `get_fonts` reports "CAAAAA+DotoBlack-Black", a span says
        # "DotoBlack-Black".
        self.assertTrue(pdf_font_family._matches("CAAAAA+DotoBlack-Black", "DotoBlack-Black"))
        self.assertTrue(pdf_font_family._matches("DotoBlack-Black", "DotoBlack-Black"))
        self.assertFalse(pdf_font_family._matches("CAAAAA+DotoBlack-Black", "Helvetica"))
        self.assertFalse(pdf_font_family._matches("", "Helvetica"))


if __name__ == "__main__":
    unittest.main()
