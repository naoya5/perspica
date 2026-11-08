#!/bin/sh
# Capture the M5 surfaces over a light and a dark backdrop, in both
# appearances, plus the three accessibility looks (SPEC 15, 18).
#
#   swiftc -O tools/winid.swift -o /tmp/winid     # once
#   swiftc -O tools/opaque.swift -o /tmp/opaque   # once
#   tools/capture-m5.sh                           # everything
#   tools/capture-m5.sh panel access              # only those groups
#
# **The screen must be unlocked.** While it is locked, `screencapture` fails
# and the app is not drawn at all. The script refuses to run in that case.
#
# These are **region captures**, not window captures. `screencapture -l` renders
# a window on its own and composites it over nothing, which turns Liquid Glass
# into flat grey and hides what the glass is doing; a region grab shows the
# window over whatever is behind it. `--demo-backdrop` draws that "whatever" as
# a full-screen gradient (the wallpaper is not touched), so the same surface can
# be photographed over a bright and a dark background.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
SHOTS=../docs/checks/shots
WINID=${WINID:-/tmp/winid}
# Demo runs write history and PDF jobs; keep them out of the real store.
DATADIR=${DATADIR:-${TMPDIR:-/tmp}/yaku-demo-data}
mkdir -p "$DATADIR"
mkdir -p "$SHOTS"
# Every shot here runs with `--demo-backdrop`, which adds a screen-sized window
# per display; skip those when picking the surface to photograph.
EXCLUDE_SCREEN_SIZED=1
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

# shot <name> <appearance> <backdrop> [WAIT=<seconds>] <args...>
shot() {
    name=$1; appearance=$2; backdrop=$3; shift 3
    wait_seconds=${WAIT:-6}
    if [ "${1:-}" != "" ] && [ "${1#WAIT=}" != "$1" ]; then
        wait_seconds=${1#WAIT=}
        shift
    fi
    "$BIN" --appearance "$appearance" --demo-backdrop "$backdrop" --data-dir "$DATADIR" "$@" \
        >/dev/null 2>&1 &
    pid=$!
    sleep "$wait_seconds"
    capture_region "$name"
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

# The four surfaces SPEC 15 names, over a light and a dark backdrop, in both
# appearances: 16 pictures.
for appearance in light dark; do
    for backdrop in light dark; do
        if wanted panel; then
            # The demo translates for real, which takes about 7s with the
            # engine starting, so the wait is long enough for the light to be
            # off and the finished text to be up (SPEC 4.2 の「完了」).
            shot "M5-panel-$appearance-on-$backdrop" "$appearance" "$backdrop" WAIT=14 \
                --demo-surface panel --demo-state done --demo-pin --demo-quit-after 60
        fi
        if wanted hud; then
            shot "M5-hud-$appearance-on-$backdrop" "$appearance" "$backdrop" WAIT=12 \
                --demo-surface hud --demo-state done --demo-pin --demo-quit-after 60
        fi
        if wanted notch; then
            shot "M5-notch-$appearance-on-$backdrop" "$appearance" "$backdrop" WAIT=5 \
                --demo-surface notch --demo-state activity --demo-quit-after 60
        fi
        if wanted overlay; then
            shot "M5-overlay-$appearance-on-$backdrop" "$appearance" "$backdrop" WAIT=10 \
                --demo-image "${SAMPLES:-${TMPDIR:-/tmp}/yaku-m4}/article.png" --demo-quit-after 60
        fi
    done
done

# SPEC 18: the three accessibility looks, drawn by launch option instead of by
# changing the Mac's own settings.
for appearance in light dark; do
    if wanted access; then
        shot "M5-access-reduce-transparency-$appearance" "$appearance" dark WAIT=14 \
            --demo-surface panel --demo-state done --demo-pin --demo-reduce-transparency \
            --demo-quit-after 60
        shot "M5-access-increase-contrast-$appearance" "$appearance" light WAIT=14 \
            --demo-surface panel --demo-state done --demo-pin --demo-increase-contrast \
            --demo-quit-after 60
        shot "M5-access-reduce-motion-$appearance" "$appearance" light WAIT=14 \
            --demo-surface panel --demo-state translating --demo-pin --demo-reduce-motion \
            --demo-quit-after 60
    fi
done

# The three samples the M5 reading-order and bold-heading fixes are visible on
# (SPEC 9, M5.md 3.1). The article is in the four-way set already.
for appearance in light dark; do
    if wanted samples; then
        for sample in columns ui; do
            shot "M5-overlay-$sample-$appearance" "$appearance" light WAIT=10 \
                --demo-image "${SAMPLES:-${TMPDIR:-/tmp}/yaku-m4}/$sample.png" --demo-quit-after 60
        done
    fi
done

# The paragraph that mixes Japanese and English lines, which is what the size
# rule of the split has to leave alone (SPEC 9, M5.md 9.2).
if wanted samples; then
    shot "M5-overlay-mixed-light" light light WAIT=10 \
        --demo-image "${SAMPLES:-${TMPDIR:-/tmp}/yaku-m4}/mixed.png" --demo-quit-after 60
fi

# A documentation page with a code block: the code must stay as it is, not come
# back from the model in another font (manual check F4).
if wanted code; then
    shot "M5-overlay-code-light" light light WAIT=12 \
        --demo-image "${SAMPLES:-${TMPDIR:-/tmp}/yaku-m4}/code.png" --demo-quit-after 60
fi

# The M5 fixes are about what the UI says, not about what the glass sits on, so
# they are captured as windows (the backdrop window is above ordinary windows
# and would cover the manager). capture_windows also wants the backdrop skipped,
# which EXCLUDE_SCREEN_SIZED already does.
shot_window() {
    name=$1; appearance=$2; shift 2
    wait_seconds=${WAIT:-8}
    if [ "${1:-}" != "" ] && [ "${1#WAIT=}" != "$1" ]; then
        wait_seconds=${1#WAIT=}
        shift
    fi
    "$BIN" --appearance "$appearance" --data-dir "$DATADIR" "$@" >/dev/null 2>&1 &
    pid=$!
    sleep "$wait_seconds"
    capture_windows "$name"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 1
}

# The M5 fixes that are visible on their own.
for appearance in light dark; do
    if wanted fixes; then
        shot_window "M5-manager-devfile-$appearance" "$appearance" WAIT=10 \
            --demo-surface manager --demo-page models --demo-quit-after 60
        shot_window "M5-manager-license-$appearance" "$appearance" WAIT=10 \
            --demo-surface manager --demo-page models --demo-download 0.8b \
            --demo-download-gate --demo-quit-after 60
        shot_window "M5-settings-pdf-installed-$appearance" "$appearance" WAIT=8 \
            --demo-surface settings --demo-tab PDF --demo-pdf-worker installed --demo-quit-after 60
    fi
done

ls -la "$SHOTS" | grep 'M5-' || true
