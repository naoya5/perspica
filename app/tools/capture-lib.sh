# Shared by capture-m2/m3/m4.sh: capture every onscreen Yaku window and keep
# the ones with something drawn in them, most drawn first.
#
# AppKit keeps some of Yaku's windows "onscreen" while they show nothing (the
# panel when it is closed, the island when there is no notch work), and
# `CGWindowListCopyWindowInfo` reports them as onscreen=true. Picking by size
# alone named the empty island as the main shot, so each capture is measured
# by its opaque pixels instead (tools/opaque.swift).
#
# Needs: WINID (tools/winid.swift), OPAQUE (tools/opaque.swift), SHOTS.

OPAQUE=${OPAQUE:-/tmp/opaque}
[ -x "$OPAQUE" ] || {
    echo "error: $OPAQUE not found; run: swiftc -O tools/opaque.swift -o $OPAQUE" >&2
    exit 1
}

# Sampled opaque pixels (every other pixel) below this are an empty window or
# the closed island over the notch (about 3,600), not a surface.
MIN_OPAQUE=${MIN_OPAQUE:-8000}

capture_windows() {
    name=$1
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/yaku-shot.XXXXXX")
    ids=$("$WINID" Yaku 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
        if (v["onscreen"] != "true") next
        if (v["w"] == 500 && v["h"] == 500) next
        if (v["w"] < 120 || v["h"] < 24) next
        print v["id"]
    }')
    for id in $ids; do
        if screencapture -x -o -l "$id" "$tmpdir/$id.png" 2>/dev/null; then
            printf '%s %s\n' "$("$OPAQUE" "$tmpdir/$id.png")" "$id" >> "$tmpdir/list"
        fi
    done
    n=0
    if [ -f "$tmpdir/list" ]; then
        for id in $(sort -rn "$tmpdir/list" | awk -v min="$MIN_OPAQUE" '$1 >= min {print $2}'); do
            n=$((n + 1))
            if [ "$n" -gt 1 ]; then suffix="-$n"; else suffix=""; fi
            mv "$tmpdir/$id.png" "$SHOTS/$name$suffix.png"
            echo "[$name$suffix] window $id"
        done
    fi
    rm -rf "$tmpdir"
    [ "$n" -gt 0 ] || echo "[$name] no window with content found" >&2
}
