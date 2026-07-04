import Cocoa
import Carbon.HIToolbox

/// A button that records a new keyboard shortcut when clicked. Click it, then
/// press the desired combination. Most keys need a modifier; F1–F19 are allowed
/// bare. Esc cancels, Delete/Backspace clears.
///
/// Uses BOTH a local monitor and the window's field-editor-free first-responder
/// path so keys are caught reliably regardless of focus quirks.
final class ShortcutRecorder: NSButton {
    var regionKey: String
    var onChange: (Shortcut) -> Void
    var onClear: (() -> Void)?
    private var recording = false
    private var monitor: Any?

    init(regionKey: String, current: Shortcut?, onChange: @escaping (Shortcut) -> Void) {
        self.regionKey = regionKey
        self.onChange = onChange
        super.init(frame: .zero)
        self.bezelStyle = .rounded
        self.title = current?.display ?? "Click to set"
        self.target = self
        self.action = #selector(beginRecording)
        self.setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { removeMonitor() }

    @objc private func beginRecording() {
        guard !recording else { endRecording(); return }   // click again to cancel
        recording = true
        self.title = "Press keys…"
        // Take key focus to the window so nothing else swallows the event.
        self.window?.makeFirstResponder(self.window?.contentView)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.recording else { return event }
            if event.type == .flagsChanged {
                // Show modifiers live while the user holds them.
                self.title = self.liveModifierString(event.modifierFlags) + "…"
                return nil
            }
            self.capture(event)
            return nil   // swallow so the keypress doesn't leak to the app
        }
    }

    private func liveModifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s.isEmpty ? "Press keys" : s
    }

    private func capture(_ event: NSEvent) {
        let code = Int(event.keyCode)
        if code == kVK_Escape { endRecording(); return }
        // Delete / forward-delete clears the shortcut.
        if code == kVK_Delete || code == kVK_ForwardDelete {
            onClear?()
            self.title = "Click to set"
            removeMonitor(); recording = false
            return
        }

        var mods: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }

        let bareAllowed: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
            kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
            kVK_F18, kVK_F19
        ]
        guard mods != 0 || bareAllowed.contains(code) else {
            self.title = "Add ⌘/⌥/⌃ or use F-key"
            // keep recording so the user can try again without re-clicking
            return
        }

        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)

        // Reject a combination already bound to a DIFFERENT action. Two actions
        // sharing a hotkey can't both register with the OS (the second silently
        // fails), and which one wins is undefined, so refuse it up front and keep
        // recording so the user can pick another.
        if let clash = Settings.shared.shortcuts.first(where: { $0.key != regionKey && $0.value == shortcut }) {
            self.title = "\(shortcut.display) in use"
            self.toolTip = "\(shortcut.display) is already assigned to “\(KeyNames.regionLabel(clash.key))”. Pick another combination."
            NSSound.beep()
            return
        }

        onChange(shortcut)
        self.title = shortcut.display
        removeMonitor(); recording = false
    }

    private func endRecording() {
        let current = Settings.shared.shortcuts[regionKey]
        self.title = current?.display ?? "Click to set"
        removeMonitor(); recording = false
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
