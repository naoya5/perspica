# Release licensing and source delivery

Audit date: **2026-11-13**, updated **2026-11-15** after reviewing the native PDF translator.
This is a release checklist, not legal advice or a statement that a release is
cleared. The repository's code is under the MIT license in `LICENSE`. Do not
publish a binary until its applicable conditions below have been resolved and
recorded for that release. The [task list](release-tasks.md) and the
[distribution/source record](source-distribution-scope.md) track the work.

## What changed on 2026-11-14

PDF translation used to run in a Python worker built on pdf2zh-next, BabelDOC and
PyMuPDF (AGPL-3.0), Levenshtein (GPL-2.0-or-later) and about 130 other packages,
installed with uv on first use, plus fonts, CMaps and a layout model that BabelDOC
downloaded. The in-process patch prompted the conservative preparation policy
approved on 2026-11-13: provide the full application source and prepare AGPL
compliance for the combined release. The audit did not establish the legal
extent of AGPL coverage over the entire app.

PDF translation is now Perspica's own Swift code (`app/Sources/YakuCore/NativePDF`)
on Core Graphics, Core Text, PDFKit and Compression. It was written from the PDF
specification under a clean-room rule: the authors, including coding agents, were
told not to read or port the source of other PDF libraries. The worker, its
requirements, the uv installer, the loopback proxy it used and the copied AGPL,
GPL, MPL, font and CMap license texts were removed. The app deletes the old
worker's files from `Application Support/Perspica` at launch. The maintainer
recorded on 2026-11-14 that no build containing the worker had been distributed.

So the AGPL analysis, the Corresponding Source plan and the Python, font and asset
inventories of the earlier audit no longer apply. What remains is PLaMo, llama.cpp
and the fonts embedded in output PDFs.

## Source-only first publication

The current plan is a personal project published as source on GitHub first,
free of charge and without donations, advertising, or paid features. Prebuilt
app distribution is deferred. See tasks S01-S06 in the [task list](release-tasks.md).

