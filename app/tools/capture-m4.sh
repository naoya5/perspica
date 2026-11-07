#!/bin/sh
# Capture the M4 surfaces (the screen overlay and the region picker) in light and
# dark appearance (SPEC 15).
#
#   swiftc -O tools/winid.swift -o /tmp/winid      # once
#   tools/capture-m4.sh                            # everything
#   tools/capture-m4.sh overlay picker             # only those groups
#
# **The screen must be unlocked.** While it is locked the app is not drawn at
# all, so the pictures would be useless; the script refuses to run in that case.
#
# The overlay and the picker are captured as windows (`screencapture -l`), so
# their Liquid Glass is composited by the window server. The picker is also
# grabbed as a screen region once, because its whole job is the dimming over
# whatever is underneath, which a window-only capture cannot show.
#
# The sample pictures the overlay reads come from `--demo-image`, which draws the
# picture in the window (M4 only), so the capture shows whether the backing hides
# the text it covers. Build them with `tools/make-samples.swift`.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
SHOTS=../docs/checks/shots
WINID=${WINID:-/tmp/winid}
SAMPLES=${SAMPLES:-${TMPDIR:-/tmp}/yaku-m4}
# Demo runs write history and PDF jobs; keep them out of the real store.
DATADIR=${DATADIR:-${TMPDIR:-/tmp}/yaku-demo-data}
mkdir -p "$DATADIR"
mkdir -p "$SHOTS"
. tools/capture-lib.sh

[ -x "$WINID" ] || {
    echo "error: $WINID not found; run: swiftc -O tools/winid.swift -o $WINID" >&2
    exit 1
}

locked=$(printf 'import CoreGraphics\nprint((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int ?? 0)\n' \
    | swift - 2>/dev/null | tail -1)
if [ "$locked" = "1" ]; then
    echo "error: the screen is locked; unlock it and run this again (SPEC 15)" >&2
    exit 1
fi

screen_size=$(printf 'import AppKit\nif let s = NSScreen.main { print("\\(Int(s.frame.width)) \\(Int(s.frame.height))") }\n' \
    | swift - 2>/dev/null | tail -1)
screen_width=$(echo "$screen_size" | cut -d' ' -f1)
screen_height=$(echo "$screen_size" | cut -d' ' -f2)


# shot <name> <appearance> [WAIT=<seconds>] <args...>
shot() {
    name=$1; appearance=$2; shift 2
    wait_seconds=${WAIT:-8}
    if [ "${1:-}" != "" ] && [ "${1#WAIT=}" != "$1" ]; then
        wait_seconds=${1#WAIT=}
        shift
    fi
    if [ -n "$DATADIR" ]; then
        "$BIN" --appearance "$appearance" --data-dir "$DATADIR" "$@" >/dev/null 2>&1 &
    else
        "$BIN" --appearance "$appearance" "$@" >/dev/null 2>&1 &
    fi
    pid=$!
    sleep "$wait_seconds"

    capture_windows "$name"

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 1
}

# region_shot <name> <appearance> [WAIT=<seconds>] <args...>: the whole screen,
# so the dimming over what is underneath is visible.
region_shot() {
    name=$1; appearance=$2; shift 2
    wait_seconds=${WAIT:-8}
    if [ "${1:-}" != "" ] && [ "${1#WAIT=}" != "$1" ]; then
        wait_seconds=${1#WAIT=}
        shift
    fi
    if [ -n "$DATADIR" ]; then
        "$BIN" --appearance "$appearance" --data-dir "$DATADIR" "$@" >/dev/null 2>&1 &
    else
        "$BIN" --appearance "$appearance" "$@" >/dev/null 2>&1 &
    fi
    pid=$!
    sleep "$wait_seconds"
    if screencapture -x -o -R "0,0,$screen_width,$screen_height" "$SHOTS/$name.png"; then
        echo "[$name] screen region"
    else
        echo "[$name] screencapture failed" >&2
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 1
}

wanted() {
    [ -z "$CAPTURE_GROUPS" ] && return 0
    for group in $CAPTURE_GROUPS; do
        [ "$group" = "$1" ] && return 0
    done
    return 1
}

CAPTURE_GROUPS="$*"

for appearance in light dark; do
    if wanted picker; then
        # SPEC 4.6 の 1: the dimming, the window outline and the glass capsule.
        shot "M4-picker-$appearance" "$appearance" WAIT=5 \
            --demo-surface overlay-picker --demo-quit-after 40
        region_shot "M4-picker-screen-$appearance" "$appearance" WAIT=5 \
            --demo-surface overlay-picker --demo-quit-after 40
    fi

    if wanted overlay; then
        # SPEC 4.6 の 3〜4: the translation drawn over the text it covers, for
        # the three sample pictures. The picture is drawn in the window by the
        # demo path, so the backing can be judged.
        for sample in article columns ui; do
            [ -f "$SAMPLES/$sample.png" ] || { echo "[$sample] missing $SAMPLES/$sample.png" >&2; continue; }
            shot "M4-overlay-$sample-$appearance" "$appearance" WAIT=10 \
                --demo-image "$SAMPLES/$sample.png" --demo-quit-after 40
        done
        # SPEC 13: the two states with no picture.
        shot "M4-overlay-permission-$appearance" "$appearance" WAIT=5 \
            --demo-surface overlay --demo-state permission --demo-quit-after 40
        shot "M4-overlay-empty-$appearance" "$appearance" WAIT=5 \
            --demo-surface overlay --demo-quit-after 40
    fi

    if wanted settings; then
        shot "M4-settings-overlay-$appearance" "$appearance" WAIT=6 \
            --demo-surface settings --demo-tab 画面翻訳 --demo-quit-after 40
    fi
done

ls -la "$SHOTS" | grep 'M4-' || true
