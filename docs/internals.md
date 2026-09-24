# Internals

Why some of this is built the way it is. None of it is needed to use the
app; all of it is needed before changing it.

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

## Notes on the tricky parts

**Why capture is input-only.** `AVAudioEngine` on macOS can use a hidden
aggregate of the default input and output devices, even for an input tap.
Changing the output route (including plugging in 3.5 mm headphones without a
microphone) can therefore disturb capture. `MicrophoneCapture` instead opens
an explicit `AVCaptureDevice.default(for: .audio)` input in a fresh
`AVCaptureSession` for each recording. It does not select or open a playback
device, change system defaults, or override the user's chosen microphone.
AVFoundation converts the native samples to the recognizer's mono PCM16 rate
(16 kHz for ElevenLabs, 24 kHz for OpenAI); the actual output format is checked
before any bytes reach STT.

**Why startup is asynchronous and bounded.** Device discovery, configuration,
and `startRunning`/`stopRunning` run on a per-attempt serial queue, never the
main actor. Startup succeeds only when a nonempty PCM chunk arrives (silence
counts), and fails after five seconds if none does. Stopping invalidates the
attempt immediately; stale audio, errors, and permission/startup completions
cannot revive a cancelled recording or damage its replacement. Hardware cleanup
is queued, so a driver stuck inside a system call cannot freeze the UI; cleanup
itself still depends on that call returning. Runtime capture errors and device
disconnection are surfaced as failures rather than leaving a dead recording.

**Why the realtime glossary is filtered.** ElevenLabs Scribe v2 Realtime
accepts at most 50 keyterms, each no longer than 20 Unicode code points (the
batch API has different limits). One oversized entry rejects the whole session:
`server-side rendering`, at 21 characters, caused exactly that. The ElevenLabs
adapter trims and deduplicates hints, skips oversized terms, and caps the list
without changing the stored glossary or the complete LLM correction table.
`invalid_request` does not have “error” in its name, but is a terminal server
error, not a reason to reconnect with the same rejected options. Before
`session_started`, the receive path owns failures so a generic send error cannot
hide the server's explanation. Replacement sockets retain the dictation's retry
budget rather than resetting it on every connection.

**Why paste instead of the Accessibility API.** `kAXSelectedTextAttribute`
returns `.success` on elements that are not text fields while inserting nothing,
and it fails silently in most Electron apps — which is where a lot of this text
is headed. The clipboard is saved and restored around the paste. The AX path is
still there behind `pasteViaClipboard: false`.

**Why the HUD is a non-activating panel.** If the overlay ever took key focus,
the caret would leave the text field being dictated into and there would be
nowhere left to paste.

**Why we wait before pasting.** The hotkey's own modifiers are usually still
physically held when the paste fires. Sending `⌘V` while `⌃⌥` are down produces
some other app's shortcut, so the inserter waits for the modifiers to clear.

**Why hotkey re-registration takes the published value.** `@Published` fires in
`willSet`, so a subscriber that re-reads `SettingsStore.shared.settings` sees the
*old* settings. Editing the hotkey in the JSON file re-registered the previous
one until that was fixed; the sink uses the emitted value instead.

<a name="signing"></a>

## Signing

Three separate things have to line up before an unattended `make install` works,
and each fails differently:

1. **The PKCS#12 format.** Apple's Security framework cannot read what OpenSSL 3
   writes by default (AES-256 + SHA-256 MAC) — `security import` fails with "MAC
   verification failed". `make cert` calls `/usr/bin/openssl` (LibreSSL) rather
   than whatever is first on `PATH`.
2. **The key's partition list.** `security import -A` opens the ACL but not the
   partition list that macOS has gated key access on since Sierra, so codesign
   still blocks on a password dialog. That is why the key lives in a dedicated
   keychain with a password the script knows: `set-key-partition-list` can then
   run without prompting.
3. **Certificate name ambiguity.** A certificate name is unique only within one
   keychain. With the same name in two keychains, codesign reports "ambiguous"
   and picks one — possibly the one with a locked-down ACL. `bundle.sh` signs by
   SHA-1 hash instead.

To undo all of it:

```bash
security delete-keychain ~/Library/Keychains/monsieur-signing.keychain-db
```
