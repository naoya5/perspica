#!/bin/sh
# Makes the two web fonts the landing page and the movie use.
#
# The headings are set in Shippori Mincho (SIL Open Font License 1.1). The full
# fonts are 8 MB each, so only the characters that appear in the page and in the
# movie are kept: run this again after you change their text.
#
#   marketing/fonts/subset.sh        # writes site/assets/fonts/*.woff2
#
# Needs curl and uv (for fonttools). The full fonts are fetched into a
# temporary folder and are not kept in the repository.
set -eu
cd "$(dirname "$0")/../.."

SOURCE=https://raw.githubusercontent.com/google/fonts/main/ofl/shipporimincho
CACHE="${TMPDIR:-/tmp}/perspica-fonts"
OUT=site/assets/fonts
mkdir -p "$CACHE" "$OUT"

for name in ShipporiMincho-Bold ShipporiMincho-ExtraBold; do
    [ -s "$CACHE/$name.ttf" ] || curl -fsSL -o "$CACHE/$name.ttf" "$SOURCE/$name.ttf"
done
curl -fsSL -o "$OUT/OFL.txt" "$SOURCE/OFL.txt"

# Every character of the two documents, plus plain ASCII for good measure.
TEXT="$CACHE/text.txt"
cat site/index.html marketing/movie/movie.html > "$TEXT"
printf ' !"#$%%&()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]_abcdefghijklmnopqrstuvwxyz{|}~' >> "$TEXT"

for name in ShipporiMincho-Bold ShipporiMincho-ExtraBold; do
    uvx --quiet --from fonttools --with brotli pyftsubset "$CACHE/$name.ttf" \
        --text-file="$TEXT" --flavor=woff2 --layout-features='*' \
        --output-file="$OUT/$name.woff2"
    echo "$OUT/$name.woff2 $(wc -c < "$OUT/$name.woff2") bytes"
done
