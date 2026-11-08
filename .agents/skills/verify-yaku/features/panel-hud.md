# Menu bar panel and HUD

The panel is the glass window under the menu bar icon: an input, the translation, and quick buttons (画面を翻訳 / PDF を開く… / 履歴). The HUD is the small window that appears under selected text after ⌃⌥J.

## Sub-features

- `panel-open` opens the panel from the icon or ⌃⌥K.
- `panel-states` shows empty, translating, done, error and no-permission.
- `hud-selection` translates the selection under the cursor.
- `hud-source` shows the source while ⌥ is held.

## How to get to it (user POV)

- Click the menu bar icon, or press ⌃⌥K.
- Select text in any app and press ⌃⌥J. The HUD opens under the selection.

## Driving it with yaku-verify

- **Panel states.** Run `$V shot panel-done WAIT=20 --appearance light --demo-surface panel --demo-state done --demo-pin --demo-quit-after 60`. Swap `--demo-state` for `empty`, `translating`, `error` or `no-permission`. `--demo-pin` keeps the panel open while it is captured.
- **Panel over a background.** Add `--demo-backdrop light` or `--demo-backdrop dark` to judge the glass. Set `EXCLUDE_SCREEN_SIZED=1` in the environment so the backdrop window is not picked as the shot.
- **HUD.** Run `$V shot hud WAIT=20 --demo-surface hud --demo-state done --demo-text "Attention is all you need." --demo-anchor 600,400 --demo-pin --demo-quit-after 60`.
- **Open latency.** The log line `panel open (…)` carries the time from the trigger to the window. Read it with `$V log 'panel open'`.
- **CPU while translating.** Run `$V cpu translating 16 12 --demo-surface panel --demo-state translating --demo-pin --demo-quit-after 60` 3 times. Baseline 12.6-13.5%.

## Gotchas

- The real hotkeys need a human. The `--demo-surface` path logs the same `panel open` line, so it stands in for timing, not for the key registration itself.
- Without `--demo-pin`, a click anywhere closes the panel before the capture.
- The panel's global mouse monitor runs even while it is hidden. Do not drag windows during a `cpu` window.
