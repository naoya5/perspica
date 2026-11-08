#!/bin/sh
# Capture the M6 overlay surfaces (SPEC 15).
#
#   swiftc -O tools/winid.swift -o /tmp/winid     # once
#   swiftc -O tools/opaque.swift -o /tmp/opaque   # once
#   tools/capture-m6.sh [groups]
#
# Groups: list regression
#
# `list` is the documentation page the wrapped-line fix is about (M6.md 2): its
# bullets' second lines hang under the text, and before the fix the last one was
# cut off and translated on its own. `regression` re-shoots the five samples the
# earlier milestones are checked on, so the same run proves they did not break.
#
# **The screen must be unlocked**, and the app's window must not be covered:
# these are region captures, not window captures, for the reason in
# tools/capture-m5.sh.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
SHOTS=../docs/checks/shots
WINID=${WINID:-/tmp/winid}
SAMPLES=${SAMPLES:-${TMPDIR:-/tmp}/yaku-m6}
DATADIR=${DATADIR:-${TMPDIR:-/tmp}/yaku-demo-data}
mkdir -p "$DATADIR" "$SHOTS"
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

# shot <name> [WAIT=<seconds>] -- <args...>
shot() {
    name=$1; shift
    wait_seconds=${WAIT:-10}
    if [ "${1:-}" != "" ] && [ "${1#WAIT=}" != "$1" ]; then
        wait_seconds=${1#WAIT=}
        shift
    fi
    "$BIN" --appearance light --demo-backdrop light --data-dir "$DATADIR" "$@" \
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

# The page the wrapped-line fix is on: four bullets whose second line hangs
# under the text, the last one short enough to have been cut off before M6.
if wanted list; then
    shot "M6-overlay-list-light" WAIT=12 \
        --demo-image "$SAMPLES/list.png" --demo-quit-after 60
fi

# The samples the earlier milestones are checked on, re-shot so the same run
# shows they still read the same (SPEC 9; M5.md 3.1, 9.2).
if wanted regression; then
    for sample in article columns ui mixed code; do
        shot "M6-overlay-$sample-light" WAIT=12 \
            --demo-image "$SAMPLES/$sample.png" --demo-quit-after 60
    done
fi

ls -la "$SHOTS" | grep 'M6-' || true
