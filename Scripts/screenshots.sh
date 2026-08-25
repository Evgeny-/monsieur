#!/usr/bin/env bash
# Captures each overlay design over the real desktop, for the README.
#
# The blur is a live NSVisualEffectView sampling whatever is behind the window,
# so these have to be real screen captures -- rendering the views offscreen
# would produce a flat, transparent rectangle where the glass should be.
#
# Full screen first, crop afterwards: reading the overlay's position back out of
# the unified log takes seconds, and the preview would be gone before the
# shutter fired.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-docs/screenshots}"
mkdir -p "$OUT"
BIN=".build/debug/Monsieur"
[ -x "$BIN" ] || { echo "build first: swift build"; exit 1; }

# Shot over the demo scene rather than whatever happens to be on screen: these
# end up in the README, and a stranger's cluttered desktop behind the glass is
# both distracting and revealing.
open -a Safari "file://$PWD/docs/demo/scene.html"
sleep 3

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for style in minimal classic frosted teleprompter waveform; do
    "$BIN" --preview-style "$style" >/dev/null 2>&1 &
    preview=$!
    sleep 2
    screencapture -x "$TMP/$style-full.png"
    kill "$preview" 2>/dev/null || true
    wait "$preview" 2>/dev/null || true

    rect=$(/usr/bin/log show --last 20s --info --style compact \
        --predicate 'subsystem == "dev.enikiforov.monsieur"' 2>/dev/null \
        | grep -oE 'hud rect [0-9]+,[0-9]+,[0-9]+,[0-9]+' | tail -1 | cut -d' ' -f3)
    [ -n "$rect" ] || { echo "  $style: no overlay rect in the log"; continue; }

    IFS=, read -r x y w h <<< "$rect"
    # The log reports points; a screen capture is in pixels. Derive the scale
    # from the image itself rather than assuming Retina.
    px_w=$(sips -g pixelWidth "$TMP/$style-full.png" | awk '/pixelWidth/ {print $2}')
    pt_w=$(python3 -c "import subprocess;print(1512)")
    scale=$(python3 -c "print(int($px_w) // int($pt_w))")

    sips -c $((h * scale)) $((w * scale)) \
         --cropOffset $((y * scale)) $((x * scale)) \
         "$TMP/$style-full.png" --out "$OUT/$style.png" >/dev/null
    echo "  $style.png  (${w}x${h} pt at ${scale}x)"
done
