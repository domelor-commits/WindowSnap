import Cocoa
import Carbon.HIToolbox

/// Registers system-wide hotkeys using the Carbon event API. Supports
/// re-registering when the user changes shortcuts in the UI.
final class HotkeyManager {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
            mgr.handlers[hkID.id]?()
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    /// Registers a global hotkey. Returns false (and logs) if the OS rejects it —
    /// which happens when the same key combination is already registered, so a
    /// silent conflict is at least visible in the activity log.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x57534E50), id: id) // 'WSNP'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else {
            Logger.log("Hotkey registration failed (OSStatus \(status)) — combo likely already in use")
            return false
        }
        // Only record the handler once the OS accepted the registration, so a
        // failed combo doesn't leave a dangling entry that never fires.
        handlers[id] = action
        refs.append(ref)
        return true
    }

    /// Remove all registered hotkeys (call before re-registering from settings).
    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        nextID = 1
    }
}
