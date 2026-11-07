#!/bin/sh
# Capture the M2 surfaces in light and dark appearance (SPEC 15).
#
#   swiftc -O tools/winid.swift -o /tmp/winid      # once
#   tools/capture-m2.sh                            # everything
#   tools/capture-m2.sh manager settings           # only those groups
#
# The window is captured with `screencapture -l <windowID>`, so the sidebar and
# the toolbar are composited by the window server and keep macOS 26's own
# Liquid Glass. **The screen must be unlocked**: while it is locked,
# `screencapture -l` fails with "could not create image from window", and the
# app is not drawn at all, so the pictures would be useless.
#
# The manager, the settings and the onboarding windows are the only windows at
# layer 0; the panel (3) and the HUD float above them. A sheet (the licence) is
# its own window, so every onscreen window with content is captured
# (tools/capture-lib.sh).
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

# Say so up front rather than producing a folder full of failures.
locked=$(printf 'import CoreGraphics\nprint((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int ?? 0)\n' \
    | swift - 2>/dev/null | tail -1)
if [ "$locked" = "1" ]; then
    echo "error: the screen is locked; unlock it and run this again (SPEC 15)" >&2
    exit 1
fi


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

wanted() {
    [ -z "$CAPTURE_GROUPS" ] && return 0
    for group in $CAPTURE_GROUPS; do
        [ "$group" = "$1" ] && return 0
    done
    return 1
}

CAPTURE_GROUPS="$*"

manager_pages="translate pdf history glossary models"
settings_tabs="一般 ショートカット エンジン PDF 画面翻訳 プライバシー"

for appearance in light dark; do
    if wanted manager; then
        for page in $manager_pages; do
            if [ "$page" = "translate" ]; then
                shot "M2-manager-translate-done-$appearance" "$appearance" WAIT=22 \
                    --demo-surface manager --demo-page translate --demo-state done \
                    --demo-text "The best performing models also connect the encoder and decoder through an attention mechanism. Attention is all you need." \
                    --demo-quit-after 90
            fi
            shot "M2-manager-$page-$appearance" "$appearance" \
                --demo-surface manager --demo-page "$page" --demo-quit-after 60
        done
        # The licence gate, which is a sheet of its own.
        shot "M2-manager-license-$appearance" "$appearance" \
            --demo-surface manager --demo-page models --demo-download 0.8b \
            --demo-download-gate --demo-quit-after 60
    fi

    if wanted settings; then
        for tab in $settings_tabs; do
            safe=$(printf '%s' "$tab" | tr -d ' ')
            shot "M2-settings-$safe-$appearance" "$appearance" \
                --demo-surface settings --demo-tab "$tab" --demo-quit-after 60
        done
    fi

    if wanted onboarding; then
        for page in 1 2 3 4; do
            shot "M2-onboarding-$page-$appearance" "$appearance" \
                --demo-surface onboarding --demo-page "$page" --demo-quit-after 60
        done
    fi

    if wanted panel; then
        # The M1 fixes: no copy and no 「管理画面で開く」 in the empty and error
        # states, and no wide blank face below the error buttons.
        shot "M2-panel-empty-$appearance" "$appearance" WAIT=5 \
            --demo-surface panel --demo-state empty --demo-pin --demo-quit-after 60
        shot "M2-panel-error-$appearance" "$appearance" WAIT=5 \
            --demo-surface panel --demo-state error --demo-pin --demo-quit-after 60
    fi
done

ls -la "$SHOTS" | grep 'M2-' || true
