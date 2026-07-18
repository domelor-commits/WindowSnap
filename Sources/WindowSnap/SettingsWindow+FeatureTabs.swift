import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import UniformTypeIdentifiers

extension SettingsWindowController {
    // MARK: - Tab: Annotate

    /// A CleanShot-style annotation editor for screenshots captured via the
    /// shortcut buttons (and any other image). The pane is created once and
    /// re-hosted on rebuilds so annotations in progress survive.
    func makeAnnotateTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "annotate")
        item.label = "✎ Annotate"
        let container = NSView()
        if annotatorPane == nil { annotatorPane = AnnotatorPane() }
        annotatorPane.removeFromSuperview()
        annotatorPane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(annotatorPane)
        NSLayoutConstraint.activate([
            annotatorPane.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            annotatorPane.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            annotatorPane.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            annotatorPane.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        item.view = container
        return item
    }

    /// Open the window on the Annotate tab with a freshly captured screenshot.
    func showAnnotate(path: String) {
        show()
        selectTab(1)   // Annotate
        annotatorPane?.loadExternal(path: path)
    }

    /// Open the Annotate tab with an image loaded straight from the clipboard
    /// (memory buffer), for captures that aren't written to a file.
    func showAnnotateFromClipboard(_ image: NSImage) {
        show()
        selectTab(1)   // Annotate
        annotatorPane?.loadImage(image, path: nil)
    }

    // MARK: - Tabs: Clipboard / Force Quit / Command Palette / Shelf

    func makeClipboardTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "clipboard")
        item.label = "Clipboard"
        let pane = ClipboardHistoryPane(frame: .zero)
        pane.autoresizingMask = [.width, .height]
        clipboardPane = pane
        item.view = pane
        return item
    }

    func makeForceQuitTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "forcequit")
        item.label = "Force Quit"
        let pane = ForceQuitPane(frame: .zero)
        pane.autoresizingMask = [.width, .height]
        forceQuitPane = pane
        item.view = pane
        return item
    }

    func makeConversionTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "conversion")
        item.label = "Convert"
        let pane = ConversionPane(frame: .zero)
        pane.autoresizingMask = [.width, .height]
        item.view = pane
        return item
    }

    func makeTranslationTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "translation")
        item.label = "Translation"
        if #available(macOS 13.0, *) {
            let pane = TranslationPane(frame: .zero)
            pane.autoresizingMask = [.width, .height]
            translationPaneStop = { [weak pane] in pane?.stopIfRunning() }
            item.view = pane
        } else {
            let label = NSTextField(labelWithString: "Live translation requires macOS 13 or later.")
            label.alignment = .center
            item.view = label
        }
        return item
    }

    /// Start/stop per-tab live activity: the Force Quit poll runs only while its
    /// tab is showing; the clipboard/command lists refresh when revealed.
    func syncTabActivity() {
        let sel = tabView?.selectedTabViewItem?.identifier as? String
        if sel == "forcequit" { forceQuitPane?.start() } else { forceQuitPane?.stop() }
        if sel == "clipboard" { clipboardPane?.reload() }
        if sel != "translation" { translationPaneStop?() }   // stop listening when tab hidden
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        syncTabActivity()
    }
}
