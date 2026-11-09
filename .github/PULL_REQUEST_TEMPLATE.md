## What and why

<!-- What changes for someone using Perspica or working on it, and why. Link the issue: "Closes #123". -->

## How it was verified

<!-- Say what you ran and what you checked in the app. Say what you did NOT verify. -->

- [ ] `cd app && swift build` has 0 warnings and `swift test` passes
- [ ] `pdf-worker` tests pass, if the worker changed
- [ ] Checked in the real app (the `verify-yaku` skill, or describe the steps below)

## Screenshots

<!-- For UI changes: before and after, light and dark. Use test text, not real documents. -->

## Checklist

- [ ] No network access outside the model and worker downloads.
- [ ] No translated or source text in logs.
- [ ] Docs are updated (`README.md`, `README.ja.md`, `SPEC.md`) if behavior changed.
- [ ] No secrets, personal data, paths from your machine, or private documents are included.
