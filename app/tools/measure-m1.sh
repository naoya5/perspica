#!/bin/sh
# Measure the numbers in SPEC 14 for M1.
#
#   tools/measure-m1.sh
#
# Memory uses `footprint <pid>` (phys_footprint), which is what Activity
# Monitor calls "Memory". CPU uses tools/measure_cpu.py (a cumulative CPU-time
# delta), because `ps -o %cpu` averages the process's whole lifetime.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
WINID=${WINID:-/tmp/winid}

run_and_measure() {
    label=$1; sleep_before=$2; cpu_window=$3; shift 3
    "$BIN" "$@" >/dev/null 2>&1 &
    shell_pid=$!
    sleep "$sleep_before"
    pid=$(ps -Ao pid,command | grep "release/Yaku" | grep -v grep | awk '{print $1}' | head -1)
    echo "--- $label (pid=$pid) ---"
    if [ -z "$pid" ]; then echo "  app not running"; return; fi
    echo "  phys_footprint: $(footprint "$pid" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}')"
    echo "  rss: $(ps -o rss= -p "$pid" | awk '{printf "%.1f MB", $1/1024}')"
    echo "  cpu: $(python3 tools/measure_cpu.py "$pid" "$cpu_window")"
    kill "$pid" 2>/dev/null || true
    sleep 2
}

echo "=== 1. idle, panel closed, engine never started ==="
run_and_measure "idle" 18 8 --demo-quit-after 60

echo
echo "=== 2. panel open, translation finished (no light) ==="
run_and_measure "panel open, done" 40 10 \
    --demo-surface panel --demo-state done --demo-pin --demo-quit-after 80

echo
echo "=== 3. panel open, empty ==="
run_and_measure "panel open, empty" 12 10 \
    --demo-surface panel --demo-state empty --demo-pin --demo-quit-after 60

echo
echo "=== 4. glow only (--demo-glow) ==="
run_and_measure "glow only" 14 12 \
    --demo-surface panel --demo-glow 60 --demo-pin --demo-quit-after 90

echo
echo "=== 5. panel open, translating (light + streaming) ==="
run_and_measure "translating" 16 12 \
    --demo-surface panel --demo-state translating --demo-pin --demo-quit-after 60 \
    --demo-text "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks that include an encoder and a decoder."
