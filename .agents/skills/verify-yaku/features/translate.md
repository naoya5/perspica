# Text translation and the engine

Yaku translates text through PLaMo 3 Translate, which runs as a `llama-server` child process on a free local port and streams the result. The engine starts on first use and stops after the idle time in settings (default 600 s).

## Sub-features

- `engine-start` starts llama-server and waits for `/health`.
- `translate-stream` streams one translation piece by piece.
- `translate-cache` answers a repeated sentence from the cache without the engine.
- `translate-form` sets である / です・ます for Japanese output.

## How to get to it (user POV)

- Type in the panel's input and press ⌘↩.
- Manager window, 翻訳 page. Type in 原文 and press 訳す or ⌘↩.
- Select text in any app and press ⌃⌥J (see panel-hud.md).

## Driving it with yaku-verify

- **Headless round trip.** Run `$V translate "Attention is all you need."`. It prints `demo-translate engineStartup=…s first=…s total=…s` and `demo-translate result=…`. The result must be Japanese. A cold run takes about 2-4 s for the engine and about 0.04 s to the first piece.
- **Cache.** Within one `begin` / `end` pair the scratch store persists across instances. Translate the same sentence through the manager page twice. The second run logs `translate done id=… cache=hit in …s`.
- **Manager page, visual.** Run `$V shot translate-done WAIT=22 --appearance light --demo-surface manager --demo-page translate --demo-state done --demo-text "The best performing models also connect the encoder and decoder through an attention mechanism." --demo-quit-after 90`. The PNG shows 原文 and 訳文 as two cards, `EN → JA` in the 訳文 header, the copy button inside the window, and the elapsed time under the 訳文 card.
- **Side effect.** After a manager or panel translation, and before `$V end`, `<state>/data/Yaku.store` is a SwiftData SQLite file. Find the history table with `sqlite3 <store> .tables` (SwiftData prefixes entity names with `Z`) and count its rows.

## Gotchas

- `--demo-translate` exits on its own. Do not add a long `--demo-quit-after`. The helper waits for the process.
- A missing model makes `engine failed` appear in the log. `doctor` checks the model first.
- The engine client uses a session with no URL cache (2026-11-09). To prove nothing reaches disk, count rows in `~/Library/Caches/Yaku/Cache.db` (the bare binary) before and after a run; they must not change. The installed app removes those leftovers at launch.
