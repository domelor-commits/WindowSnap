import Cocoa

/// A simple "What's New" release-notes window. Shown automatically the first time
/// the app runs after a version bump, and on demand from the menu bar.
final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    static let shared = WhatsNewWindowController()

    /// Release notes, newest first. The first entry's version is treated as the
    /// current release for the "show once after an update" logic below.
    private static let releases: [(version: String, notes: [String])] = [
        ("2.3", [
            "Dictate Anywhere — press the shortcut, speak, and the text is pasted into any app.",
            "Window Switcher — an Alt-Tab-style overlay of all open windows with thumbnails.",
            "Meeting bar — your next calendar meeting in the menu with a one-click Join.",
            "Keystroke visualizer — show pressed keys on screen for demos and recordings.",
            "New Convert tab — live currency (country, continent, inverse, decimals, pin/hide/reorder), a worldtimebuddy-style World Time comparer with a 5-minute slider and calendar events, plus every common unit.",
            "Command Palette calculator — type math, unit or currency conversions and copy the result.",
            "Tidied the menu bar and settings tabs.",
        ]),
        ("2.2", [
            "Redesigned Layouts tab — each layout has clear Restore and Overwrite buttons that work on a single click, no shortcut required.",
            "Overwriting a layout now asks for confirmation, so you can’t clobber a saved arrangement by accident.",
            "Keyboard shortcuts moved into a tidy popover behind a ⌨ button (set or clear restore & overwrite hotkeys there).",
        ]),
        ("2.1", [
            "Live translation is more accurate: full Whisper large-v3 model option, prior-text conditioning, and silence/music filtering.",
            "New audio source picker — translate System audio, your Microphone, or a specific app.",
            "Southeast-Asian + Chinese/Cantonese source languages pinned to the top of the From list; your language choices are now remembered.",
            "Model downloads now show progress instead of a frozen “please wait”.",
            "Keyboard Shortcuts cheat sheet — see every binding at a glance.",
            "Clipboard history can be kept in memory only, and old entries expire automatically.",
            "Automatic updates and this What’s New window.",
            "Tidier menu-bar menu.",
        ]),
    ]

    /// UserDefaults key remembering the last version whose notes were shown.
    private static let lastShownKey = "WindowSnapWhatsNewLastVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? releases.first?.version ?? "0"
    }

    private var window: NSWindow?

    /// Show the notes once after an update. On a brand-new install (nothing stored)
    /// we record the version silently so first-run doesn't nag.
    func showIfNeeded() {
        let last = UserDefaults.standard.string(forKey: Self.lastShownKey)
        let current = Self.currentVersion
        guard last != current else { return }
        UserDefaults.standard.set(current, forKey: Self.lastShownKey)
        if last != nil { show() }   // only pop for an actual update, not first launch
    }

    func show() {
        if window == nil { window = buildWindow() }
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() -> NSWindow {
        let width: CGFloat = 460
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "What’s New in WindowSnap"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let content = w.contentView!

        let title = NSTextField(labelWithString: "What’s New")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let version = NSTextField(labelWithString: "Version \(Self.currentVersion)")
        version.font = .systemFont(ofSize: 12, weight: .medium)
        version.textColor = .secondaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false

        // Bulleted notes for the current release.
        let notes = Self.releases.first?.notes ?? []
        let body = NSTextView()
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.textContainerInset = NSSize(width: 4, height: 6)
        body.textStorage?.setAttributedString(Self.bulletedNotes(notes))
        let scroll = NSScrollView()
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title); content.addSubview(version)
        content.addSubview(scroll); content.addSubview(closeButton)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            version.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            version.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scroll.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        return w
    }

    private static func bulletedNotes(_ notes: [String]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 8
        para.lineSpacing = 2
        para.headIndent = 16
        para.firstLineHeadIndent = 0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        for note in notes {
            s.append(NSAttributedString(string: "•  \(note)\n", attributes: attrs))
        }
        return s
    }

    @objc private func closeWindow() { window?.close() }

    func windowWillClose(_ notification: Notification) { /* keep the controller for reuse */ }
}
