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
# Chrome, not Safari: Safari shows a "make me your default" banner that
# lands in the middle of the frame.
open -a "Google Chrome" "file://$PWD/docs/demo/scene.html"
sleep 3

echo "==> Recording"
screencapture -v -g -V 22 -x "$OUT" &
recorder=$!
sleep 2

"$APP" --signal toggle          # start dictating
sleep 0.8
afplay "$SPEECH"
sleep 1.2
"$APP" --signal toggle          # stop; transcription settles, then the rewrite

wait "$recorder" 2>/dev/null || true

# Cropped to the band holding the card and the overlay. The full screen carries
# a menu bar, a dock and whatever else happens to be open -- none of it the
# subject, all of it somebody's private desktop.
# Measured, not guessed: the composer occupies 521-764pt and the overlay
# 830-910pt, so the band runs from just above the card to just below the
# overlay. It stops short of 915pt, where the browser window ends and the
# desktop behind it starts. Pixels are twice the points on this display.
CROP="${CROP:-1620:830:640:1000}"
ffmpeg -v error -i "$OUT" -vf "crop=$CROP" -c:v h264 -crf 20 -c:a aac \
       "${OUT%.mov}-cropped.mp4" -y
mv "${OUT%.mov}-cropped.mp4" "${OUT%.mov}.mp4"
rm -f "$OUT"
echo "==> Wrote ${OUT%.mov}.mp4 ($(du -h "${OUT%.mov}.mp4" | cut -f1), spoken line ${DURATION}s)"