Check the rights and notices for the source and resources actually conveyed,
including copied code and design assets (see the [icon artwork record](../THIRD_PARTY_NOTICES.md#icon-artwork)),
and review file contents and Git history
before publication. PLaMo execution, model provision, and sharing generated output
have their own conditions. Source publication alone has not been determined to
require PFN commercial registration. The maintainer's registration history and
contractual use category remain unconfirmed; the
[inquiry memo](plamo-release-inquiry.md) is unsent and on hold.

## What is actually shipped or downloaded

The source tree has no third-party Swift packages and no third-party PDF code.
The packaging script ships the Swift executable and license resources. It
optionally copies a Homebrew `llama-server`. It does not ship PLaMo weights.
The app downloads only the model, from Hugging Face.

| Artifact | Identified version | Release evidence needed |
| --- | --- | --- |
| PLaMo 3 Translate 0.8B Q4_K_M | SHA-256 `923b2f28a9856de1b8b3b610a7e59ded0b14d007466fd5dd526e6a9ecaadafdd` | Actual download matches catalog; retain model-card revision and terms |
| PLaMo 3 Translate 2B Q4_K_M | SHA-256 `f36d0813dd95573a852ab5d76e374c543632d9e292929e922bcdbf7e53b494e0` | Same |
| PLaMo 3 Translate 8B Q4_K_M | SHA-256 `47a04e86a67bcc352fa186f01159060aae594b73993e1d49dbfc0ef0081d01ad` | Same |
| llama.cpp | Local Homebrew 0.7.0, commit `620d2225cc436ab0b001e3200e590e3b286ef9ab` | Actual bundled/external version, executable hash, build recipe and dependency closure |
| Hiragino fonts | Shipped with macOS; subsets are embedded in translated PDFs | Checked 2026-11-14: OS/2 `fsType` 0x0008 (editable embedding, subsetting allowed) for HiraMinProN-W3/W6 and HiraginoSans-W3/W6. Checked 2026-11-15: the macOS Tahoe 26 license, section 2E, defers to these restrictions |

The PLaMo hashes above are the catalog's artifact identifiers, not a new download
verification performed by this audit. `resolve/main` is mutable: retain the actual
repository revision and model-card/license snapshot as well as the byte hash.
The recorded Homebrew llama.cpp recipe uses shared libraries, system ggml,
OpenSSL, and a built web UI. Its receipt lists ggml 0.27.0, OpenSSL 4.0.3, and
libomp 23.1.4. These are leads for the actual binary dependency audit, not proof
that every listed library is embedded in the executable.

## PLaMo: agreement, attribution, output, and consent

The [official agreement](https://plamo.preferredai.jp/info/plamo-community-license-en)
states that it was revised on **November 9, 2026**. The older bundled copy lacked
the conversion-model definition and output exceptions, the output-training
notice, and other amendments. The bundled copy now reproduces the current
publisher wording. Its webpage-to-text formatting is preserved as returned by
FetchUrl; it is not a new translation or a substitute legal license.

1. Keep the full agreement available offline and show it before a model download.
   Both manager and onboarding use the same gate. A missing license resource
   disables acceptance instead of replacing the agreement with an inaccurate
   summary. The manager and onboarding show **Built with PLaMo**.
2. Store consent against the model ID **and** `2026-11-09`. Earlier bare-ID consent
   does not imply agreement to revised terms for subsequent downloads. This
   changes neither the settings backend nor legacy-data migration.
3. Existing installed/custom models can still run without a new download gate.
   Consent records are not proof that every current user accepted the revision.
   Before release, decide how to notify existing users of amended terms and
   whether renewed acceptance is needed, taking Article 12's notice/effective-date
   mechanism into account. Do not silently write a new consent on their behalf.
4. Commercial purpose includes organizational use, product/service development,
   and API/hosting use. Verify the distributor's own eligibility as well as
   users' obligations. In-app agreement is not the required PFN commercial
   registration. Above the revenue threshold, obtain a separate PFN license.
5. If supplying weights or derived models, meet Article 4's agreement-copy,
   attribution, model naming, recipient-compliance, and other-license conditions.
   Do not apply MIT to PFN's weights. The app's name need not contain PLaMo.
6. Preserve Article 5's distinctions: normal public output requires a model
   indication; conversion output has the exception and long-form-publication
   credit requirement; output recipients must separately be told that models
   trained on the output are subject to the agreement. The conversion exception
   does **not** remove Article 5(4). Plan recipient-visible notices for copied,
   exported, and PDF output, or an equally effective recipient-facing mechanism.
   A note visible only to Perspica's operator does not by itself notify recipients.
7. Model use does not grant rights in a third party's document or its translation.
   Retain the input/output rights and no-warranty explanations.

## Notices and packaging

Before signing, include at least:

- The root MIT `LICENSE`.
- `THIRD_PARTY_NOTICES.md`.
- `PLAMO-COMMUNITY-LICENSE-en.txt`.
- The entire `app/Resources/Licenses` directory under `Contents/Resources/Licenses`.
- Artifact-specific license/NOTICE files not yet captured by those resources.

The manager's licensing card opens the local notices without transmitting
translation data. Verify all bundled links and resources in the signed artifact.

When bundling llama-server, audit its actual linked libraries, embedded web UI,
vendored headers, ggml backends, OpenSSL, and any additional native code. Preserve
all applicable copyright/license/NOTICE files. Copying only the Homebrew
executable is neither proof of a self-contained bundle nor a complete license
inventory. MIT does not itself require a source offer, but it requires the
copyright and permission notice when distributing substantial copies.

## Unresolved release gates

1. Resolve amended PLaMo terms for existing users and recipient-facing output
   notices, and confirm the distributor's commercial eligibility/registration.
2. Pin and record the actual engine and model revisions; if llama-server is
   bundled, extract all license/copyright/NOTICE files from the exact binary and
   its libraries.
3. Complete a signed-bundle notice/link check after all packaging changes. Never
   describe documentation alone as legal clearance.

## Font embedding (checked 2026-11-15)

The software license agreement for macOS Tahoe 26 on the build Mac (26.5.2,
`/Library/Documentation/License.lpdf`), section 2E, says: "you may only embed fonts
in content if that is permitted by the embedding restrictions accompanying the
font in question". The wording is the same as in the macOS 10.12 license. The
Hiragino fonts the typesetter requests declare editable embedding with
subsetting allowed (see the table).

Translated outputs of the Attention paper (all 15 pages) and the ResNet paper
(pages 2, 4 and 5) were compared with their sources. The fonts the app added were
only subsets of HiraMinProN-W3/W6 and HiraginoSans-W3/W6; Core Text chose no
fallback font on these pages. This is a sample: Core Text can still substitute another
font for a character the Hiragino fonts lack (a formula that the fallback path
writes as plain text makes that more likely), so check the fonts of an output
before relying on this for it. All other fonts in the output are the source document's own embedded fonts,
which stay because untranslated parts of each page are kept. Whoever shares a
translated PDF is responsible for those fonts, as for the source. This is a
record of the check, not legal clearance.

## Evidence

Primary terms and project/version links are in `THIRD_PARTY_NOTICES.md`.
`app/Resources/Licenses/PROVENANCE.md` identifies each copied legal text and
its retrieval date. All online evidence was read with FetchUrl; no legal text was
rewritten or translated by this audit. Dated entries in the task list summarize
the earlier Python audit and the change of plan. Do not assume an uncommitted
report has been preserved in Git history.
