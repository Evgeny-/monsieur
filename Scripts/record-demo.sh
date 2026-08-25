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
LINE="Peux-tu vérifier les journaux de production et me dire pourquoi le déploiement a échoué hier soir ?"

key() { python3 -c "import json,pathlib;print(json.loads(pathlib.Path('$SETTINGS').read_text())['$1'])"; }

if [ ! -f "$SPEECH" ]; then
    echo "==> Synthesising the French line"
    python3 - "$SPEECH" "$LINE" <<'PY'
import json, os, pathlib, subprocess, sys
out, line = sys.argv[1], sys.argv[2]
key = os.environ["TTS_KEY"]
body = json.dumps({"text": line, "model_id": "eleven_multilingual_v2"})
subprocess.run([
    "curl", "-sf", "-o", out, "-X", "POST",
    "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM",
    "-H", f"xi-api-key: {key}", "-H", "Content-Type: application/json",
    "-d", body], check=True)
print(f"    wrote {out}")
PY
fi

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SPEECH")

echo "==> Opening the scene"
open -a Safari "file://$PWD/docs/demo/scene.html"
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
echo "==> Wrote $OUT ($(du -h "$OUT" | cut -f1), spoken line ${DURATION}s)"
