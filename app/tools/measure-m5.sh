#!/bin/sh
# Measure every number in SPEC 14, for M5.
#
#   tools/measure-m5.sh
#
# Memory uses `footprint <pid>` (phys_footprint), which is what Activity
# Monitor calls "Memory". CPU uses tools/measure_cpu.py (a cumulative CPU-time
# delta), because `ps -o %cpu` averages the process's whole lifetime. **The
# screen must be unlocked**: while it is locked nothing is drawn and every CPU
# reading is 0.00%.
#
# Run this on an idle machine. `tools/measure_cpu.py` reports the app's own CPU
# time, but a busy Mac makes every window of the measurement noisier, and the
# translating row in particular moves by a few points between runs.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
# Demo runs write history and PDF jobs; keep them out of the real store.
DATADIR=${DATADIR:-${TMPDIR:-/tmp}/yaku-demo-data}
mkdir -p "$DATADIR"
LOGFILE="$HOME/Library/Logs/Yaku/app.log"

find_pid() {
    ps -Ao pid,command | grep "release/Yaku" | grep -v grep | awk '{print $1}' | head -1
}

footprint_of() {
    footprint "$1" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}'
}

run_and_measure() {
    label=$1; sleep_before=$2; cpu_window=$3; shift 3
    "$BIN" --data-dir "$DATADIR" "$@" >/dev/null 2>&1 &
    shell_pid=$!
    sleep "$sleep_before"
    pid=$(find_pid)
    echo "--- $label (pid=$pid) ---"
    if [ -z "$pid" ]; then echo "  app not running"; return; fi
    echo "  phys_footprint: $(footprint_of "$pid")"
    echo "  cpu: $(python3 tools/measure_cpu.py "$pid" "$cpu_window")"
    kill "$pid" 2>/dev/null || true
    wait "$shell_pid" 2>/dev/null || true
    sleep 2
}

echo "=== 1. the app bundle (SPEC 14 の 1 行目) ==="
echo "  build/Yaku.app: $(du -sh build/Yaku.app | awk '{print $1}')"
echo "  main binary:    $(du -sh build/Yaku.app/Contents/MacOS/Yaku | awk '{print $1}')"
if [ -e build/Yaku.app/Contents/Resources/llama-server ]; then
    echo "  llama-server is bundled: $(du -sh build/Yaku.app/Contents/Resources/llama-server | awk '{print $1}')"
else
    echo "  llama-server is not bundled (the app uses the one on PATH)"
fi

echo
echo "=== 2. idle, no window, engine never started (30s) ==="
run_and_measure "idle" 20 10 --demo-quit-after 60

echo
echo "=== 3. panel open, translation finished, no light ==="
run_and_measure "panel open, done" 40 10 \
    --demo-surface panel --demo-state done --demo-pin --demo-quit-after 80

echo
echo "=== 4. glow only, no translation ==="
run_and_measure "glow only" 14 12 \
    --demo-surface panel --demo-glow 60 --demo-pin --demo-quit-after 90

echo
echo "=== 5. translating (light + the text appearing) ==="
echo "  This is the number for the SPEC 14 row 「訳している最中の CPU」. What it"
echo "  costs is the reveal redrawing the translation (M5.md 4.2): the publish"
echo "  interval makes no difference, and the source text's height is measured"
echo "  once instead of on every frame. Run it more than once; a busy Mac moves"
echo "  it by a point or two."
for i in 1 2 3; do
    run_and_measure "translating #$i" 16 12 \
        --demo-surface panel --demo-state translating --demo-pin --demo-quit-after 60
done

echo
echo "=== 6. engine startup, 0.8B (SPEC 14 の最後から 2 番目) ==="
start=$(wc -l < "$LOGFILE")
for i in 1 2 3 4 5; do
    "$BIN" --data-dir "$DATADIR" --demo-translate "The dominant sequence transduction models are based on complex recurrent networks." \
        --demo-quit-after 40 >/dev/null 2>&1 || true
    sleep 1
done
tail -n +$((start + 1)) "$LOGFILE" | grep -oE "engine ready server=[0-9]+ in [0-9.]+s" || true

echo
echo "=== 7. hotkey → panel / HUD, and the first character ==="
echo "  hotkey → panel is logged by the app itself; the hotkey is not pressed"
echo "  here (SPEC 12 のキーは人の操作が要る). --demo-surface opens the same"
echo "  window through the same code path and logs the same line."
start=$(wc -l < "$LOGFILE")
"$BIN" --data-dir "$DATADIR" --demo-surface panel --demo-state translating --demo-pin \
    --demo-quit-after 40 >/dev/null 2>&1 &
shell_pid=$!
sleep 30
pid=$(find_pid)
kill "$pid" 2>/dev/null || true
wait "$shell_pid" 2>/dev/null || true
sleep 2
tail -n +$((start + 1)) "$LOGFILE" | grep -E "panel open \(" || true
tail -n +$((start + 1)) "$LOGFILE" | grep -oE "translate first piece id=[0-9A-F]+ surface=[a-z]+ in [0-9.]+s" || true

echo
echo "=== 8. PDF, 15 pages (SPEC 14 の最後の行) ==="
# The whole document, so **no `--pdf-pages`**. That option is a page *list*
# ("1,2,1-,-3,3-5"), so `--pdf-pages 15` means page 15 only and finishes in
# about 12s; the 15-page row needs every page. Point PDF at the paper and give
# the worker's interpreter as the first argument:
#
#   PDF=…/attention.pdf tools/measure-m5.sh ~/…/.venv/bin/python
#
# Without an argument it falls back to the installed worker, or to
# $YAKU_PDF_PYTHON while the worker has not been installed yet.
PDF=${PDF:-${TMPDIR:-/tmp}/yaku-m3-attention/attention.pdf}
PYTHON=${1:-${YAKU_PDF_PYTHON:-}}
PY_ARGS=${PYTHON:+--pdf-python "$PYTHON"}
if [ ! -f "$PDF" ]; then
    echo "  skipped: $PDF not found (set PDF=<path to the paper>)"
else
    start=$(wc -l < "$LOGFILE")
    # shellcheck disable=SC2086
    "$BIN" --data-dir "$DATADIR" $PY_ARGS --demo-pdf "$PDF" --demo-quit-after 600 \
        >/dev/null 2>&1 &
    shell_pid=$!
    # The job's own line has the time (`total_seconds` from BabelDOC), and it
    # arrives whether or not the run ends in `done` or `failed`.
    waited=0
    line=""
    while [ "$waited" -lt 600 ]; do
        line=$(tail -n +$((start + 1)) "$LOGFILE" | grep -E "pdf: done .* in [0-9.]+s" | tail -1 || true)
        [ -n "$line" ] && break
        sleep 5
        waited=$((waited + 5))
    done
    if [ -n "$line" ]; then
        echo "  $line"
    else
        echo "  no result after ${waited}s; tail of the log:"
        tail -n +$((start + 1)) "$LOGFILE" | grep "pdf:" | tail -5 || true
    fi
    pid=$(find_pid)
    kill "$pid" 2>/dev/null || true
    wait "$shell_pid" 2>/dev/null || true
    sleep 3
    # The app stops the worker on the way out; make sure nothing is left.
    left=$(ps -Ao pid,command | grep "translate_pdf.py" | grep -v grep | awk '{print $1}' | head -1 || true)
    [ -z "$left" ] || echo "  warning: worker $left still running"
fi
