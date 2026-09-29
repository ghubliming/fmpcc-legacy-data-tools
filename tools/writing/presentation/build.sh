#!/usr/bin/env bash
# Build the deck into a new, immutable output folder (never edit or delete a build afterwards):
#   output/<YYYYMMDD_HHMMSS>_presentation_<rev>_<TAG>/
#     presentation.html  self-contained: figures, GIFs, fonts and maths inside; opens offline
#     presentation.pdf   backup for a foreign laptop (a GIF shows one frame)
#     BUILD_NOTES.md     what was built from what, and the checks
# Usage:  tools/build.sh v2.0 NEAR_FINAL        new build folder (a new major/content revision)
#         tools/build.sh --hot v2.1 "what"      hot update: small fix, overwrites the LATEST build folder in
#                                               place and appends the revision to its BUILD_NOTES history
set -euo pipefail
hot=0; [ "${1:-}" = "--hot" ] && { hot=1; shift; }
rev="${1:?revision, e.g. v1.0}"; tag="${2:?tag or, with --hot, a short description}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"; DECK="$HERE/deck"
command -v quarto >/dev/null && command -v decktape >/dev/null && command -v chromium >/dev/null \
  || { echo "toolchain missing: run tools/install_tools.sh"; exit 1; }

python3 "$HERE/tools/sync_figures.py" --check

if [ "$hot" = 1 ]; then
  out="$(ls -d "$HERE"/output/*_presentation_* 2>/dev/null | sort | tail -1)"
  [ -n "$out" ] || { echo "no build to hot-update"; exit 1; }
  history="$(sed -n '/^## Hot updates/,$p' "$out/BUILD_NOTES.md" 2>/dev/null || true)"
  first="$(sed -n 's/^- \*\*Revision:\*\* \([^ ]*\).*/\1/p' "$out/BUILD_NOTES.md" | head -1)"
else
  stamp="$(date +%Y%m%d_%H%M%S)"
  out="$HERE/output/${stamp}_presentation_${rev}_${tag}"
  mkdir "$out"
fi

(cd "$DECK" && quarto render presentation.qmd --quiet)
cp "$DECK/_build/presentation.html" "$out/presentation.html"

# The PDF is printed with the network blocked, so it shows exactly what an offline laptop shows.
decktape reveal --chrome-path "$(command -v chromium)" --chrome-arg=--no-sandbox \
  --chrome-arg=--proxy-server=127.0.0.1:9 --chrome-arg='--proxy-bypass-list=<-loopback>' \
  --size 1600x900 --load-pause 1500 "file://$out/presentation.html" "$out/presentation.pdf" >/dev/null

# Offline check: every host named anywhere in the page (script strings included), minus hosts that
# only appear as XML namespaces or library credits. Anything left could be fetched at runtime.
inert='www.w3.org|revealjs.com|github.com|hakim.se|lab.hakim.se|marked.js.org|clipboardjs.com'
ext="$(grep -o -E 'https?://[A-Za-z0-9.-]+' "$out/presentation.html" | sed -E 's#^https?://##' | sort -u \
       | grep -v -x -E "$inert" || true)"
pages="$(python3.14 -c "import pypdf,sys; print(len(pypdf.PdfReader(sys.argv[1]).pages))" "$out/presentation.pdf" 2>/dev/null || echo '?')"
size() { du -h "$1" | cut -f1; }

cat > "$out/BUILD_NOTES.md" <<NOTES
# Build notes — \`$(basename "$out")\`

- **Revision:** $rev · **Tag:** $tag · **Built:** $(date '+%Y-%m-%d %H:%M:%S')
- **Thesis source (pinned):** \`Working_Space/RELEASE/output/$(cat "$DECK/PINNED_RELEASE")\`
- **Template:** UNCERTAIN — interim look by the author's instruction; the advisor's template scheme is pending.
- **Toolchain:** Quarto $(quarto --version) · decktape $(decktape version 2>/dev/null | head -1 | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+' | head -1) · $(chromium --version | cut -d' ' -f1-2)
- **Files:** \`presentation.html\` $(size "$out/presentation.html") · \`presentation.pdf\` $(size "$out/presentation.pdf"), $pages slides
- **Offline check (hosts the page could fetch; PDF printed with the network blocked):** $( [ -z "$ext" ] && echo "none — self-contained" || { echo; echo '```'; echo "$ext"; echo '```'; } )

Not a compile of the thesis; the deck quotes the pinned release as written.
NOTES
if [ "$hot" = 1 ]; then
  { echo; [ -n "$history" ] && echo "$history" || echo "## Hot updates (folder named after ${first:-its first revision}; files overwritten in place)"
    echo "- **$rev** · $(date '+%Y-%m-%d %H:%M') · $tag"; } >> "$out/BUILD_NOTES.md"
fi
echo "built: $out"
ls -la "$out"
