#!/bin/sh
# Capture the M0 panel in light and dark appearance: one shot of the panel
# window itself, one of the area around it including the menu bar.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
SHOTS=../docs/checks/shots
WINID=/tmp/winid

capture() {
    appearance=$1
    "$BIN" --demo-surface panel --demo-state empty --appearance "$appearance" \
        --demo-quit-after 14 >/dev/null 2>&1 &
    pid=$!
    sleep 5

    echo "[$appearance] windows:"
    "$WINID" Yaku | sed 's/^/    /'

    # AppKit keeps an offscreen helper window around, so pick the onscreen
    # window with the largest area: that is the panel.
    info=$("$WINID" Yaku | grep 'onscreen=true' | awk '{
        for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
        print v["w"] * v["h"], $0
    }' | sort -rn | head -1 | cut -d' ' -f2-)

    id=$(echo "$info" | sed -n 's/.*id=\([0-9]*\).*/\1/p')
    x=$(echo "$info" | sed -n 's/.*x=\(-\{0,1\}[0-9]*\).*/\1/p')
    echo "[$appearance] chosen: id=$id x=$x"

    screencapture -x -o -l "$id" "$SHOTS/M0-panel-$appearance.png"
    screencapture -x -R"$((x - 68)),0,600,400" "$SHOTS/M0-around-$appearance.png"

    wait "$pid" 2>/dev/null || true
    echo "[$appearance] done"
}

capture light
capture dark
ls -la "$SHOTS"
