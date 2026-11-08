#!/bin/sh
# Capture the M7 surfaces: the settings window's six tabs and the manager
# window's six screens, in light and dark appearance (SPEC 15).
#
#   swiftc -O tools/winid.swift -o /tmp/winid      # once
#   swiftc -O tools/opaque.swift -o /tmp/opaque    # once
#   tools/capture-m7.sh                            # everything
#   tools/capture-m7.sh settings                   # only that group
#
# M7 changes only the two hand-opened windows, so these are the same window
# captures the M2 script takes (`screencapture -l <windowID>`, so the sidebar
# and the toolbar keep macOS 26's own Liquid Glass). The shots are named
# `M7-...` with the same composition as the `M2-...` pictures in
# `docs/checks/shots/`, so before and after can be laid side by side.
#
# **The screen must be unlocked**: while it is locked, `screencapture -l` fails
# with "could not create image from window" and the app is not drawn at all.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
SHOTS=../docs/checks/shots
WINID=${WINID:-/tmp/winid}
# Demo runs write history and PDF jobs; keep them out of the real store.
DATADIR=${DATADIR:-${TMPDIR:-/tmp}/yaku-demo-data}
mkdir -p "$DATADIR" "$SHOTS"
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

# shot <name> <appearance> [WAIT=<seconds>] <args...>
shot() {
    name=$1; appearance=$2; shift 2
    wait_seconds=${WAIT:-7}
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

wanted() {
    [ -z "$CAPTURE_GROUPS" ] && return 0
    for group in $CAPTURE_GROUPS; do
        [ "$group" = "$1" ] && return 0
    done
    return 1
}

CAPTURE_GROUPS="$*"

settings_tabs="一般 ショートカット エンジン PDF 画面翻訳 プライバシー"
manager_pages="pdf history glossary models"

for appearance in light dark; do
    if wanted settings; then
        for tab in $settings_tabs; do
            safe=$(printf '%s' "$tab" | tr -d ' ')
            shot "M7-settings-$safe-$appearance" "$appearance" \
                --demo-surface settings --demo-tab "$tab" --demo-quit-after 60
        done
    fi

    if wanted manager; then
        # 翻訳, in the finished state the M2 picture is in.
        shot "M7-manager-translate-done-$appearance" "$appearance" WAIT=22 \
            --demo-surface manager --demo-page translate --demo-state done \
            --demo-text "The best performing models also connect the encoder and decoder through an attention mechanism. Attention is all you need." \
            --demo-quit-after 90
        # The remaining pages. The PDF page carries a finished row and a failed
        # one with a long worker error (M7 9).
        for page in $manager_pages; do
            if [ "$page" = "pdf" ]; then
                shot "M7-manager-$page-$appearance" "$appearance" \
                    --demo-surface manager --demo-page "$page" --demo-state done \
                    --demo-quit-after 60
            else
                shot "M7-manager-$page-$appearance" "$appearance" \
                    --demo-surface manager --demo-page "$page" --demo-quit-after 60
            fi
        done
        # The licence gate, which is a sheet of its own.
        shot "M7-manager-license-$appearance" "$appearance" \
            --demo-surface manager --demo-page models --demo-download 0.8b \
            --demo-download-gate --demo-quit-after 60
    fi
done

ls -la "$SHOTS" | grep 'M7-' || true
