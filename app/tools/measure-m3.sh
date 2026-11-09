#!/bin/sh
# Measure the numbers in SPEC 14 for M3 (PDF).
#
#   tools/measure-m3.sh [pdf-python]
#
# The PDF numbers need a real job, so they use `--demo-pdf`. The interpreter is
# the argument, or `--pdf-python`'s default (the installed environment), or
# `$YAKU_PDF_PYTHON`. Use the prototype's environment while the worker has not
# been installed:
#
#   tools/measure-m3.sh ~/docs/agentic-os/lab/plamo-pdf-translate/.venv/bin/python
#
# Memory uses `footprint <pid>` (phys_footprint), which is what Activity
# Monitor calls "Memory". CPU uses tools/measure_cpu.py (a cumulative CPU-time
# delta), because `ps -o %cpu` averages the process's whole lifetime. The
# worker's CPU is measured on its own pid; the app's is measured on the app.
set -eu
cd "$(dirname "$0")/.."

BIN=.build/arm64-apple-macosx/release/Yaku
# Demo runs write history and PDF jobs; keep them out of the real store.
DATADIR=${DATADIR:-${TMPDIR:-/tmp}/yaku-demo-data}
mkdir -p "$DATADIR"
PDF=${PDF:-"${TMPDIR:-/tmp}/yaku-m3-attention/attention.pdf"}
PYTHON=${1:-${YAKU_PDF_PYTHON:-}}
PY_ARGS=${PYTHON:+--pdf-python "$PYTHON"}
PAGES=${PAGES:-1}

find_app_pid() {
    ps -Ao pid,command | grep "release/Yaku" | grep -v grep | awk '{print $1}' | head -1
}

find_worker_pid() {
    ps -Ao pid,command | grep "translate_pdf.py" | grep -v grep | awk '{print $1}' | head -1
}

footprint_of() {
    footprint "$1" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}'
}

[ -f "$PDF" ] || {
    echo "error: $PDF not found (copy the Attention PDF there first)" >&2
    exit 1
}

echo "=== 0. the app bundle and the worker ==="
echo "  build/Perspica.app: $(du -sh build/Perspica.app | awk '{print $1}')"
if [ -n "$PYTHON" ]; then
    echo "  worker interpreter: $PYTHON"
fi
if [ -d "$HOME/Library/Application Support/Yaku/pdf-worker" ]; then
    echo "  installed worker: $(du -sh "$HOME/Library/Application Support/Yaku/pdf-worker" | awk '{print $1}')"
fi

echo
echo "=== 1. a real PDF job ($PAGES page(s)), app and worker CPU ==="
# shellcheck disable=SC2086
if [ -n "$DATADIR" ]; then
    "$BIN" --data-dir "$DATADIR" $PY_ARGS --demo-pdf "$PDF" --pdf-pages "$PAGES" \
        --demo-quit-after 600 >/dev/null 2>&1 &
else
    "$BIN" $PY_ARGS --demo-pdf "$PDF" --pdf-pages "$PAGES" --demo-quit-after 600 >/dev/null 2>&1 &
fi
shell_pid=$!

# Wait for the worker to appear, then for the paragraph stage to begin.
worker=""
i=0
while [ "$i" -lt 60 ]; do
    worker=$(find_worker_pid)
    [ -n "$worker" ] && break
    sleep 2
    i=$((i + 1))
done
if [ -z "$worker" ]; then
    echo "  the worker never started"
else
    app=$(find_app_pid)
    echo "--- app (pid=$app) ---"
    echo "  phys_footprint: $(footprint_of "$app")"
    echo "  cpu: $(python3 tools/measure_cpu.py "$app" 20)"
    echo "--- worker (pid=$worker) ---"
    echo "  cpu: $(python3 tools/measure_cpu.py "$worker" 20)"
    echo "  phys_footprint: $(footprint_of "$worker")"
fi
kill "$shell_pid" 2>/dev/null || true
sleep 3
# The app stops the worker on the way out; make sure nothing is left.
left=$(find_worker_pid || true)
[ -z "$left" ] || echo "  warning: worker $left still running"

echo
echo "=== 2. the island in its activity state (SPEC 4.5) ==="
# shellcheck disable=SC2086
if [ -n "$DATADIR" ]; then
    "$BIN" --data-dir "$DATADIR" --demo-surface notch --demo-state activity \
        --demo-quit-after 90 >/dev/null 2>&1 &
else
    "$BIN" --demo-surface notch --demo-state activity --demo-quit-after 90 >/dev/null 2>&1 &
fi
sleep 8
pid=$(find_app_pid)
echo "  phys_footprint: $(footprint_of "$pid")"
echo "  cpu: $(python3 tools/measure_cpu.py "$pid" 20)"
kill "$pid" 2>/dev/null || true
sleep 2

echo
echo "=== 3. the panel with a PDF row (SPEC 4.2) ==="
# shellcheck disable=SC2086
if [ -n "$DATADIR" ]; then
    "$BIN" --data-dir "$DATADIR" --demo-surface panel --demo-state pdf-running \
        --demo-pin --demo-quit-after 90 >/dev/null 2>&1 &
else
    "$BIN" --demo-surface panel --demo-state pdf-running \
        --demo-pin --demo-quit-after 90 >/dev/null 2>&1 &
fi
sleep 8
pid=$(find_app_pid)
echo "  phys_footprint: $(footprint_of "$pid")"
echo "  cpu: $(python3 tools/measure_cpu.py "$pid" 20)"
kill "$pid" 2>/dev/null || true
sleep 2

echo
echo "=== 4. the manager's PDF page (SPEC 4.4) ==="
# shellcheck disable=SC2086
if [ -n "$DATADIR" ]; then
    "$BIN" --data-dir "$DATADIR" --demo-surface manager --demo-page pdf \
        --demo-quit-after 90 >/dev/null 2>&1 &
else
    "$BIN" --demo-surface manager --demo-page pdf --demo-quit-after 90 >/dev/null 2>&1 &
fi
sleep 8
pid=$(find_app_pid)
echo "  phys_footprint: $(footprint_of "$pid")"
echo "  cpu: $(python3 tools/measure_cpu.py "$pid" 20)"
kill "$pid" 2>/dev/null || true
sleep 2
