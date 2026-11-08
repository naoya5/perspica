#!/usr/bin/env python3
"""Choose the font family for a translated PDF from the source document's own
fonts (SPEC 8.2, M6.md 3.1).

`pdf2zh-next` takes `--primary-font-family serif|sans-serif|script`. Left unset
it picks per character from the original font's `is_serif` flag, which is the
right idea and the wrong evidence here: the guide this was measured on draws its
body text with a **Type 3** font, and a Type 3 font has no font descriptor, so
`pymupdf.Font.is_serif` cannot read a flag and the library falls back to a
serif face. The guide is a geometric sans, and the translation came back in a
serif (M6.md 3.1).

So the family is decided here, from two pieces of evidence, in order:

1. the serif flag of each font, when the font has one, and
2. the font's **name**, which Type 3 fonts do not help with but almost every
   other PDF does.

Both are weighted by how many characters the document actually draws with that
font, so the body face decides and a decorative heading does not. When nothing
says either way, the answer is **sans-serif**: a screen-oriented document and a
Japanese translation both read better in a gothic face, and that is the
direction the measured document went.

Only the standard library plus pymupdf, which BabelDOC already requires.
"""
from __future__ import annotations

# Names that say "serif" or "sans" outright. Checked case-insensitively against
# the font's name, longest first, so "Source Han Serif" beats "Source Han".
SERIF_NAMES = (
    "serif", "times", "georgia", "garamond", "baskerville", "palatino",
    "cambria", "minion", "charter", "book antiqua", "bookman", "didot",
    "bodoni", "century schoolbook", "liberation serif", "dejavu serif",
    "noto serif", "source han serif", "songti", "simsun", "ms mincho",
    "hiragino mincho", "yu mincho", "ipaex mincho", "ipam", "ヒラギノ明朝",
    "明朝", "宋体",
)
SANS_NAMES = (
    "sans", "helvetica", "arial", "roboto", "inter", "lato", "open sans",
    "noto sans", "source han sans", "source sans", "segoe", "verdana",
    "tahoma", "calibri", "futura", "gill sans", "avenir", "montserrat",
    "poppins", "ubuntu", "dejavu sans", "liberation sans", "pingfang",
    "heiti", "hiragino kaku", "hiragino sans", "yu gothic", "meiryo",
    "ipaex gothic", "ipag", "ゴシック", "角ゴ", "黑体", "微软雅黑",
    "doto", "space grotesk", "work sans",
)

SERIF = "serif"
SANS_SERIF = "sans-serif"
DEFAULT = SANS_SERIF


def _name_says(font_name: str) -> str | None:
    """What the font's own name says, or None when it says nothing."""
    lowered = (font_name or "").lower()
    if not lowered:
        return None
    for needle in SERIF_NAMES:
        if needle in lowered:
            return SERIF
    for needle in SANS_NAMES:
        if needle in lowered:
            return SANS_SERIF
    return None


def _font_flags(document, xref: int, basefont: str, font_type: str) -> tuple[bool, bool] | None:
    """(is_serif, is_monospaced) from the font's own descriptor, or None.

    A **Type 3** font gives None even though `pymupdf` will answer: its glyphs
    are drawing programs, there is no font descriptor, and the flag it reports is
    the enum's default rather than anything read from the document. The guide
    measured for M6.md 3.1 draws its whole body in a Type 3 font that reports
    `is_serif=True` while being a geometric sans, so trusting that answer is what
    put the translation in a serif face. A font whose bytes cannot be read also
    gives None.
    """
    if "type3" in (font_type or "").lower():
        return None
    try:
        import pymupdf
    except ImportError:
        return None
    try:
        content = document.extract_font(xref)[3]
        if not content:
            return None
        font = pymupdf.Font(fontbuffer=content)
        return (bool(font.is_serif), bool(font.is_monospaced))
    except Exception:
        return None


def _matches(basefont: str, span_name: str) -> bool:
    """Whether a `get_fonts` entry is the font a text span was drawn with.

    `get_fonts` reports the subset prefix (`CAAAAA+DotoBlack-Black`) and a span
    reports the plain name (`DotoBlack-Black`), so the comparison is on the
    stripped names either way round.
    """
    stripped = basefont.split("+")[-1]
    if not stripped or not span_name:
        return False
    return stripped == span_name or stripped.startswith(span_name) or span_name.startswith(stripped)


def choose(document_path: str) -> tuple[str, dict[str, int]]:
    """(`serif` or `sans-serif`, the character tally behind it) for this document.

    The tally is `{"serif": n, "sans-serif": n, "unknown": n}`: how many visible
    characters the document draws in a face it could be placed in one of. The
    caller logs it, so a wrong answer can be traced to the document rather than
    guessed at.

    Raises `FileNotFoundError` when the document cannot be opened, so the caller
    can fall back rather than translating with a guess.
    """
    import pymupdf

    document = pymupdf.open(document_path)
    try:
        # What each font says, once per font rather than once per page.
        verdict: dict[str, str | None] = {}
        for page in document:
            for entry in page.get_fonts(full=True):
                xref, font_type, basefont = entry[0], entry[2], entry[3]
                if basefont in verdict:
                    continue
                flags = _font_flags(document, xref, basefont, font_type)
                named = _name_says(basefont)
                if flags is not None and flags[1]:
                    # A monospaced face: leave it to the name or the fallback
                    # rather than call a code font a serif or a sans.
                    verdict[basefont] = named
                elif flags is not None:
                    verdict[basefont] = SERIF if flags[0] else SANS_SERIF
                else:
                    verdict[basefont] = named

        tally = {SERIF: 0, SANS_SERIF: 0, "unknown": 0}
        for page in document:
            for block in page.get_text("dict")["blocks"]:
                for line in block.get("lines", []):
                    for span in line["spans"]:
                        count = len(span["text"].strip())
                        if not count:
                            continue
                        said = None
                        for basefont, answer in verdict.items():
                            if _matches(basefont, span["font"]):
                                said = answer
                                break
                        if said is None:
                            said = _name_says(span["font"])
                        tally[said if said in tally else "unknown"] += count
        if tally[SERIF] == 0 and tally[SANS_SERIF] == 0:
            return DEFAULT, tally
        # A tie goes to the default, which is what an inconclusive document is.
        return (SERIF if tally[SERIF] > tally[SANS_SERIF] else DEFAULT), tally
    finally:
        document.close()


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Choose a PDF's translation font family")
    parser.add_argument("pdf")
    parser.add_argument("--explain", action="store_true", help="print the evidence to stderr")
    args = parser.parse_args(argv)

    answer, tally = choose(args.pdf)
    if args.explain:
        import sys

        import pymupdf

        document = pymupdf.open(args.pdf)
        try:
            for page in document:
                for entry in page.get_fonts(full=True):
                    basefont = entry[3]
                    print(
                        f"{basefont}\ttype={entry[2]}\t"
                        f"flags={_font_flags(document, entry[0], basefont, entry[2])}\t"
                        f"name={_name_says(basefont)}",
                        file=sys.stderr,
                    )
        finally:
            document.close()
        print(f"characters: {tally}", file=sys.stderr)
        print(f"chose {answer}", file=sys.stderr)
    print(answer)
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
