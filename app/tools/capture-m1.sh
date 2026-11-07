#!/bin/sh
# Capture the M1 panel and HUD states in light and dark appearance.
#
#   swift tools/winid.swift ...   (build the helper first, see README)
#
# The window is captured with `screencapture -l <windowID>` so the glass is
# composited by the window server (SPEC 15: ImageRenderer cannot show glass).
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
SHOTS=../docs/checks/shots
WINID=${WINID:-/tmp/winid}
mkdir -p "$SHOTS"

[ -x "$WINID" ] || { echo "error: $WINID not found; run: swiftc -O tools/winid.swift -o $WINID" >&2; exit 1; }

# window_id <process> <width>: the onscreen window of that width with the
# largest area. The panel is 464 wide, the HUD 468 (both include the shadow
# margin), so the width tells them apart.
window_id() {
    "$WINID" "$1" | grep 'onscreen=true' | awk -v want="$2" '{
        for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
        if (v["w"] != want) next
        print v["w"] * v["h"], $0
    }' | sort -rn | head -1 | cut -d' ' -f2- | sed -n 's/.*id=\([0-9]*\).*/\1/p'
}

# shot <name> <appearance> <window width> [WAIT=<seconds>] <args...>
shot() {
    name=$1; appearance=$2; width=$3; shift 3
    wait_seconds=${WAIT:-6}
    if [ "${1:-}" != "" ] && [ "${1#WAIT=}" != "$1" ]; then
        wait_seconds=${1#WAIT=}
        shift
    fi
    "$BIN" --appearance "$appearance" "$@" >/dev/null 2>&1 &
    pid=$!
    sleep "${wait_seconds:-6}"
    id=$(window_id Yaku "$width" || true)
    if [ -z "$id" ]; then
        echo "[$name] no window of width $width found" >&2
    elif screencapture -x -o -l "$id" "$SHOTS/$name.png"; then
        echo "[$name] captured window $id"
    else
        echo "[$name] screencapture failed for window $id" >&2
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 1
}

PANEL_WIDTH=464
HUD_WIDTH=468

for appearance in light dark; do
    shot "M1-panel-empty-$appearance" "$appearance" "$PANEL_WIDTH" \
        --demo-surface panel --demo-state empty --demo-pin --demo-quit-after 40
    shot "M1-panel-translating-$appearance" "$appearance" "$PANEL_WIDTH" \
        --demo-surface panel --demo-state translating --demo-pin --demo-quit-after 40 \
        --demo-text "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks that include an encoder and a decoder, and the best performing models also connect the encoder and decoder through an attention mechanism."
    shot "M1-panel-done-$appearance" "$appearance" "$PANEL_WIDTH" \
        WAIT=25 --demo-surface panel --demo-state done --demo-pin --demo-quit-after 60
    shot "M1-panel-error-$appearance" "$appearance" "$PANEL_WIDTH" \
        --demo-surface panel --demo-state error --demo-pin --demo-quit-after 40
    shot "M1-hud-done-$appearance" "$appearance" "$HUD_WIDTH" \
        --demo-surface hud --demo-pin \
        --demo-text "The best performing models also connect the encoder and decoder through an attention mechanism." \
        --demo-anchor 700,300 --demo-quit-after 45
    shot "M1-hud-no-permission-$appearance" "$appearance" "$HUD_WIDTH" \
        --demo-surface hud --demo-state no-permission --demo-pin --demo-quit-after 40
done

ls -la "$SHOTS"
