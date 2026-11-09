# Used by the verify-yaku helper: capture every onscreen Yaku window and keep
# the ones with something drawn in them, most drawn first.
#
# AppKit keeps some of Yaku's windows "onscreen" while they show nothing (the
# panel when it is closed, the island when there is no notch work), and
# `CGWindowListCopyWindowInfo` reports them as onscreen=true. Picking by size
# alone named the empty island as the main shot, so each capture is measured
# by its opaque pixels instead (tools/opaque.swift).
#
# Needs: WINID (tools/winid.swift), OPAQUE (tools/opaque.swift), SHOTS.

OPAQUE=${OPAQUE:-${TMPDIR:-/tmp}/yaku-verify-tools-$(id -u)/opaque}
[ -x "$OPAQUE" ] || {
    echo "error: $OPAQUE not found; run: swiftc -O tools/opaque.swift -o $OPAQUE" >&2
    exit 1
}

# Sampled opaque pixels (every other pixel) below this are an empty window or
# the closed island over the notch (about 3,600), not a surface.
MIN_OPAQUE=${MIN_OPAQUE:-8000}

# `--demo-backdrop` covers each screen with a window of exactly the screen's
# size, which `capture_windows` would otherwise pick as the most drawn surface.
# Window names cannot be read without screen recording permission, so a window
# matching a screen frame is treated as the backdrop. Only the M5 captures turn
# this on: the M4 region picker is screen-sized too, and it is a real surface.
if [ -n "${EXCLUDE_SCREEN_SIZED:-}" ]; then
    SCREEN_FRAMES=$(printf 'import AppKit\nfor s in NSScreen.screens { print("\\(Int(s.frame.width))x\\(Int(s.frame.height))", terminator: " ") }\n' \
        | swift - 2>/dev/null | tail -1)
fi
SCREEN_FRAMES=${SCREEN_FRAMES:-}
export SCREEN_FRAMES

capture_windows() {
    name=$1
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/yaku-shot.XXXXXX")
    ids=$("$WINID" Yaku 2>/dev/null | awk -v screens="$SCREEN_FRAMES" '{
        for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
        if (v["onscreen"] != "true") next
        if (v["w"] == 500 && v["h"] == 500) next
        if (v["w"] < 120 || v["h"] < 24) next
        n = split(screens, s, " ")
        for (i = 1; i <= n; i++) if (s[i] == v["w"] "x" v["h"]) next
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

# The union of the screens, as "x y w h". A region that reaches outside it is
# clipped by `screencapture` and the picture loses an edge of the window.
if [ -z "${SCREEN_UNION:-}" ]; then
    SCREEN_UNION=$(printf 'import AppKit\nlet f = NSScreen.screens.dropFirst().reduce(NSScreen.screens[0].frame) { $0.union($1.frame) }\nprint(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))\n' \
        | swift - 2>/dev/null | tail -1)
fi
export SCREEN_UNION

# The window the app is actually showing, as "x y w h", picked the same way
# capture_windows picks it (most drawn pixels first). Used by capture_region.
content_rect() {
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/yaku-rect.XXXXXX")
    "$WINID" Yaku 2>/dev/null | awk -v screens="$SCREEN_FRAMES" '{
        for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
        if (v["onscreen"] != "true") next
        if (v["w"] == 500 && v["h"] == 500) next
        if (v["w"] < 120 || v["h"] < 24) next
        n = split(screens, s, " ")
        for (i = 1; i <= n; i++) if (s[i] == v["w"] "x" v["h"]) next
        print v["x"], v["y"], v["w"], v["h"], v["id"]
    }' | while read -r x y w h id; do
        if screencapture -x -o -l "$id" "$tmpdir/$id.png" 2>/dev/null; then
            printf '%s %s %s %s %s\n' "$("$OPAQUE" "$tmpdir/$id.png")" "$x" "$y" "$w" "$h" >> "$tmpdir/list"
        fi
    done
    if [ -f "$tmpdir/list" ]; then
        sort -rn "$tmpdir/list" | awk -v min="$MIN_OPAQUE" '$1 >= min {print $2, $3, $4, $5; exit}'
    fi
    rm -rf "$tmpdir"
}

# Capture a screen region around the app's main window, so **what is behind
# the glass** is in the picture. `screencapture -l <id>` renders the window on
# its own and composites it over nothing, which turns Liquid Glass into flat
# grey; the region grab instead shows the window as the screen shows it
# (SPEC 15, M5).
#
#   capture_region <name> [padding]
capture_region() {
    name=$1
    pad=${2:-${REGION_PAD:-60}}
    rect=$(content_rect)
    if [ -z "$rect" ]; then
        echo "[$name] no window with content found" >&2
        return 1
    fi
    set -- $rect
    winw=$3; winh=$4
    x=$(( $1 - pad )); y=$(( $2 - pad ))
    w=$(( $3 + pad * 2 )); h=$(( $4 + pad * 2 ))
    # `screencapture -R` takes the coordinates of the whole display space,
    # which starts at a negative x when a second display sits to the left.
    # Anything outside the union of the screens is simply not captured, so the
    # region is pulled back inside it first; otherwise the window loses an edge.
    set -- $SCREEN_UNION
    sx=$1; sy=$2; sw=$3; sh=$4
    [ "$x" -lt "$sx" ] && { w=$(( w - (sx - x) )); x=$sx; }
    [ "$y" -lt "$sy" ] && { h=$(( h - (sy - y) )); y=$sy; }
    [ $(( x + w )) -gt $(( sx + sw )) ] && w=$(( sx + sw - x ))
    [ $(( y + h )) -gt $(( sy + sh )) ] && h=$(( sy + sh - y ))
    if screencapture -x -o -R "$x,$y,$w,$h" "$SHOTS/$name.png"; then
        echo "[$name] region ${w}x${h} at ${x},${y} (window ${winw}x${winh})"
    else
        echo "[$name] screencapture failed" >&2
    fi
}

