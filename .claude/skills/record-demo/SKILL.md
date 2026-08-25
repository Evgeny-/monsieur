---
name: record-demo
description: Re-record the README demo video for Monsieur — a French sentence spoken aloud by ElevenLabs, heard through the microphone, transcribed, rewritten, and typed into a mock web app. Use when the demo needs reshooting after a change to the overlay, the app's behaviour, or the demo scene, or when the spoken line, voice or language should change.
---

# Recording the demo

The demo shows the claim the whole project rests on: speak one language, get
another, typed into software that was never built for this. It has to be a real
screen recording of the app actually working — the overlay's blur samples what
is behind the window, so nothing rendered offscreen looks right.

## What it is made of

| | |
|---|---|
| `docs/demo/scene.html` | The mock app being typed into. Knows nothing about Monsieur. |
| `Scripts/open-scene.sh` | Opens it in a chromeless, isolated Chrome window. |
| `Scripts/record-demo.sh` | Drives the whole take and writes `docs/demo/demo.mp4` and `.gif`. |
| `docs/demo/line.mp3` | The spoken line. Delete it to have it re-synthesised. |

## Recording

```bash
export TTS_KEY=$(grep -E "^ELEVENLABS_API_KEY" ~/Projects/Psyside/.env | sed -E 's/^[^=]+=//; s/^"//; s/"$//')
Scripts/record-demo.sh
```

**The room has to be silent and the machine untouched for ~30 seconds.** The
loop is acoustic on purpose — speakers to microphone, no virtual audio device —
so a recording made while someone is talking captures them instead. That has
happened; check the transcript afterwards, not just the video.

Prerequisites: Monsieur installed and holding Accessibility permission
(`Monsieur --check`), and a Chrome at `/Applications/Google Chrome.app`.

## Verifying the take

Never ship one without looking at it. Two checks catch almost everything:

```bash
# What the app actually heard and produced
python3 -c "
import json, pathlib
p = pathlib.Path.home()/'Library/Application Support/Monsieur/history.jsonl'
last = [json.loads(l) for l in p.read_text().splitlines() if l.strip()][-1]
print(last['transcript']); print('->', last['output'])"

# Frames: before the overlay appears, mid-dictation, after the paste
for t in 0.3 8 13; do
    ffmpeg -v error -ss $t -i docs/demo/demo.mp4 -frames:v 1 -vf scale=740:-1 /tmp/f$t.png -y
done
```

## Failures that have cost takes

Each of these produced a plausible-looking video that was wrong.

**The text landed in the browser's address bar.** A single `autofocus` loses the
race against the browser settling focus into the URL field after load. The scene
reclaims focus repeatedly for five seconds; if that is ever removed it will
come back.

**The French line transcribed as Russian.** A pinned recognition language is
enforced, not preferred: the recogniser forces what it hears into it rather than
reporting a mismatch. `journaux de production` came back as `дневники
производства`. The script pins French for the take and restores the previous
setting on exit — do not remove the `trap`.

**The overlay was in the very first frame.** `screencapture -v` does not begin
recording when it is launched; a short lead-in is entirely swallowed by that
startup. If the take needs a longer quiet opening, extend the `sleep` after the
recorder starts, not the trim.

**The frame held an empty composer.** The crop used to be constants measured
once. It is now derived from where the app logs the overlay (`hud rect` in the
unified log) and from the window geometry `open-scene.sh` writes to
`/tmp/monsieur-scene-geometry`. Keep it derived.

## Changing the line, voice or language

The spoken line is `LINE` in `Scripts/record-demo.sh`; delete `docs/demo/line.mp3`
to force re-synthesis. `VOICE=<id>` overrides the voice — list real French ones
with:

```bash
curl -s -H "xi-api-key: $TTS_KEY" \
  "https://api.elevenlabs.io/v1/shared-voices?language=fr&page_size=20" | \
  python3 -c "
import json, sys
for v in json.load(sys.stdin)['voices'][:12]:
    print(v['voice_id'], v['name'], v.get('accent'))"
```

For another spoken language, change `LINE`, `VOICE`, and the `sttLanguage` the
script pins.

## Getting sound into the README

GitHub will not play a video that lives in the repository. Verified against its
own renderer:

| Written as | Rendered as |
|---|---|
| `![x](docs/demo/demo.mp4)` | `<img src="...mp4">` — a broken image |
| a bare raw URL | a plain link |
| `<video src="...">` | stripped entirely |

The only thing that produces a real player is an asset uploaded through the web
interface: open any issue, drag `docs/demo/demo.mp4` into the comment box, and
GitHub returns a `https://github.com/user-attachments/assets/…` URL. That URL,
on its own line in the README, renders as a player with sound. The issue itself
does not need to be submitted.

Until then the README shows `demo.gif`, which is silent — and hearing the French
is half the point, so this is worth doing once the repository is public.
Attachments on a private repository are only served to people who can already
see it.
