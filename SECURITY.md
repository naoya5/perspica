# Security policy

## Supported versions

Perspica has no releases; users build it from `main`. Security fixes land on `main`, so pull and
rebuild (`./make-app.sh install`) to get them. For the PDF worker, the app reinstalls its Python
environment automatically when `pdf-worker/requirements.txt` changes.

## Report a vulnerability

Please do not open a public issue, pull request or discussion for a security problem.

Report it privately through GitHub:
[**Security > Report a vulnerability**](https://github.com/naoya5/perspica/security/advisories/new).

Include:

- the commit you built (`git rev-parse --short HEAD`), the macOS version and the Mac model
- what an attacker can do, and what they need first (for example, local access or a crafted PDF)
- the steps to reproduce, or a proof of concept

Do not include real translated text, documents or screen pictures. Use test data.

Perspica is maintained by one person in spare time, so a reply can take a few days. After a fix
lands, the advisory is published with credit to you, unless you ask to stay anonymous.

## Security model

Perspica is a desktop app with no server and no account. These are the properties it is built to
keep; a way to break one of them is a vulnerability.

| Property | How |
|---|---|
| Source and translated text stay on the Mac | The model runs in a local `llama-server`. The only network code is the model downloader and the PDF worker's first-run setup. |
| The engine is not open to other programs | `llama-server` binds to `127.0.0.1` on a random port and requires a random key per launch. The key is passed in the environment, not on the command line. |
| Model downloads cannot be swapped | Each file comes over HTTPS from Hugging Face and is checked against a SHA-256 pinned in the source before use. |
| The PDF worker installs what was reviewed | `pdf-worker/requirements.txt` is a locked, hashed dependency set; the installer requires the hashes and re-syncs when the file changes. |
| A crafted PDF cannot run code through known parser bugs | The worker's PDF stack is pinned to versions with known vulnerabilities fixed, and runs in a separate process from the app. |
| Logs do not leak words | Logs record what the app did and how long it took. Source and translated text are written only in explicit debug runs. |
| Erasing really erases | 「履歴とキャッシュを消す」 removes history, the translation cache, the PDF worker's translation cache and the logs. |
| The app's permissions cannot be borrowed | The app is signed with the hardened runtime, so other processes cannot inject code into it and use its Accessibility or Screen Recording grants. |

## Out of scope

- Problems that need an attacker who already controls your user account or has root.
- macOS warnings about an unidentified developer. The app is not notarized; each user builds it.
- Vulnerabilities in llama.cpp, the PLaMo models or the PDF worker's Python packages that Perspica
  does not make worse. Report those upstream, and tell us if Perspica needs to update a pin.
