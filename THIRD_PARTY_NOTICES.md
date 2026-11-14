# Third-party notices

Reviewed against the sources below on **2026-11-13**; the PDF section was
updated on **2026-11-14**. Icon font licensing sources were checked on
**2026-11-15**.

Perspica's original source is offered under the MIT license in `LICENSE`.
That license does not replace the licenses for model weights or native
libraries. This notice does not approve a binary release. Release conditions
are recorded in `docs/release-licenses.md` and tracked in `docs/release-tasks.md`.

## PLaMo 3 Translate

**Built with PLaMo**

The downloadable models are provided by Preferred Networks, Inc. (PFN):

| Model repository | File |
| --- | --- |
| [pfnet/plamo-3-translate-0.8b-GGUF](https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF) | `plamo-3-translate-0.8b-Q4_K_M.gguf` |
| [pfnet/plamo-3-translate-2b-GGUF](https://huggingface.co/pfnet/plamo-3-translate-2b-GGUF) | `plamo-3-translate-2b-Q4_K_M.gguf` |
| [pfnet/plamo-3-translate-8b-GGUF](https://huggingface.co/pfnet/plamo-3-translate-8b-GGUF) | `plamo-3-translate-8b-Q4_K_M.gguf` |

These are **not MIT- or Apache-licensed weights**. All three publisher model
cards specify the [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-en),
revised November 9, 2026. Its full wording is reproduced in
`app/Resources/PLAMO-COMMUNITY-LICENSE-en.txt` in the source tree and
`Contents/Resources/PLAMO-COMMUNITY-LICENSE-en.txt` in the app.

Personal and academic use do not require commercial registration. The agreement
defines commercial purpose broadly, including organizational use. Under Article
3, commercial use requires prior PFN registration and annual revenue/sales of the
user or affiliated company not exceeding JPY 1 billion; otherwise a separate PFN
commercial license is required. Clicking Perspica's consent button is not PFN
registration.

When providing the model or a derived model to others, Article 4 requires a copy
of the agreement, recipient compliance, the exact attribution “Built with PLaMo”,
PLaMo in names of models created using the materials, and compliance with other
component licenses. It does not require renaming the app itself.

Article 5 allows public distribution of conversion-model output without the
ordinary model-output indication, except that a book, paper, or similar
standalone long-form publication consisting wholly or substantially of that
output must credit PLaMo's translation/conversion in a reasonable location.
Article 5(4) separately requires recipients of output, including output datasets,
to be informed that models trained using it are subject to the agreement.
For example: “Any model trained using this PLaMo output is subject to the PLaMo
Community License Agreement.” The agreement also preserves third-party rights in
input and output. This paragraph is a summary, not a substitute for its terms.

## llama.cpp

Copyright (c) 2023-2026 The ggml authors.

[llama.cpp](https://github.com/ggml-org/llama.cpp) is MIT-licensed. The audited
Homebrew installation is **0.7.0**, source revision
`620d2225cc436ab0b001e3200e590e3b286ef9ab`.
The app does not pin it: an external executable is normally used, and the
packager can optionally copy it into the app. A release must record the actual
binary and its dependencies rather than assuming it matches this workstation.

The full upstream MIT notice is at
`app/Resources/Licenses/llama.cpp-0.7.0-LICENSE.txt` in the source tree and
`Contents/Resources/Licenses/llama.cpp-0.7.0-LICENSE.txt` in the app.
Preserve it when redistributing the executable or library. Embedded code, the
server web UI, and linked libraries may need additional notices; the top-level
MIT file alone is not a complete notice inventory for a built server.

## PDF translation

PDFs are translated inside the app, by Perspica's own Swift code
(`app/Sources/YakuCore/NativePDF`) and Apple system frameworks (Core Graphics,
Core Text, PDFKit, Compression). No third-party PDF library, Python package,
downloaded font, CMap or layout model is used, installed or distributed.
The implementation policy is to use the PDF specification (ISO 32000) and
Apple APIs, and not to read or port other PDF libraries' source. This rule
also applies to coding agents.

The typesetter requests the Hiragino fonts that ship with macOS
(HiraMinProN-W3/W6, HiraginoSans-W3/W6). These four fonts declare editable
embedding with subsetting allowed (OS/2 `fsType` 0x0008, read on macOS 26 on
2026-11-14). This metadata is not, by itself, a complete license review.
The macOS 26 font license clause and the fonts actually embedded in output
remain checks before sharing translated PDFs. Core Text can select fallback
fonts, and fonts from the original document can also remain in the output.

Versions up to 2026-11-13 used a Python worker (pdf2zh-next, BabelDOC, PyMuPDF
and their dependencies, under AGPL-3.0 and other licenses) that the app installed
on first use. The app now deletes that worker's leftover files
(`Application Support/Perspica/pdf-worker` and `pdf-worker-home`) at launch.

## Icon artwork

`design/app-icon/make-candidates.swift` records six font inputs used to make
the icon candidates and the app icon. Their upstream projects declare
SIL Open Font License 1.1:

| Font family | Upstream license |
| --- | --- |
| Zen Kaku Gothic New | [OFL](https://raw.githubusercontent.com/google/fonts/main/ofl/zenkakugothicnew/OFL.txt) |
| Cinzel | [OFL](https://raw.githubusercontent.com/google/fonts/main/ofl/cinzel/OFL.txt) |
| Cinzel Decorative | [OFL](https://raw.githubusercontent.com/google/fonts/main/ofl/cinzeldecorative/OFL.txt) |
| Cormorant Garamond | [OFL](https://raw.githubusercontent.com/google/fonts/main/ofl/cormorantgaramond/OFL.txt) |
| Shippori Mincho B1 | [OFL](https://raw.githubusercontent.com/google/fonts/main/ofl/shipporiminchob1/OFL.txt) |
| Yuji Syuku | [OFL](https://raw.githubusercontent.com/google/fonts/main/ofl/yujisyuku/OFL.txt) |

The source tree contains generated SVG artwork, not these font binaries.
The [official OFL FAQ, 1.1–1.1.2](https://openfontlicense.org/ofl-faq/),
allows logos and graphics made with OFL fonts without requiring the resulting
artwork to adopt the OFL or carry a font attribution. These links record the
input families and current upstream licensing, not the exact versions or
hashes of the font files originally used. If font binaries are added later,
preserve their own notices and meet the conditions for those actual files.
