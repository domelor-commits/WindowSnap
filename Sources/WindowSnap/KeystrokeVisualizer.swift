import Cocoa
import Carbon.HIToolbox

/// KeyCastr-style on-screen keystroke display. When on, a global key monitor
/// shows each pressed key combination as a fading capsule at the bottom of the
/// screen — handy for demos, screen recordings, and screenshots. Toggled from
/// the menu; the on/off state persists.
final class KeystrokeVisualizer {
    static let shared = KeystrokeVisualizer()

    private var monitor: Any?
    private var panel: NSPanel?
    private var stack: NSStackView!
    private var caps: [NSView] = []
    private(set) var isActive = false

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        isActive = true
        Settings.shared.keystrokeVizEnabled = true; Settings.shared.save()
        buildPanel()
        // Global monitor: sees key events while other apps are focused (needs
        // Accessibility / Input Monitoring, which the app already prompts for).
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.display(e)
        }
        NotificationCenter.default.post(name: .windowSnapKeystrokeVizChanged, object: nil)
        Logger.log("Keystroke visualizer: on")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        Settings.shared.keystrokeVizEnabled = false; Settings.shared.save()
        if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil
        panel?.orderOut(nil); panel = nil; caps = []
        NotificationCenter.default.post(name: .windowSnapKeystrokeVizChanged, object: nil)
        Logger.log("Keystroke visualizer: off")
    }

    // MARK: Display

    private func display(_ e: NSEvent) {
        guard isActive, let panel = panel else { return }
        let text = Self.combo(e)
        guard !text.isEmpty else { return }
        let cap = Self.makeCapsule(text)
        cap.alphaValue = 0
        stack.addArrangedSubview(cap)
        caps.append(cap)
        if caps.count > 7 { caps.removeFirst().removeFromSuperview() }
        relayout()
        panel.orderFrontRegardless()
        cap.animator().alphaValue = 1

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self, weak cap] in
            guard let self = self, let cap = cap else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; cap.animator().alphaValue = 0 }) {
                cap.removeFromSuperview()
                self.caps.removeAll { $0 === cap }
                self.relayout()
            }
        }
    }

    private func relayout() {
        guard let panel = panel else { return }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let w = max(1, size.width + 24), h = max(1, size.height + 16)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(NSRect(x: vis.midX - w / 2, y: vis.minY + 110, width: w, height: h), display: true)
    }

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        stack = NSStackView()
        stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        let cv = p.contentView!
        cv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
        ])
        panel = p
    }

    // MARK: Rendering helpers

    static func combo(_ e: NSEvent) -> String {
        var s = ""
        let f = e.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += KeyNames.string(for: UInt32(e.keyCode))
        return s
    }

    private static func makeCapsule(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        box.layer?.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 42),
        ])
        return box
    }
}

extension Notification.Name {
    static let windowSnapKeystrokeVizChanged = Notification.Name("windowSnapKeystrokeVizChanged")
}
