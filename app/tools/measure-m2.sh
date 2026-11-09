#!/bin/sh
# Measure the numbers in SPEC 14 for M2.
#
#   tools/measure-m2.sh
#
# Memory uses `footprint <pid>` (phys_footprint), which is what Activity
# Monitor calls "Memory". CPU uses tools/measure_cpu.py (a cumulative CPU-time
# delta), because `ps -o %cpu` averages the process's whole lifetime.
#
# The manager numbers need a window that can be opened and closed without a
# hand, so they use the demo options added for M2: `--demo-surface manager` and
# `--demo-close-after`.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
# Demo runs write history and PDF jobs; keep them out of the real store.
DATADIR=${DATADIR:-${TMPDIR:-/tmp}/yaku-demo-data}
mkdir -p "$DATADIR"

find_pid() {
    ps -Ao pid,command | grep "release/Yaku" | grep -v grep | awk '{print $1}' | head -1
}

footprint_of() {
    footprint "$1" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}'
}

run_and_measure() {
    label=$1; sleep_before=$2; cpu_window=$3; shift 3
    if [ -n "$DATADIR" ]; then
        "$BIN" --data-dir "$DATADIR" "$@" >/dev/null 2>&1 &
    else
        "$BIN" "$@" >/dev/null 2>&1 &
    fi
    sleep "$sleep_before"
    pid=$(find_pid)
    echo "--- $label (pid=$pid) ---"
    if [ -z "$pid" ]; then echo "  app not running"; return; fi
    echo "  phys_footprint: $(footprint_of "$pid")"
    echo "  cpu: $(python3 tools/measure_cpu.py "$pid" "$cpu_window")"
    kill "$pid" 2>/dev/null || true
    sleep 2
}

echo "=== 0. the app bundle (llama-server excluded) ==="
echo "  build/Perspica.app: $(du -sh build/Perspica.app | awk '{print $1}')"
echo "  Contents/MacOS/Yaku: $(du -h build/Perspica.app/Contents/MacOS/Yaku | awk '{print $1}')"

echo
echo "=== 1. idle, no window, engine never started ==="
run_and_measure "idle" 16 8 --demo-quit-after 60

echo
echo "=== 2. manager open on 翻訳, nothing typed ==="
run_and_measure "manager open" 16 10 \
    --demo-surface manager --demo-page translate --demo-quit-after 60

echo
echo "=== 3. manager open, then closed again (does memory come back) ==="
if [ -n "$DATADIR" ]; then
    "$BIN" --data-dir "$DATADIR" --demo-surface manager --demo-page translate \
        --demo-close-after 16 --demo-quit-after 60 >/dev/null 2>&1 &
else
    "$BIN" --demo-surface manager --demo-page translate \
        --demo-close-after 16 --demo-quit-after 60 >/dev/null 2>&1 &
fi
shell_pid=$!
sleep 14
pid=$(find_pid)
echo "--- manager open (pid=$pid) ---"
echo "  phys_footprint: $(footprint_of "$pid")"
sleep 8
echo "--- manager closed ---"
echo "  phys_footprint: $(footprint_of "$pid")"
sleep 4
echo "  phys_footprint (after 4s more): $(footprint_of "$pid")"
kill "$pid" 2>/dev/null || true
wait "$shell_pid" 2>/dev/null || true
sleep 2

echo
echo "=== 4. manager open, translating a paragraph (light + streaming) ==="
run_and_measure "manager translating" 16 12 \
    --demo-surface manager --demo-page translate --demo-state translating \
    --demo-text "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks that include an encoder and a decoder." \
    --demo-quit-after 60

echo
echo "=== 5. panel open, translation finished (M1 regression) ==="
run_and_measure "panel open, done" 40 10 \
    --demo-surface panel --demo-state done --demo-pin --demo-quit-after 80

echo
echo "=== 6. panel glow only (M1 regression) ==="
run_and_measure "glow only" 14 12 \
    --demo-surface panel --demo-glow 60 --demo-pin --demo-quit-after 90

echo
echo "=== 7. onboarding open ==="
run_and_measure "onboarding" 16 10 \
    --demo-surface onboarding --demo-page 1 --demo-quit-after 60

echo
echo "=== 8. settings open ==="
run_and_measure "settings" 16 10 \
    --demo-surface settings --demo-tab 一般 --demo-quit-after 60
