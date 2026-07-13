import Cocoa
import AVFoundation
import WhisperKit

/// Dictate Anywhere: press the shortcut to record from the microphone; press it
/// again (or click Insert) to transcribe with Whisper and paste the text into
/// whatever app is frontmost. Reuses the shared WhisperKit model that live
/// translation loads, so no extra model download.
@available(macOS 14.0, *)
final class Dictation {
    static let shared = Dictation()

    private var engine: AVAudioEngine?
    private let audioQueue = DispatchQueue(label: "windowsnap.dictation.audio")
    private var samples: [Float] = []
    private(set) var isRecording = false
    private var transcribing = false
    private var escMonitor: Any?

    /// Toggle: start recording, or finish and transcribe if already recording.
    func toggle() {
        if isRecording { finish() }
        else if !transcribing { begin() }
    }

    func cancel() {
        guard isRecording else { return }
        stopEngine()
        isRecording = false
        DictationHUD.shared.hide()
        Logger.log("Dictation: cancelled")
    }

    // MARK: Recording

    private func begin() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    DictationHUD.shared.flashError("Microphone access denied. Enable WindowSnap under System Settings → Privacy & Security → Microphone.")
                    return
                }
                self.startEngine()
            }
        }
    }

    private func startEngine() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        audioQueue.async { self.samples.removeAll() }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            guard let resampled = AudioProcessor.resampleAudio(fromBuffer: buffer,
                                                               toSampleRate: 16000, channelCount: 1) else { return }
            let floats = AudioProcessor.convertBufferToArray(buffer: resampled)
            self.audioQueue.async { self.samples.append(contentsOf: floats) }
        }
        do {
            try engine.start()
            self.engine = engine
            isRecording = true
            DictationHUD.shared.showListening { [weak self] in self?.finish() } onCancel: { [weak self] in self?.cancel() }
            installEscMonitor()
            Logger.log("Dictation: listening")
        } catch {
            DictationHUD.shared.flashError("Couldn't start the microphone — \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        removeEscMonitor()
    }

    private func finish() {
        guard isRecording else { return }
        isRecording = false
        stopEngine()
        let captured = audioQueue.sync { samples }
        guard captured.count >= 8000 else {         // need ~0.5s of audio
            DictationHUD.shared.hide()
            Logger.log("Dictation: too short (\(captured.count) samples)")
            return
        }
        transcribing = true
        DictationHUD.shared.showTranscribing()
        let lang = Settings.shared.dictationLanguage.isEmpty ? nil : Settings.shared.dictationLanguage
        Task { [weak self] in
            defer { self?.transcribing = false }
            do {
                let whisper = try await LiveTranslator.loadSharedWhisper(
                    highAccuracy: Settings.shared.translationHighAccuracy)
                let options = DecodingOptions(
                    task: .transcribe, language: lang,
                    usePrefillPrompt: true, detectLanguage: lang == nil, skipSpecialTokens: true,
                    compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.6)
                let results = try await whisper.transcribe(audioArray: captured, decodeOptions: options)
                let raw = results.first?.segments.map { $0.text }.joined() ?? ""
                let text = LiveTranslator.cleanSegment(raw)
                await MainActor.run {
                    DictationHUD.shared.hide()
                    guard !text.isEmpty else { Logger.log("Dictation: no text recognized"); NSSound.beep(); return }
                    Dictation.insertText(text)
                    Logger.log("Dictation: inserted \(text.count) chars")
                }
            } catch {
                await MainActor.run {
                    DictationHUD.shared.flashError("Transcription failed — \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Esc-to-cancel

    private func installEscMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }   // Esc
        }
    }
    private func removeEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    // MARK: Insertion

    /// Insert text into the frontmost app via the clipboard + synthetic ⌘V, then
    /// restore the previous clipboard string.
    static func insertText(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        AppDelegate.synthesizeCmdV()
        if let previous = previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pb.clearContents(); pb.setString(previous, forType: .string)
            }
        }
    }
}

// MARK: - Recording HUD

/// A small floating HUD shown while dictation records/transcribes.
final class DictationHUD {
    static let shared = DictationHUD()

    private var panel: NSPanel?
    private var titleLabel: NSTextField?

    func showListening(onInsert: @escaping () -> Void, onCancel: @escaping () -> Void) {
        build(title: "🎤  Listening…",
              subtitle: "Press the dictation shortcut again to insert · Esc to cancel",
              buttons: [("Insert", onInsert), ("Cancel", onCancel)])
    }

    func showTranscribing() {
        build(title: "✍️  Transcribing…", subtitle: "Converting speech to text", buttons: [])
    }

    func flashError(_ message: String) {
        build(title: "⚠︎  Dictation", subtitle: message, buttons: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.hide() }
    }

    func hide() {
        panel?.orderOut(nil); panel = nil; titleLabel = nil
    }

    private func build(title: String, subtitle: String, buttons: [(String, () -> Void)]) {
        hide()
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow; backdrop.state = .active; backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 14; backdrop.layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        let subField = NSTextField(labelWithString: subtitle)
        subField.font = .systemFont(ofSize: 11); subField.textColor = .secondaryLabelColor
        subField.lineBreakMode = .byWordWrapping; subField.maximumNumberOfLines = 3
        subField.preferredMaxLayoutWidth = 300

        let textStack = NSStackView(views: [titleField, subField])
        textStack.orientation = .vertical; textStack.alignment = .leading; textStack.spacing = 3

        var rows: [NSView] = [textStack]
        if !buttons.isEmpty {
            let btnViews: [NSView] = buttons.map { (label, action) in
                let b = ClosureButton(title: label, action: action)
                b.bezelStyle = .rounded; b.controlSize = .small
                return b
            }
            let btnRow = NSStackView(views: btnViews)
            btnRow.orientation = .horizontal; btnRow.spacing = 8
            rows.append(btnRow)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor),
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        backdrop.layoutSubtreeIfNeeded()
        let size = backdrop.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = backdrop

        // Bottom-center of the screen under the pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 80))
        }
        p.orderFrontRegardless()
        panel = p
        titleLabel = titleField
    }
}

/// NSButton that runs a closure (used by the dictation HUD).
private final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
