import AppKit
import Carbon.HIToolbox

/// Registers system-wide hotkeys through Carbon's `RegisterEventHotKey`.
///
/// Carbon is ancient but it is still the only API that reserves a key
/// combination process-wide without needing an event tap, so it needs no
/// Accessibility grant of its own and cannot be starved by a busy main thread.
///
/// `kEventHotKeyReleased` gives us push-to-talk. It is not perfectly reliable
/// across all keyboards, so a `.flagsChanged` monitor acts as a safety net: if
/// every modifier the hotkey requires has been let go, we treat that as release.
@MainActor
final class HotkeyManager {

    struct Registration {
        let hotkey: Hotkey
        let onPress: () -> Void
        let onRelease: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var heldIDs: Set<UInt32> = []
    private var flagsMonitor: Any?

    static let shared = HotkeyManager()

    private init() {}

    // MARK: - Public API

    /// Replaces every registration in one shot. Called on launch and whenever
    /// settings change.
    func setBindings(_ bindings: [(hotkey: Hotkey, onPress: () -> Void, onRelease: () -> Void)]) {
        unregisterAll()
        installHandlerIfNeeded()
        for b in bindings {
            register(b.hotkey, onPress: b.onPress, onRelease: b.onRelease)
        }
        installFlagsMonitorIfNeeded()
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        registrations.removeAll()
        heldIDs.removeAll()
    }

    // MARK: - Registration

    private func register(_ hotkey: Hotkey,
                          onPress: @escaping () -> Void,
                          onRelease: @escaping () -> Void) {
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5649_4E50 /* "VINP" */), id: id)
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.carbonModifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &ref)

        guard status == noErr, let ref else {
            Log.hotkey.error("could not register \(hotkey.display, privacy: .public) (OSStatus \(status))")
            return
        }
        refs[id] = ref
        registrations[id] = Registration(hotkey: hotkey, onPress: onPress, onRelease: onRelease)
        Log.hotkey.info("registered \(hotkey.display, privacy: .public)")
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let this = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr else { return noErr }
            let kind = GetEventKind(event)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if kind == UInt32(kEventHotKeyPressed) {
                    manager.handlePress(id: id.id)
                } else {
                    manager.handleRelease(id: id.id)
                }
            }
            return noErr
        }, 2, &types, this, &handler)
    }

    // MARK: - Dispatch

    private func handlePress(id: UInt32) {
        guard let reg = registrations[id] else { return }
        heldIDs.insert(id)
        reg.onPress()
    }

    private func handleRelease(id: UInt32) {
        guard heldIDs.remove(id) != nil, let reg = registrations[id] else { return }
        reg.onRelease()
    }

    /// Safety net for push-to-talk: `kEventHotKeyReleased` can be missed when the
    /// user lets go of the modifier before the key. Watching the modifier flags
    /// catches that case.
    private func installFlagsMonitorIfNeeded() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                let active = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                for id in self.heldIDs {
                    guard let reg = self.registrations[id] else { continue }
                    let required = reg.hotkey.cocoaModifiers
                    if !required.isEmpty, !active.isSuperset(of: required) {
                        self.handleRelease(id: id)
                    }
                }
            }
        }
    }
}
