import Cocoa
import SwiftUI
import Speech
import ScreenCaptureKit
import Translation
import NaturalLanguage
import CoreMedia
import AVFoundation
import WhisperKit

// MARK: - Translation tab

@available(macOS 13.0, *)
final class TranslationPane: NSView {
    private let engine = LiveTranslator()
    private let sourcePopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let audioPopup = NSPopUpButton()
    private let startButton = NSButton()
    private let accuracyToggle = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detectedLabel = NSTextField(labelWithString: "")
    private let outputView = NSTextView()

    private var running = false
    private var committedLength = 0
    private var liveSourceText = ""
    private var liveTransText = ""

    private static let targets: [(String, String)] = [
        ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Italian", "it"), ("Portuguese", "pt"), ("Chinese", "zh"),
        ("Japanese", "ja"), ("Korean", "ko"), ("Russian", "ru"), ("Arabic", "ar"),
        ("Hindi", "hi"), ("Dutch", "nl"), ("Polish", "pl"), ("Turkish", "tr"),
    ]

    /// Priority source languages floated to the top of the "From" list (in this
    /// order) ahead of the alphabetical rest. Matched by Whisper language *code*,
    /// so any code the loaded model doesn't support is simply skipped, and each
    /// item's display name comes from Whisper's own list.
    private static let pinnedSourceLanguageCodes = ["id", "ms", "th", "vi", "tl", "zh", "yue"]

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build(); wireEngine() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        // Source languages come from Whisper's own list so the code we pass is
        // always a valid language token — otherwise WhisperKit silently falls
        // back to English (that was the "wrong source language" bug).
        //
        // Each item carries its Whisper code in representedObject, so the ASEAN
        // group can be floated to the top (with a separator) without the
        // selection logic depending on item order.
        sourcePopup.addItem(withTitle: "Automatic (detect)")   // representedObject nil = auto-detect

        // Sort first so the code→name dedupe below picks a stable, alphabetically
        // first display name when Whisper lists aliases for one code (e.g.
        // chinese/mandarin → "zh", flemish/dutch → "nl").
        let all = Constants.languages
            .map { (name: $0.key.capitalized, code: $0.value) }
            .sorted { $0.name < $1.name }
        let byCode = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = Self.pinnedSourceLanguageCodes.compactMap { byCode[$0] }
        let pinnedCodes = Set(Self.pinnedSourceLanguageCodes)
        let rest = all.filter { !pinnedCodes.contains($0.code) }

        func addLang(_ lang: (name: String, code: String)) {
            sourcePopup.addItem(withTitle: lang.name)
            sourcePopup.lastItem?.representedObject = lang.code
        }
        pinned.forEach(addLang)
        if !pinned.isEmpty, !rest.isEmpty { sourcePopup.menu?.addItem(.separator()) }
        rest.forEach(addLang)
        sourcePopup.target = self; sourcePopup.action = #selector(languageChanged)
        // Restore the last-used source language ("" = Automatic).
        Self.selectByCode(sourcePopup, code: Settings.shared.translationSourceCode)

        for (name, code) in Self.targets {
            targetPopup.addItem(withTitle: name)
            targetPopup.lastItem?.representedObject = code
        }
        targetPopup.target = self; targetPopup.action = #selector(languageChanged)
        // Restore the last-used target language (default English).
        Self.selectByCode(targetPopup, code: Settings.shared.translationTargetCode)

        // Audio source: System / Microphone, then each running app.
        populateAudioSources()
        audioPopup.target = self; audioPopup.action = #selector(audioChanged)

