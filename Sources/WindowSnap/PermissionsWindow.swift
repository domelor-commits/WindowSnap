import Cocoa
import ApplicationServices
import CoreGraphics

/// First-run onboarding: one window showing the two permissions WindowSnap needs
/// — Accessibility (to move windows) and Screen Recording (to capture) — each
/// with live status and a one-click Grant button. Auto-shown at launch when a
/// permission is missing, and re-openable anytime from the menu bar.
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    private var axStatus: NSTextField!
    private var srStatus: NSTextField!
    private var axButton: NSButton!
    private var srButton: NSButton!
    private var summary: NSTextField!
    private var timer: Timer?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WindowSnap Setup"
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    func show() {
        refresh()
        startTimer()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// True when both permissions are already granted (so the caller can skip
    /// showing the wizard entirely).
    static func allGranted() -> Bool {
        let ax = AXIsProcessTrusted()
        let sr: Bool = { if #available(macOS 10.15, *) { return CGPreflightScreenCaptureAccess() }; return true }()
        return ax && sr
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let title = NSTextField(labelWithString: "Welcome to WindowSnap")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        stack.addArrangedSubview(title)

        let intro = NSTextField(wrappingLabelWithString:
            "WindowSnap needs two macOS permissions. Grant each once — they carry over to future updates, so you won't be asked again.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 452
        stack.addArrangedSubview(intro)

        let (axRow, axS, axB) = permissionRow(
            name: "Accessibility",
            detail: "Lets WindowSnap move and resize your windows.",
            action: #selector(grantAX))
        axStatus = axS; axButton = axB
        stack.addArrangedSubview(axRow)

        let (srRow, srS, srB) = permissionRow(
            name: "Screen Recording",
            detail: "Lets WindowSnap take screenshots, OCR, and scrolling captures.",
            action: #selector(grantSR))
        srStatus = srS; srButton = srB
        stack.addArrangedSubview(srRow)

        let note = NSTextField(wrappingLabelWithString:
            "After enabling a toggle, macOS may ask you to quit and reopen WindowSnap for it to take effect.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 452
        stack.addArrangedSubview(note)

        summary = NSTextField(labelWithString: "")
        summary.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(summary)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        stack.addArrangedSubview(spacer)

        let done = NSButton(title: "Done", target: self, action: #selector(donePressed))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        stack.addArrangedSubview(done)
    }

    private func permissionRow(name: String, detail: String, action: Selector)
        -> (NSView, NSTextField, NSButton) {
        let box = NSStackView()
        box.orientation = .horizontal
        box.alignment = .centerY
        box.spacing = 12
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 452).isActive = true

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        text.addArrangedSubview(nameLabel)
        text.addArrangedSubview(detailLabel)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let status = NSTextField(labelWithString: "…")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.alignment = .right
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let button = NSButton(title: "Grant…", target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 84).isActive = true

        box.addArrangedSubview(text)
        box.addArrangedSubview(status)
        box.addArrangedSubview(button)
        return (box, status, button)
    }

    // MARK: Status

    private func refresh() {
        let ax = AXIsProcessTrusted()
        let sr: Bool = { if #available(macOS 10.15, *) { return CGPreflightScreenCaptureAccess() }; return true }()
        set(axStatus, axButton, granted: ax)
        set(srStatus, srButton, granted: sr)
        if ax && sr {
            summary.stringValue = "✓ All set — WindowSnap is ready to use."
            summary.textColor = .systemGreen
        } else {
            summary.stringValue = "Enable the items marked “Not granted” above."
            summary.textColor = .secondaryLabelColor
        }
    }

    private func set(_ status: NSTextField, _ button: NSButton, granted: Bool) {
        status.stringValue = granted ? "✓ Granted" : "Not granted"
        status.textColor = granted ? .systemGreen : .systemRed
        button.isEnabled = !granted
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    // MARK: Actions

    @objc private func grantAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openPane("Privacy_Accessibility")
    }

    @objc private func grantSR() {
        if #available(macOS 10.15, *) { CGRequestScreenCaptureAccess() }
        openPane("Privacy_ScreenCapture")
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func donePressed() { window?.close() }

    func windowWillClose(_ notification: Notification) { stopTimer() }
}
