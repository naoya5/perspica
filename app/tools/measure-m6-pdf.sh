#!/bin/sh
# M6: translate a PDF with the worker and print one line of numbers.
#
#   tools/measure-m6-pdf.sh <label> <input.pdf> <out-dir> [extra worker args...]
#
# Prints:  label<TAB>seconds<TAB>paragraphs<TAB>cache hits<TAB>errors<TAB>done
#
# `seconds` is the worker's own `done` event (the same figure the app shows), so
# it is comparable between runs. `paragraphs` and `cache hits` come from
# pdf2zh-next's own clitranslator log lines, which is the count of work actually
# done: a run that translated nothing would show 0 and be caught here rather
# than looking fast (benchmark-checklist question 7). `errors` counts the
# worker's error events, and any non-zero value makes the run unusable
# (question 4).
#
# The engine URL and key come from the environment so no key lands on a command
# line: YAKU_ENGINE_URL and YAKU_ENGINE_API_KEY.
#
# **The cache is the trap.** pdf2zh-next keeps a translation cache at
# `~/.cache/pdf2zh_next/cache.v1.db` (hard-coded, no setting), so a second run of
# the same document skips almost all the work and looks fast. This script runs
# every side under its own `HOME` inside $TMPDIR with that cache **empty**, so
# both sides translate every paragraph. BabelDOC's own cache holds the fonts and
# layout model and is symlinked to the real one, so nothing is re-downloaded.
# `WARM=1` keeps the cache instead, which is what a second run of the same
# document in the app looks like.
set -eu
cd "$(dirname "$0")/../.."

label=$1; input=$2; out=$3; shift 3
: "${YAKU_ENGINE_URL:?set YAKU_ENGINE_URL}"
: "${YAKU_ENGINE_API_KEY:?set YAKU_ENGINE_API_KEY}"

PY=${PDF_PYTHON:-$HOME/Library/Application Support/Yaku/pdf-worker/bin/python}
# Which copy of the worker to run. The baseline side of an A/B points this at the
# scripts from the commit being compared against, so both sides are the code that
# actually ran (benchmark-checklist question 2), not today's code with today's
# flags turned off.
WORKER=${WORKER_DIR:-pdf-worker}
REAL_HOME=$HOME
mkdir -p "$out"

# A private HOME per run, so the translation cache starts empty and stays out of
# the user's own cache. Only `.cache/babeldoc` is shared, and only read.
FAKE_HOME=${FAKE_HOME:-${TMPDIR:-/tmp}/yaku-m6-home}
mkdir -p "$FAKE_HOME/.cache"
if [ ! -e "$FAKE_HOME/.cache/babeldoc" ]; then
    ln -s "$REAL_HOME/.cache/babeldoc" "$FAKE_HOME/.cache/babeldoc"
fi
if [ "${WARM:-0}" != "1" ]; then
    rm -f "$FAKE_HOME/.cache/pdf2zh_next/cache.v1.db" \
          "$FAKE_HOME/.cache/pdf2zh_next/cache.v1.db-wal" \
          "$FAKE_HOME/.cache/pdf2zh_next/cache.v1.db-shm"
fi

started=$(date +%s.%N)
HOME="$FAKE_HOME" "$PY" "$WORKER/translate_pdf.py" "$input" \
    --engine-url "$YAKU_ENGINE_URL" --output "$out" "$@" \
    > "$out/events.jsonl" 2> "$out/worker.log" || true
finished=$(date +%s.%N)

python3 - "$label" "$started" "$finished" "$out" <<'PY'
import json, pathlib, re, sys
label, started, finished, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), pathlib.Path(sys.argv[4])
seconds = errors = None
for line in (out / "events.jsonl").read_text(errors="replace").splitlines():
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("type") == "done":
        seconds = event.get("seconds")
    elif event.get("type") == "error":
        errors = event.get("message")
log = (out / "worker.log").read_text(errors="replace")
# pdf2zh-next logs through `rich`, which wraps the count onto its own line, so
# the whitespace is collapsed before the count is read.
flat = " ".join(log.split())
paragraphs = re.findall(r"translate call base_translator\.py:\d+ count: (\d+)", flat)
cached = re.findall(r"cache base_translator\.py:\d+ call count: (\d+)", flat)
print("\t".join([
    label,
    f"{seconds if seconds is not None else finished - started:.2f}",
    paragraphs[-1] if paragraphs else "0",
    cached[-1] if cached else "0",
    "0" if errors is None else f"1({errors[:40]})",
    "done" if seconds is not None else "NO DONE EVENT",
]))
PY
