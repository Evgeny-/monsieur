# Contributing

## Building

```bash
make cert   # once
make run
```

`make cert` creates a self-signed code-signing certificate in its own
keychain so the Accessibility and Microphone grants survive rebuilds -- see
[Signing](docs/internals.md#signing) for why that is three separate fiddly problems
rather than one. Skip it and `make run` still works, but macOS will treat
every rebuild as a new app and drop your Accessibility grant each time.

`make run` builds `dist/Monsieur.app`, installs it to `/Applications`, and
launches it. Plain SwiftPM -- there is no Xcode project. `make debug`,
`make logs`, and `make reset-permissions` cover the rest of the inner loop;
see the Makefile.

## Testing

```bash
swift test
```

Uses `swift-testing` (`import Testing`, `@Test`, `#expect`), not XCTest.
`MonsieurTests` depends directly on the `Monsieur` executable target --
SwiftPM has supported testing an executable target this way since Swift 5.5,
as long as its entry point is an `@main` type rather than top-level code in a
literal `main.swift`, which is what this app already uses. No separate
library target was needed just to make it testable.

The suite covers the pure logic underneath the AppKit and network-I/O
surface: hotkey string parsing, `Settings`' per-field-fallback JSON decoding,
system prompt assembly, microphone startup/cancellation with a fake capture
backend, and the PCM wire format. It deliberately does not
attempt to drive AppKit views, the websocket clients, or anything needing a
microphone -- `--transcribe` and `--preview-style` (README.md › Diagnostics)
are the fast manual way to exercise those. `DictationController` is mostly
state-machine glue around those, sitting behind a `private init()` singleton;
its few pure helpers (stop-phrase stripping, transcript normalisation) are
currently `private` to the file. Widening one to `internal` to unit test it
is a reasonable thing to do and does not need any deeper restructuring.

### Microphone route regression check

On a signed build with microphone permission, select the built-in microphone in
System Settings > Sound > Input. Start/stop dictation, plug in output-only 3.5 mm
headphones, then repeat without restarting the app. Repeat after unplugging them,
and with headphones already connected at launch. Verify the meter and transcript
work; also change the output route while recording. Check both STT providers
(16/24 kHz), quick push-to-talk release during startup, and Escape followed by an
immediate retry. A missing/unresponsive input must show an error after five
seconds instead of leaving “Starting…” indefinitely. Automated tests cover the
lifecycle and PCM contract, not physical jack insertion or the full STT path.

## Layout

```
Sources/Monsieur/
  App/          entry point, delegate, DictationController state machine
  Audio/        input-only AVCaptureSession, 16/24 kHz mono PCM16, silence gate
  STT/          ElevenLabs and OpenAI realtime websocket clients
  LLM/          prompt construction, OpenAI and Anthropic providers
  Insert/       clipboard-paste and Accessibility text insertion
  Hotkey/       Carbon global hotkeys, push-to-talk
  UI/           menu bar, HUD panel, settings window
  Config/       settings model and its file-watching store
```

## The overlay

The overlay is one view, `Sources/Monsieur/UI/MonsieurHUD.swift`, in two sizes:
with the transcript, or a dot that reacts to your voice. There were five designs
once, switchable at runtime; the one that got used was the one that said the
least, and each of the others was another thing to keep working through every
change underneath. `TranscriptText` and `VisualEffectBackground` in
`HUDStyle.swift` carry the committed-versus-partial text rendering and the
frosted-glass background. Preview a change without dictating:

```bash
.build/debug/Monsieur --preview-hud
```

## Secrets

Nothing in this repository should ever carry a real API key. Settings
(including keys) live outside the repo, at
`~/Library/Application Support/Monsieur/settings.json`. Settings can also
import `ELEVENLABS_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` from a
local `.env` file, filling in only whichever keys are currently empty -- keep
that file out of git too, same as settings.json.

## Re-recording the demo

The video in the README is a real screen recording of the app working, driven by
`Scripts/record-demo.sh`. The procedure, the checks worth running on a take, and
the several ways a take can come out plausible but wrong are written up in
[skills/record-demo/SKILL.md](skills/record-demo/SKILL.md).
