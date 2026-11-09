#!/bin/sh
# Measure the numbers in SPEC 14 for M4 (the screen overlay).
#
#   tools/measure-m4.sh [<png>]
#
# The overlay's own timing is measured by the app and written to
# `~/Library/Logs/Yaku/app.log`:
#
#   overlay: read N block(s) in X.XXXs
#   overlay: first block drawn X.XXXs after capture
#   overlay: all N block(s) drawn X.XXXs after capture
#
# The target (SPEC 9, 14) is the first block within 1 second and everything
# within 3 seconds, with the engine already up — the hotkey warms it while the
# user works the picker, so the demo warms it before it reads the picture.
#
# CPU is measured with tools/measure_cpu.py (a cumulative CPU-time delta),
# because `ps -o %cpu` averages the process's whole lifetime. **The screen must
# be unlocked**: while it is locked the app is not drawn and every reading is
# 0.00%.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
# Demo runs write history and PDF jobs; keep them out of the real store.
DATADIR=${DATADIR:-${TMPDIR:-/tmp}/yaku-demo-data}
mkdir -p "$DATADIR"
SAMPLES=${SAMPLES:-${TMPDIR:-/tmp}/yaku-m4}
PNG=${1:-$SAMPLES/article.png}
LOGFILE="$HOME/Library/Logs/Yaku/app.log"

find_pid() {
    ps -Ao pid,command | grep "release/Yaku" | grep -v grep | awk '{print $1}' | head -1
}

footprint_of() {
    footprint "$1" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}'
}

[ -f "$PNG" ] || {
    echo "error: $PNG not found (build the samples with tools/make-samples.swift)" >&2
    exit 1
}

echo "=== 0. the app bundle ==="
echo "  build/Perspica.app: $(du -sh build/Perspica.app | awk '{print $1}')"

echo
echo "=== 1. idle, no window, engine never started ==="
start=$(wc -l < "$LOGFILE")
if [ -n "$DATADIR" ]; then
    "$BIN" --data-dir "$DATADIR" --demo-quit-after 30 >/dev/null 2>&1 &
else
    "$BIN" --demo-quit-after 30 >/dev/null 2>&1 &
fi
shell_pid=$!
sleep 16
pid=$(find_pid)
echo "  phys_footprint: $(footprint_of "$pid")"
echo "  cpu: $(python3 tools/measure_cpu.py "$pid" 10)"
kill "$pid" 2>/dev/null || true
wait "$shell_pid" 2>/dev/null || true
sleep 2

echo
echo "=== 2. the overlay showing a picture (SPEC 4.6, 9, 14) ==="
start=$(wc -l < "$LOGFILE")
if [ -n "$DATADIR" ]; then
    "$BIN" --data-dir "$DATADIR" --demo-image "$PNG" --demo-quit-after 45 >/dev/null 2>&1 &
else
    "$BIN" --demo-image "$PNG" --demo-quit-after 45 >/dev/null 2>&1 &
fi
shell_pid=$!
# The engine warms for 3.5s, the picture is read, then the blocks stream in.
sleep 12
pid=$(find_pid)
echo "  phys_footprint: $(footprint_of "$pid")"
echo "  cpu while the overlay is up: $(python3 tools/measure_cpu.py "$pid" 15)"
kill "$pid" 2>/dev/null || true
wait "$shell_pid" 2>/dev/null || true
sleep 2
echo "--- the overlay's own timing ---"
tail -n +$((start + 1)) "$LOGFILE" | grep -E "overlay: (read|first block|all .* drawn)" || true

echo
echo "=== 3. the region picker open (SPEC 4.6 の 1) ==="
start=$(wc -l < "$LOGFILE")
if [ -n "$DATADIR" ]; then
    "$BIN" --data-dir "$DATADIR" --demo-surface overlay-picker --demo-quit-after 40 >/dev/null 2>&1 &
else
    "$BIN" --demo-surface overlay-picker --demo-quit-after 40 >/dev/null 2>&1 &
fi
shell_pid=$!
sleep 8
pid=$(find_pid)
echo "  phys_footprint: $(footprint_of "$pid")"
echo "  cpu: $(python3 tools/measure_cpu.py "$pid" 15)"
kill "$pid" 2>/dev/null || true
wait "$shell_pid" 2>/dev/null || true
sleep 2

echo
echo "=== 4. the settings 画面翻訳 tab ==="
if [ -n "$DATADIR" ]; then
    "$BIN" --data-dir "$DATADIR" --demo-surface settings --demo-tab 画面翻訳 \
        --demo-quit-after 30 >/dev/null 2>&1 &
else
    "$BIN" --demo-surface settings --demo-tab 画面翻訳 --demo-quit-after 30 >/dev/null 2>&1 &
fi
shell_pid=$!
sleep 8
pid=$(find_pid)
echo "  phys_footprint: $(footprint_of "$pid")"
echo "  cpu: $(python3 tools/measure_cpu.py "$pid" 10)"
kill "$pid" 2>/dev/null || true
wait "$shell_pid" 2>/dev/null || true
sleep 2
