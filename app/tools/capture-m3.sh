#!/bin/sh
# Capture the M3 surfaces (PDF) in light and dark appearance (SPEC 15).
#
#   swiftc -O tools/winid.swift -o /tmp/winid      # once
#   tools/capture-m3.sh                            # everything
#   tools/capture-m3.sh panel notch                # only those groups
#
# **The screen must be unlocked.** While it is locked, `screencapture -l`
# fails with "could not create image from window" and the app is not drawn at
# all, so the pictures would be useless. The script refuses to run in that case.
#
# The panel and the island are captured as windows (`screencapture -l`), so
# their Liquid Glass is composited by the window server. The menu bar icon is
# not a window at all, so the right-hand end of the menu bar strip is captured
# as a screen region instead.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
SHOTS=../docs/checks/shots
WINID=${WINID:-/tmp/winid}
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

screen_width=$(printf 'import AppKit\nprint(Int(NSScreen.main?.frame.width ?? 1440))\n' \
    | swift - 2>/dev/null | tail -1)


# shot <name> <appearance> [WAIT=<seconds>] <args...>
shot() {
    name=$1; appearance=$2; shift 2
    wait_seconds=${WAIT:-7}
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

# The status item is not a window: grab the right-hand end of the menu bar.
icon_shot() {
    name=$1; appearance=$2; shift 2
    if [ -n "$DATADIR" ]; then
        "$BIN" --appearance "$appearance" --data-dir "$DATADIR" "$@" >/dev/null 2>&1 &
    else
        "$BIN" --appearance "$appearance" "$@" >/dev/null 2>&1 &
    fi
    pid=$!
    sleep 6
    if screencapture -x -o -R "$((screen_width - 420)),0,420,26" "$SHOTS/$name.png"; then
        echo "[$name] menu bar region"
    else
        echo "[$name] screencapture failed for the menu bar" >&2
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
    if wanted panel; then
        # SPEC 4.2: the drop state, the 「作業中の PDF」 row while a job runs,
        # and the same row after it finished.
        shot "M3-panel-drop-$appearance" "$appearance" WAIT=5 \
            --demo-surface panel --demo-state drop --demo-pin --demo-quit-after 60
        shot "M3-panel-pdf-running-$appearance" "$appearance" WAIT=6 \
            --demo-surface panel --demo-state pdf-running --demo-pin --demo-quit-after 60
        shot "M3-panel-pdf-done-$appearance" "$appearance" WAIT=6 \
            --demo-surface panel --demo-state pdf-done --demo-pin --demo-quit-after 60
    fi

    if wanted notch; then
        # SPEC 4.5: drop, activity, done, error. On a Mac without a notch the
        # island is drawn on the main display instead (NotchController.force).
        for state in drop activity done error; do
            shot "M3-notch-$state-$appearance" "$appearance" WAIT=5 \
                --demo-surface notch --demo-state "$state" --demo-quit-after 60
        done
    fi

    if wanted manager; then
        shot "M3-manager-pdf-$appearance" "$appearance" WAIT=7 \
            --demo-surface manager --demo-page pdf --demo-quit-after 60
        shot "M3-manager-pdf-running-$appearance" "$appearance" WAIT=7 \
            --demo-surface manager --demo-page pdf --demo-state pdf-running --demo-quit-after 60
        shot "M3-manager-pdf-done-$appearance" "$appearance" WAIT=7 \
            --demo-surface manager --demo-page pdf --demo-state done --demo-quit-after 60
    fi

    if wanted settings; then
        shot "M3-settings-pdf-$appearance" "$appearance" WAIT=6 \
            --demo-surface settings --demo-tab PDF --demo-quit-after 60
        shot "M3-settings-pdf-installed-$appearance" "$appearance" WAIT=6 \
            --demo-surface settings --demo-tab PDF --pdf-python "$(command -v python3)" --demo-quit-after 60
    fi

    if wanted icon; then
        for state in progress done failed; do
            icon_shot "M3-icon-$state-$appearance" "$appearance" \
                --demo-surface icon --demo-state "$state" --demo-quit-after 60
        done
    fi
done

ls -la "$SHOTS" | grep 'M3-' || true
