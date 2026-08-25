# Contributing

## Building

```bash
make cert   # once
make run
```

`make cert` creates a self-signed code-signing certificate in its own
keychain so the Accessibility and Microphone grants survive rebuilds -- see
[Signing](README.md#signing) for why that is three separate fiddly problems
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
system prompt assembly, and the HUD style catalogue. It deliberately does not
attempt to drive AppKit views, the websocket clients, or anything needing a
microphone -- `--transcribe` and `--preview-style` (README.md › Diagnostics)
are the fast manual way to exercise those. `DictationController` is mostly
state-machine glue around those, sitting behind a `private init()` singleton;
its few pure helpers (stop-phrase stripping, transcript normalisation) are
currently `private` to the file. Widening one to `internal` to unit test it
is a reasonable thing to do and does not need any deeper restructuring.

## Layout

```
Sources/Monsieur/
  App/          entry point, delegate, DictationController state machine
  Audio/        AVAudioEngine capture, resampling to 16 kHz PCM16, silence gate
  STT/          ElevenLabs and OpenAI realtime websocket clients
  LLM/          prompt construction, OpenAI and Anthropic providers
  Insert/       clipboard-paste and Accessibility text insertion
  Hotkey/       Carbon global hotkeys, push-to-talk
  UI/           menu bar, HUD panel, settings window
  Config/       settings model and its file-watching store
```

## Adding a HUD design

Overlay designs are one file each, switchable from the menu bar and
previewable in one shot with `.build/debug/Monsieur --preview-style all`
(README.md › Diagnostics). To add one:

1. Add a case to `HUDStyleID` in `Sources/Monsieur/UI/HUDStyle.swift`.
   `displayName`, `detail`, and `preferredSize` are all switches over this
   enum, so the compiler will point at every place that now needs a branch.
2. Add a file in `Sources/Monsieur/UI/HUDStyles/` with a `View` that takes
   an `HUDModel` -- look at the existing five for the shape. Reuse
   `TranscriptText` and `VisualEffectBackground` from `HUDStyle.swift` rather
   than reimplementing committed/partial text rendering or the frosted-glass
   background.
3. Add the case to `makeView(model:)`'s switch, also in `HUDStyle.swift`.

The menu switcher and the Settings picker are both generated from
`HUDStyleID.allCases`, so a new case appears in both without further wiring.
Render committed words solid and in-flight words dimmed -- the recogniser
revises the tail of a sentence as it listens, and every existing design is
honest about which words have actually settled.

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
[.claude/skills/record-demo/SKILL.md](.claude/skills/record-demo/SKILL.md).
