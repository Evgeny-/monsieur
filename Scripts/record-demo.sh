#!/usr/bin/env bash
# Records the README demo: a French sentence is spoken aloud, Monsieur hears it
# through the microphone, and English lands in the text field.
#
# The loop is deliberately acoustic -- speakers to microphone, no virtual audio
# device -- so the recording is of the app genuinely working, not of a signal
# routed around the part being demonstrated. `screencapture -g` captures that
# same microphone, so the French is audible in the video.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-docs/demo/demo.mov}"
SETTINGS="$HOME/Library/Application Support/Monsieur/settings.json"
APP="/Applications/Monsieur.app/Contents/MacOS/Monsieur"
SPEECH="docs/demo/line.mp3"
# A real French voice, not an English one reading French. Override with
# VOICE=<id> to try another.
VOICE="${VOICE:-AK0nPY3tziUZ3HEQeHa5}"
LINE="Peux-tu vérifier les journaux de production et me dire pourquoi le déploiement a échoué hier soir ?"

key() { python3 -c "import json,pathlib;print(json.loads(pathlib.Path('$SETTINGS').read_text())['$1'])"; }

if [ ! -f "$SPEECH" ]; then
    echo "==> Synthesising the French line"
    VOICE="$VOICE" python3 - "$SPEECH" "$LINE" <<'PY'
import json, os, pathlib, subprocess, sys
out, line = sys.argv[1], sys.argv[2]
key = os.environ["TTS_KEY"]
body = json.dumps({"text": line, "model_id": "eleven_multilingual_v2"})
subprocess.run([
    "curl", "-sf", "-o", out, "-X", "POST",
    f"https://api.elevenlabs.io/v1/text-to-speech/{os.environ['VOICE']}",
    "-H", f"xi-api-key: {key}", "-H", "Content-Type: application/json",
    "-d", body], check=True)
print(f"    wrote {out}")
PY
fi

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SPEECH")

# A pinned recognition language is not a hint -- the recogniser forces speech
# into it. With the language left on Russian, the first take transcribed the
# French line as Russian words ("dnevniki proizvodstva" for "journaux de
# production") and the demo would have shown the app doing something other than
# what it claims. Set for the take, restored afterwards.
RESTORE="$(mktemp)"
cp "$SETTINGS" "$RESTORE"
trap 'cp "$RESTORE" "$SETTINGS"; rm -f "$RESTORE"' EXIT
python3 -c "
import json, pathlib
p = pathlib.Path('$SETTINGS')
d = json.loads(p.read_text())
d['sttLanguage'] = 'fra'
p.write_text(json.dumps(d, indent=2, sort_keys=True, ensure_ascii=False))
"
sleep 1   # the app watches the file; give it a moment to pick the change up

echo "==> Opening the scene"
Scripts/open-scene.sh

echo "==> Recording"
screencapture -v -g -V 26 -x "$OUT" &
recorder=$!
# Four seconds, not two: roughly half of it is consumed before the first frame
# is actually captured, and the rest is the beat of ordinary page before
# anything appears.
sleep 4

"$APP" --signal start           # explicit, not a toggle: a toggle arriving
                                # while the app is still busy desynchronises
sleep 0.8
afplay "$SPEECH"
sleep 1.2
"$APP" --signal stop            # transcription settles, then the rewrite

wait "$recorder" 2>/dev/null || true

# Cropped to the band holding the card and the overlay. The full screen carries
# a menu bar, a dock and whatever else happens to be open -- none of it the
# subject, all of it somebody's private desktop.
# Anchored to the overlay rather than to a constant. The app logs where it drew
# the panel, and the frame is built upward from there: everything above it up to
# the top of the conversation, nothing below it where the browser window ends
# and the desktop begins. Re-measuring by hand every time the page changes is
# how the first take ended up framing an empty composer.
rect=$(/usr/bin/log show --last 60s --info --style compact \
    --predicate 'subsystem == "dev.enikiforov.monsieur"' 2>/dev/null \
    | grep -oE 'hud rect [0-9]+,[0-9]+,[0-9]+,[0-9]+' | tail -1 | cut -d' ' -f3)

if [ -n "$rect" ]; then
    IFS=, read -r _hx hy _hw hh <<< "$rect"
    CROP=$(python3 -c "
scale = 2                      # points to pixels on this display
geom = open('/tmp/monsieur-scene-geometry').read().split()
# The bottom edge follows the window, not the overlay. Anchoring it to the
# overlay clipped the composer as soon as the composer moved below it -- and the
# window is full height, so both are guaranteed to be inside this.
bottom = (int(geom[2]) - 14) * scale
height = 780 * scale           # enough to keep the channel list whole
# Framed to the window, not the display: the window is narrower than the
# screen and centred, and open-scene.sh writes its geometry out so this does
# not have to assume either.
width  = int(geom[0]) * scale
left   = int(geom[1]) * scale
print(f'{width}:{height}:{left}:{max(0, bottom - height)}')
")
else
    CROP="${CROP:-2360:1400:0:420}"
fi
echo "==> Framing $CROP"

ffmpeg -v error -i "$OUT" -vf "crop=$CROP" -c:v h264 -crf 20 -c:a aac \
       "${OUT%.mov}-cropped.mp4" -y
mv "${OUT%.mov}-cropped.mp4" "${OUT%.mov}.mp4"
# Trimmed: everything after the paste is dead air, and a README video that
# outlasts its own point does not get watched twice.
ffmpeg -v error -i "${OUT%.mov}.mp4" -t 17 -c:v libx264 -crf 22 -preset slow \
       -c:a aac -b:a 128k "${OUT%.mov}-t.mp4" -y
mv "${OUT%.mov}-t.mp4" "${OUT%.mov}.mp4"
rm -f "$OUT"
echo "==> Wrote ${OUT%.mov}.mp4 ($(du -h "${OUT%.mov}.mp4" | cut -f1), spoken line ${DURATION}s)"
