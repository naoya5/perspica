## What and why

<!-- Explain what changes for users or contributors, and why. Link the issue, if any: "Closes #123". -->

## How it was verified

<!-- List the commands you ran and the behavior you checked in the app. Explicitly list skipped or failed checks. Mark checks that do not apply as such. -->

- [ ] `cd app && swift build` has 0 warnings and `swift test` passes
- [ ] PDF changes were checked on a real paper (`fixtures/attention.pdf`), and no other PDF library's source was read or ported
- [ ] Checked in the real app using isolated `--data-dir` state (the `verify-yaku` skill, or describe the steps below)

## Screenshots

<!-- For UI changes: before and after, light and dark. Use test text, not real documents. -->

## Checklist

- [ ] No network access outside the model downloads.
- [ ] No translated or source text in normal-use logs; content logging stays opt-in or isolated.
- [ ] User-facing changes are documented in Japanese `README.md`, English `README.en.md` and `SPEC.md`; compatibility links in `README.ja.md` still work.
- [ ] Dependency changes account for `THIRD_PARTY_NOTICES.md` and `docs/release-licenses.md`, if applicable.
- [ ] No secrets, personal data, paths from your machine, or private documents are included.
