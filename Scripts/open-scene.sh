#!/usr/bin/env bash
# Opens the demo scene in a chromeless, full-height browser window.
#
# App mode with an isolated profile, rather than a normal tab: a normal window
# stops short of the screen bottom, which left the overlay floating over bare
# desktop with a white seam between it and the page. It also removes the tab
# strip and address bar -- both of which are somebody's private browsing, and
# the address bar is what stole focus from the page in the first take.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:-/tmp/monsieur-demo-profile}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome not found"; exit 1; }

# Screen size in points, so the window reaches the bottom edge.
read -r W H <<< "$(python3 -c "
import subprocess, re
out = subprocess.run(['system_profiler','SPDisplaysDataType'], capture_output=True, text=True).stdout
m = re.search(r'Resolution: (\d+) x (\d+)', out)
print(int(m.group(1)) // 2, int(m.group(2)) // 2)")"

pkill -f "user-data-dir=$PROFILE" 2>/dev/null || true
sleep 0.5
"$CHROME" --user-data-dir="$PROFILE" \
    --app="file://$PWD/docs/demo/scene.html" \
    --window-position=0,0 --window-size="$W,$H" \
    --no-first-run --no-default-browser-check --hide-crash-restore-bubble \
    >/dev/null 2>&1 &
sleep 3