        startButton.title = "Start"; startButton.bezelStyle = .rounded
        startButton.target = self; startButton.action = #selector(toggleRun)
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearOutput))
        clearButton.bezelStyle = .rounded

        // "Higher accuracy" switches to the full large-v3 model. It's slower, so
        // it lives on its own row and applies on the next Start.
        accuracyToggle.setButtonType(.switch)
        accuracyToggle.title = "Higher accuracy"
        accuracyToggle.state = Settings.shared.translationHighAccuracy ? .on : .off
        accuracyToggle.target = self
        accuracyToggle.action = #selector(toggleAccuracy)
        accuracyToggle.toolTip = "Use the full Whisper large-v3 model for better transcription "
            + "accuracy. Slower to transcribe; takes effect on the next Start."
        accuracyToggle.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [NSTextField(labelWithString: "From:"), sourcePopup,
                                           NSTextField(labelWithString: "To:"), targetPopup,
                                           startButton, clearButton])
        controls.orientation = .horizontal; controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        // Second row: audio source picker + the accuracy toggle.
        let row2 = NSStackView(views: [NSTextField(labelWithString: "Audio:"), audioPopup, accuracyToggle])
        row2.orientation = .horizontal; row2.spacing = 8
        row2.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail; statusLabel.translatesAutoresizingMaskIntoConstraints = false
        detectedLabel.font = .systemFont(ofSize: 11, weight: .medium); detectedLabel.textColor = .systemBlue
        detectedLabel.alignment = .right; detectedLabel.translatesAutoresizingMaskIntoConstraints = false

        outputView.isEditable = false
        outputView.textContainerInset = NSSize(width: 6, height: 8)
        let scroll = NSScrollView(); scroll.documentView = outputView
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(controls); addSubview(row2)
        addSubview(statusLabel); addSubview(detectedLabel); addSubview(scroll)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            row2.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            row2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row2.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: row2.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            detectedLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            detectedLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            detectedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    private func wireEngine() {
        engine.onStatus = { [weak self] s in self?.statusLabel.stringValue = s }
        engine.translator.onStatus = { [weak self] s in self?.statusLabel.stringValue = s }
        engine.onDetectedLanguage = { [weak self] s in self?.detectedLabel.stringValue = "Detected: \(s)" }
        engine.onLiveSource = { [weak self] s in self?.liveSourceText = s; self?.renderLive() }
        engine.onLiveTranslation = { [weak self] s in self?.liveTransText = s; self?.renderLive() }
        engine.onFinal = { [weak self] source, translated in
            guard let self = self else { return }
            // The engine drives the live line via onLiveSource/onLiveTranslation;
            // committing must not blank it — mid-speech commits leave a pending
            // remainder that stays live below the committed pair.
            self.commit(self.pairAttr(source: source, translated: translated, live: false))
        }
    }

    /// Builds a "source above / translation below" block.
    private func pairAttr(source: String, translated: String, live: Bool) -> NSAttributedString {
        let s = NSMutableAttributedString()
        var srcAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)]
        var trAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 16, weight: .medium)]
        if live {
            let hl = NSColor.controlAccentColor.withAlphaComponent(0.10)
            srcAttrs[.backgroundColor] = hl; trAttrs[.backgroundColor] = hl
        }
        s.append(NSAttributedString(string: source + "\n", attributes: srcAttrs))
        s.append(NSAttributedString(string: (translated.isEmpty ? "…" : translated) + "\n\n", attributes: trAttrs))
        return s
    }

    /// Replaces the live tail (after the committed text) with the current pair.
    private func renderLive() {
        guard let ts = outputView.textStorage else { return }
        let liveRange = NSRange(location: committedLength, length: ts.length - committedLength)
        let attr = (liveSourceText.isEmpty && liveTransText.isEmpty)
            ? NSAttributedString(string: "")
            : pairAttr(source: liveSourceText, translated: liveTransText, live: true)
        ts.replaceCharacters(in: liveRange, with: attr)
        outputView.scrollToEndOfDocument(nil)
    }

    /// Commits a finalized pair, moving the boundary so it stays put.
    private func commit(_ attr: NSAttributedString) {
        guard let ts = outputView.textStorage else { return }
        let liveRange = NSRange(location: committedLength, length: ts.length - committedLength)
        ts.replaceCharacters(in: liveRange, with: attr)
        committedLength = ts.length
        outputView.scrollToEndOfDocument(nil)
    }

    @objc private func clearOutput() {
        outputView.string = ""; committedLength = 0
        liveSourceText = ""; liveTransText = ""; detectedLabel.stringValue = ""
    }

    /// Persist the accuracy choice. It changes which model loads, so it only
    /// takes effect on the next Start (the engine reloads if the mode changed).
    @objc private func toggleAccuracy(_ sender: NSButton) {
        Settings.shared.translationHighAccuracy = (sender.state == .on)
        Settings.shared.save()
        statusLabel.stringValue = sender.state == .on
            ? "Higher accuracy on — full large-v3 loads on the next Start (slower)."
            : "Higher accuracy off — fast large-v3 turbo loads on the next Start."
    }

    /// Persist the last-used From/To languages so they're restored next launch.
    @objc private func languageChanged() {
        Settings.shared.translationSourceCode = (sourcePopup.selectedItem?.representedObject as? String) ?? ""
        Settings.shared.translationTargetCode = (targetPopup.selectedItem?.representedObject as? String) ?? "en"
        Settings.shared.save()
    }

    /// Persist System/Microphone choices. Per-app picks aren't persisted because
    /// a pid isn't stable across launches.
    @objc private func audioChanged() {
        if let s = audioPopup.selectedItem?.representedObject as? String {
            Settings.shared.translationAudioSource = s
            Settings.shared.save()
        }
    }

    /// Select the popup item whose representedObject code matches, else the first.
    private static func selectByCode(_ popup: NSPopUpButton, code: String) {
        if !code.isEmpty {
            for item in popup.itemArray where (item.representedObject as? String) == code {
                popup.select(item); return
            }
        }
        popup.selectItem(at: 0)
    }

    /// Fill the audio popup: System, Microphone, then each running regular app
    /// (its pid stored in representedObject). Rebuilt each time the tab is built
    /// so the app list is current.
    private func populateAudioSources() {
        audioPopup.removeAllItems()
        audioPopup.addItem(withTitle: "System audio")
        audioPopup.lastItem?.representedObject = "system"
        audioPopup.addItem(withTitle: "Microphone")
        audioPopup.lastItem?.representedObject = "mic"

        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me
                      && ($0.localizedName?.isEmpty == false) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        if !apps.isEmpty { audioPopup.menu?.addItem(.separator()) }
        for app in apps {
            audioPopup.addItem(withTitle: app.localizedName ?? "App")
            audioPopup.lastItem?.representedObject = Int(app.processIdentifier)
        }
        // Restore System/Mic; app selections aren't persisted (pid changes).
        Self.selectByCode(audioPopup, code: Settings.shared.translationAudioSource)
    }

    /// Read the audio-source selection into the engine.
    private func applyAudioSelection() {
        guard let ro = audioPopup.selectedItem?.representedObject else {
            engine.setAudioSource(.system); return
        }
        if let s = ro as? String {
            engine.setAudioSource(s == "mic" ? .microphone : .system)
        } else if let pidInt = ro as? Int {
            engine.setAudioSource(.app(pid: pid_t(pidInt), name: audioPopup.titleOfSelectedItem ?? "App"))
        } else {
            engine.setAudioSource(.system)
        }
    }

    private func setControlsEnabled(_ on: Bool) {
        sourcePopup.isEnabled = on; targetPopup.isEnabled = on
        audioPopup.isEnabled = on; accuracyToggle.isEnabled = on
    }

    @objc private func toggleRun() {
        if running {
            engine.stop(); running = false; startButton.title = "Start"
            setControlsEnabled(true)
            return
        }
        // nil representedObject = the "Automatic (detect)" row.
        let sourceCode = sourcePopup.selectedItem?.representedObject as? String
        let targetCode = targetPopup.selectedItem?.representedObject as? String ?? "en"
        let target = Locale(identifier: targetCode)
        engine.setLanguages(sourceCode: sourceCode, target: target)
        applyAudioSelection()
        if let host = engine.translator.hostingView, host.superview == nil {
            host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            addSubview(host)
        }
        detectedLabel.stringValue = ""
        engine.start()
        running = true; startButton.title = "Stop"
        // Locked while running — languages, audio source, and model are set at Start.
        setControlsEnabled(false)
    }

    func stopIfRunning() {
        if running {
            engine.stop(); running = false; startButton.title = "Start"
            setControlsEnabled(true)
        }
    }
}
