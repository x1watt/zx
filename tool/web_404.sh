#!/usr/bin/env bash
# Makes the 404 page of the site from the page of the web version, so that
# a link with an archive's address after the page's
# (https://x1watt.github.io/zx/online/https://example.org/a.zx) opens the
# app: GitHub Pages has no file at that path and serves 404.html, whose
# base element (/zx/online/) loads the app, which reads the address from
# its location (app/lib/src/web/web_services.dart, linkParameters). Any
# other missing path goes to the start page of the site.
#
# Usage: tool/web_404.sh ONLINE_INDEX_HTML OUT_404_HTML
set -euo pipefail
in=$1 out=$2
base=$(sed -n 's/.*<base href="\([^"]*\)".*/\1/p' "$in" | head -1)
[ -n "$base" ] || { echo "web_404: no base href in $in" >&2; exit 1; }
site=${base%online/}
guard="<script>if (location.pathname.indexOf('$base') !== 0) location.replace('$site');</script>"
awk -v g="$guard" '{print} /<head>/ && !done {print "  " g; done=1}' "$in" > "$out"
grep -q "location.replace" "$out" || { echo "web_404: no <head> in $in" >&2; exit 1; }
echo "web_404: $out (base $base)"
