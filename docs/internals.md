# Internals

Why some of this is built the way it is. None of it is needed to use the
app; all of it is needed before changing it.

## Layout

```
Sources/Monsieur/
  App/          entry point, delegate, DictationController state machine
  Audio/        AVAudioEngine capture, resampling to 16 kHz PCM16, silence gate
  STT/          ElevenLabs realtime websocket client
  LLM/          prompt construction, OpenAI and Anthropic providers
  Insert/       clipboard-paste and Accessibility text insertion
  Hotkey/       Carbon global hotkeys, push-to-talk
  UI/           menu bar, HUD panel, settings window
  Config/       settings model and its file-watching store
```

## Notes on the tricky parts

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
