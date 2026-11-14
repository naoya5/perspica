# Security policy

## Supported versions

Perspica has no releases; users build it from `main`. Security fixes land on `main`, so pull and
rebuild (`cd app && ./make-app.sh install`, from the repository root) to get them.

## Report a vulnerability

Please do not open a public issue, pull request or discussion for a security problem.

Report it privately through
[Security > Report a vulnerability](https://github.com/naoya5/perspica/security/advisories/new) on GitHub.

Include the following information.

- the commit you built (`git rev-parse --short HEAD`), the macOS version and the Mac model
- what an attacker can do, and what they need first (for example, local access or a crafted PDF)
- the steps to reproduce, or a proof of concept

Do not include real source or translated text, documents or screenshots. Use test data.

Perspica is maintained by one person in spare time, so a reply can take a few days. After a fix
lands, the advisory is published with credit to you, unless you ask to stay anonymous.

## Security model

Perspica is a desktop app with no remote service and no account. It uses a local `llama-server`.
These are the properties it is built to
keep; a way to break one of them is a vulnerability.

| Property | How |
|---|---|
| Source and translated text stay on the Mac | The model runs in a local `llama-server`. The only network code is the model downloader. PDFs are translated inside the app. |
| Engine requests require authentication | `llama-server` binds to `127.0.0.1` on a random port and requires a random key per launch. The key is passed in the environment, not on the command line. |
| Model downloads cannot be swapped | Each file comes over HTTPS from Hugging Face and is checked against a SHA-256 pinned in the source before use. |
| A crafted PDF is read defensively | Files are parsed and decoded by Apple's Core Graphics and PDFKit. Perspica's own content-stream reader works only on the bytes those frameworks decoded, and skips malformed operators instead of trusting them. |
| Normal logs do not contain source or translated text | Logs record what the app did and how long it took. Source and translated text are written only in explicit debug runs. |
| Clearing history and caches removes their contents | 「履歴とキャッシュを消す」 removes history, the translation cache, the files left by the old PDF worker and the logs. |
| The app's permissions cannot be borrowed | The app is signed with the hardened runtime, so other processes cannot inject code into it and use its Accessibility or Screen Recording grants. |

### Data and migration

Current data lives in `~/Library/Application Support/Perspica/`, logs in
`~/Library/Logs/Perspica/`, and settings in the `app.perspica` defaults domain. Normal startup
migrates old Yaku data; `--data-dir` runs never migrate real data or settings and keep logs under
`<data-dir>/logs/`. Debug runs can log text; set `YAKU_LOG_CONTENT=0` to disable this.

The migration keeps old settings and the old, non-relocatable PDF worker environment as backups.
Conflicting legacy files also remain in place. Do not assume clearing current history and caches
removes these backups. See the [migration notes](README.en.md#updating-from-yaku) before removing them.
The bundle identifier change requires macOS permissions to be granted again.

## Out of scope

- Problems that need an attacker who already controls your user account or has root.
- macOS warnings about an unidentified developer. The app is not notarized; each user builds it.
- Vulnerabilities in llama.cpp, the PLaMo models or macOS frameworks that Perspica does not make
  worse. Report those upstream, and tell us if Perspica needs to change.
