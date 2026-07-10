import Cocoa
import SwiftUI
import Speech
import ScreenCaptureKit
import Translation
import NaturalLanguage
import CoreMedia
import AVFoundation

// MARK: - On-device translation bridge (macOS 15+)

/// Apple's Translation framework only vends a `TranslationSession` through the
/// SwiftUI `.translationTask` modifier, so we host a tiny offscreen SwiftUI view
/// and funnel strings through it.
@available(macOS 15.0, *)
final class TranslationBridge: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var onStatus: ((String) -> Void)?

    typealias Job = (text: String, completion: (String) -> Void)
    private var stream: AsyncStream<Job>!
    private var continuation: AsyncStream<Job>.Continuation!
    private var warned = false

    init() { remakeStream() }

    private func remakeStream() {
        var cont: AsyncStream<Job>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    private var lastPairKey = ""

    func configure(source: Locale.Language?, target: Locale.Language) {
        // End the previous session's job loop; the (re-)run translationTask will
        // consume a fresh stream with the new session.
        continuation.finish()
        remakeStream()
        warned = false
        let key = "\(source?.minimalIdentifier ?? "auto")→\(target.minimalIdentifier)"
        if key == lastPairKey, configuration != nil {
            // Same language pair as last time: assigning an equal Configuration
            // does NOT re-trigger .translationTask, so the fresh stream would sit
            // unconsumed and every translation would hang — the ordered
            // transcript queue then freezes and lines vanish on the next
            // restart (observed as "text overwritten / not captured").
            // invalidate() is Apple's documented way to force a new session.
            configuration?.invalidate()
        } else {
            lastPairKey = key
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// Runs INSIDE the `.translationTask` closure — the only context in which
    /// Apple allows the session to be used. The old design retained the session
    /// and called it later from ad-hoc Tasks; once the session went stale
    /// mid-meeting, an internal framework assertion in
    /// `_LTTextSessionRequest didReceiveError:` crashed the app (SIGTRAP on the
    /// com.apple.translation.TextSession queue). Consuming jobs in a single
    /// serial loop here also stops concurrent calls into one session.
    func run(_ session: TranslationSession) async {
        do { try await session.prepareTranslation() }
        catch {
            onStatus?("Couldn't prepare translation — download this language pair in Apple's Translate app, then press Start again.")
        }
        for await job in stream {
            do {
                let responses = try await session.translations(from: [.init(sourceText: job.text)])
                job.completion(responses.first?.targetText ?? job.text)
            } catch {
                if !warned {
                    warned = true
                    onStatus?("Translation error — showing original text. (\(error.localizedDescription))")
                }
                job.completion(job.text)
            }
        }
    }

    func enqueue(_ text: String, completion: @escaping (String) -> Void) {
        // If the stream was just torn down (language switch), complete with the
        // original text rather than dropping the job — a swallowed completion
        // would stall the ordered emit queue and freeze the transcript.
        if case .terminated = continuation.yield((text, completion)) {
            completion(text)
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationHostView: View {
    @ObservedObject var bridge: TranslationBridge
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in await bridge.run(session) }
    }
}

/// Version-agnostic wrapper around the translation bridge.
final class Translator {
    private var bridge: AnyObject?
    private(set) var hostingView: NSView?
    private(set) var isAvailable = false
    var onStatus: ((String) -> Void)?

    func configure(source: Locale?, target: Locale) {
        guard #available(macOS 15.0, *) else { isAvailable = false; return }
        let b: TranslationBridge
        if let existing = bridge as? TranslationBridge { b = existing }
        else {
            b = TranslationBridge(); bridge = b
            b.onStatus = { [weak self] s in self?.onStatus?(s) }
            let host = NSHostingView(rootView: TranslationHostView(bridge: b))
            host.translatesAutoresizingMaskIntoConstraints = false
            hostingView = host
        }
        let src = source.map { Locale.Language(identifier: $0.identifier) }
        b.configure(source: src, target: Locale.Language(identifier: target.identifier))
        isAvailable = true
    }

    func translate(_ text: String, _ completion: @escaping (String) -> Void) {
        if #available(macOS 15.0, *), let b = bridge as? TranslationBridge, isAvailable {
            b.enqueue(text, completion: completion)
        } else { completion(text) }
    }
}

// MARK: - Live meeting translator

/// Where the audio being transcribed comes from.
enum AudioSource {
    case system                       // everything the Mac is playing
    case app(pid: pid_t, name: String) // one application's audio only
    case microphone                   // the Mac's mic (people in the room)
}

@available(macOS 13.0, *)
final class LiveTranslator: NSObject, SCStreamDelegate, SCStreamOutput {
    var onLiveSource: ((String) -> Void)?
    var onLiveTranslation: ((String) -> Void)?
    var onFinal: ((_ source: String, _ translated: String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onDetectedLanguage: ((String) -> Void)?

    let translator = Translator()
    var autoDetect = false

    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?     // microphone source
    private var audioSource: AudioSource = .system
    private let audioQueue = DispatchQueue(label: "windowsnap.translate.audio")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sourceLocale = Locale(identifier: "en-US")
    private var targetLocale = Locale(identifier: "en")
    private var currentLangCode = "en"
    private var lastPartialTranslate = Date.distantPast
    private var committedSource = ""       // this utterance's text already locked on screen
    private var lastCommittedSentence = "" // duplicate guard for commits
    private var commitSeq = 0              // sequence number assigned to each finalized line
    private var nextEmit = 0               // next sequence to hand to the UI (keeps order)
    private var pendingCommits: [Int: (String, String)] = [:]
    private var stableCandidate: String?   // sentence block waiting to prove stable
    private var stableSince = Date()
    private var taskGeneration = 0         // invalidates callbacks from cancelled tasks
    private(set) var isRunning = false

    func setLanguages(source: Locale?, target: Locale) {
        targetLocale = target
        if let source = source {
            autoDetect = false; sourceLocale = source
        } else {
            autoDetect = true; sourceLocale = Locale(identifier: Locale.current.identifier)
        }
        currentLangCode = sourceLocale.language.languageCode?.identifier ?? "en"
        // Give the translator an explicit source when known; nil while auto-detecting.
        translator.configure(source: autoDetect ? nil : source, target: target)
    }

    func setAudioSource(_ s: AudioSource) { audioSource = s }

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard status == .authorized else {
                    self.onStatus?("Speech Recognition isn't authorized. Enable WindowSnap under System Settings → Privacy & Security → Speech Recognition.")
                    return
                }
                self.beginCapture()
            }
        }
    }

    private func beginCapture() {
        guard let rec = SFSpeechRecognizer(locale: sourceLocale), rec.isAvailable else {
            onStatus?("Speech recognition isn't available for that language."); return
        }
        recognizer = rec
        isRunning = true
        commitSeq = 0; nextEmit = 0; pendingCommits.removeAll()
        stableCandidate = nil
        startRecognitionTask()
        if case .microphone = audioSource {
            startMicrophone()
        } else {
            Task { await setupStream() }
        }
    }

    /// Microphone source: feed the recognizer from the input device instead of
    /// captured system audio (for translating people speaking in the room).
    private func startMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    self.onStatus?("Microphone access denied. Enable WindowSnap under System Settings → Privacy & Security → Microphone.")
                    self.isRunning = false
                    return
                }
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                    guard let self = self, self.isRunning else { return }
                    self.request?.append(buffer)
                }
                do {
                    try engine.start()
                    self.audioEngine = engine
                    self.onStatus?(self.translator.isAvailable
                                   ? "Listening to the microphone…"
                                   : "Listening to the microphone — transcription only (translation needs macOS 15+).")
                } catch {
                    self.onStatus?("Couldn't start the microphone — \(error.localizedDescription)")
                    self.isRunning = false
                }
            }
        }
    }

    private func startRecognitionTask() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true                       // include punctuation
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req
        // Cancelled tasks still fire their callback — often with an error AND a
        // last "final" result repeating the utterance. Without this generation
        // guard, that callback re-committed the same text (duplicated lines) and
        // its error triggered another restart that killed the fresh task (gaps
        // where nothing was listening). Stale generations are ignored entirely.
        let gen = taskGeneration
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self, gen == self.taskGeneration else { return }
            if let result = result {
                self.handleResult(result.bestTranscription.formattedString, isFinal: result.isFinal)
            }
            // A finished/errored task is dead; restart to keep listening. `isFinal`
            // fires on a natural pause, which is also where we want a new line.
            if error != nil { self.restartRecognition(afterPause: false) }
        }
    }

    /// Flows the running transcript into committed lines without ever losing or
    /// rewriting text. Partial transcripts get REVISED retroactively by the
    /// recognizer, so a sentence is only committed once it has been stable for a
    /// moment — committing eagerly baked in text the recognizer later rewrote
    /// (seen as overwritten lines) or mis-sliced it (dropped words).
    private func handleResult(_ full: String, isFinal: Bool) {
        let pending = pendingText(in: full)

        // A pause finalizes the utterance: commit everything still pending —
        // this text is final, no stability wait needed — and restart fresh so
        // the next words (often a new speaker) begin a new line.
        if isFinal {
            let (sentences, remainder) = Self.splitSentences(pending)
            for sent in sentences { commitIfFresh(sent) }
            commitIfFresh(remainder)
            DispatchQueue.main.async { self.onLiveSource?(""); self.onLiveTranslation?("") }
            restartRecognition(afterPause: true)
            return
        }

        // Live line always shows ALL not-yet-committed text, so nothing spoken
        // is ever invisible while it waits to stabilize.
        DispatchQueue.main.async { self.onLiveSource?(pending.trimmingCharacters(in: .whitespacesAndNewlines)) }
        throttledLiveTranslate(pending)

        // Candidate block = leading complete sentences (or a long run-on chunk).
        let (sentences, remainder) = Self.splitSentences(pending)
        var block = sentences.joined()
        if block.isEmpty && remainder.count > 80 { block = remainder }
        guard !block.isEmpty else { stableCandidate = nil; return }

        if block == stableCandidate {
            // Unchanged across updates for 1s → safe to lock in permanently.
            guard Date().timeIntervalSince(stableSince) >= 1.0 else { return }
            stableCandidate = nil
            committedSource += block
            let (blockSentences, blockRest) = Self.splitSentences(block)
            for sent in blockSentences { commitIfFresh(sent) }
            commitIfFresh(blockRest)   // run-on chunk case
            let rest = String(pending.dropFirst(block.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.onLiveSource?(rest); self.onLiveTranslation?("") }
        } else {
            stableCandidate = block
            stableSince = Date()
        }
    }

    /// Aligns the recognizer's latest transcript against the text already locked
    /// on screen. The recognizer REVISES its transcript retroactively, so a fixed
    /// character offset drifts: a leftward shift re-included committed text
    /// (duplicated/"overwritten" lines) and a rightward shift skipped fresh words
    /// (missing speech). Re-anchoring on the last committed characters tolerates
    /// those revisions.
    private func pendingText(in full: String) -> String {
        guard !committedSource.isEmpty else { return full }
        // Fast path: transcript still extends exactly what we committed.
        if full.hasPrefix(committedSource) {
            return String(full.dropFirst(committedSource.count))
        }
        // Revision changed earlier text. Anchor on the tail of what we committed;
        // everything after its last occurrence is genuinely new.
        let anchor = String(committedSource.suffix(20))
        if !anchor.isEmpty, let r = full.range(of: anchor, options: .backwards) {
            return String(full[r.upperBound...])
        }
        // Anchor itself was revised away — length split so new words aren't lost.
        if full.count > committedSource.count {
            return String(full.suffix(full.count - committedSource.count))
        }
        return ""
    }

    /// Commits one line unless it's an exact repeat of the previous commit —
    /// the last defense against a revision echoing an already-written sentence.
    private func commitIfFresh(_ raw: String) {
        let src = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, src != lastCommittedSentence else { return }
        lastCommittedSentence = src
        commitLine(src)
    }

    /// Finalizes one line: detect language (auto), translate, and emit — in
    /// ORDER. Translations complete asynchronously and can return out of order
    /// (a short sentence outruns a long one), which used to scramble the
    /// transcript; each line now waits its turn.
    private func commitLine(_ src: String) {
        maybeDetectAndSwitch(src)
        let seq = commitSeq; commitSeq += 1
        translator.translate(src) { tr in
            DispatchQueue.main.async {
                guard seq >= self.nextEmit else { return }   // timeout already emitted it
                self.pendingCommits[seq] = (src, tr)
                self.emitReady()
            }
        }
        // Anti-stall: one line whose translation never returns must not freeze
        // the whole ordered transcript behind it. After 8s, emit it with the
        // source text so the book keeps flowing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, seq >= self.nextEmit, self.pendingCommits[seq] == nil else { return }
            self.pendingCommits[seq] = (src, src)
            self.emitReady()
        }
    }

    /// Hands finished lines to the UI strictly in sequence.
    private func emitReady() {
        while let (src, tr) = pendingCommits[nextEmit] {
            pendingCommits.removeValue(forKey: nextEmit)
            nextEmit += 1
            onFinal?(src, tr)
        }
    }

    /// Throttled translation of the in-progress text. Results are dropped if a
    /// commit or task restart happened in the meantime — otherwise a slow
    /// translation of pre-commit text would repopulate the live line with a copy
    /// of the pair just committed above it.
    private func throttledLiveTranslate(_ src: String) {
        let t = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, Date().timeIntervalSince(lastPartialTranslate) > 0.5 else { return }
        lastPartialTranslate = Date()
        let markerCommitted = committedSource.count
        let markerGen = taskGeneration
        translator.translate(t) { tr in
            DispatchQueue.main.async {
                guard markerCommitted == self.committedSource.count,
                      markerGen == self.taskGeneration else { return }
                self.onLiveTranslation?(tr)
            }
        }
    }

    /// Splits into complete sentences (kept with punctuation) + trailing
    /// remainder. Hard enders always close a sentence; commas and other clause
    /// marks close one only once it's at least `softMinLen` characters long —
    /// continuous Mandarin speech is punctuated almost entirely with commas, so
    /// without the soft rule the text never reaches a boundary and nothing ever
    /// commits to the transcript.
    static func splitSentences(_ s: String, softMinLen: Int = 20) -> ([String], String) {
        let hard: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "\n"]
        let soft: Set<Character> = [",", "，", "、", ";", "；", ":", "："]
        var sentences: [String] = []
        var current = ""
        for ch in s {
            current.append(ch)
            if hard.contains(ch) || (soft.contains(ch) && current.count >= softMinLen) {
                sentences.append(current); current = ""
            }
        }
        return (sentences, current)
    }

    private func maybeDetectAndSwitch(_ text: String) {
        guard autoDetect, text.count > 8 else { return }
        let r = NLLanguageRecognizer(); r.processString(text)
        guard let lang = r.dominantLanguage else { return }
        let code = lang.rawValue
        DispatchQueue.main.async {
            self.onDetectedLanguage?(Locale.current.localizedString(forLanguageCode: code) ?? code)
        }
        guard code != currentLangCode, let loc = Self.speechLocale(forLanguageCode: code) else { return }
        currentLangCode = code
        sourceLocale = loc
        recognizer = SFSpeechRecognizer(locale: loc)
        // Now that we know the source, give the translator an explicit direction.
        translator.configure(source: loc, target: targetLocale)
    }

    static func speechLocale(forLanguageCode code: String) -> Locale? {
        SFSpeechRecognizer.supportedLocales().first { $0.language.languageCode?.identifier == code }
    }

    /// Restarts the recognition task. On a natural pause we restart immediately
    /// (no audio is being spoken, so nothing is lost); on an error we wait a beat
    /// to avoid a tight loop. We do NOT restart during continuous speech, which is
    /// what previously dropped words during the gap.
    private func restartRecognition(afterPause: Bool) {
        taskGeneration += 1   // anything the old task still delivers is stale
        task?.cancel(); task = nil; request = nil
        committedSource = ""  // a fresh task starts a fresh cumulative transcript
        stableCandidate = nil
        guard isRunning else { return }
        if afterPause {
            startRecognitionTask()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard self?.isRunning == true else { return }
                self?.startRecognitionTask()
            }
        }
    }

    private func setupStream() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                onMain("No display available to capture audio from."); isRunning = false; return
            }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.width = 2; config.height = 2
            // Filter by source: everything, or a single app's audio only.
            let filter: SCContentFilter
            let sourceDesc: String
            switch audioSource {
            case .app(let pid, let name):
                guard let scApp = content.applications.first(where: { $0.processID == pid }) else {
                    onMain("\(name) isn't available to capture — is it still running?")
                    isRunning = false
                    return
                }
                filter = SCContentFilter(display: display, including: [scApp], exceptingWindows: [])
                sourceDesc = "\(name) audio"
            default:
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                sourceDesc = "system audio"
            }
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await s.startCapture()
            stream = s
            onMain(translator.isAvailable
                   ? (autoDetect ? "Listening to \(sourceDesc) — detecting language…" : "Listening to \(sourceDesc)…")
                   : "Listening to \(sourceDesc) — transcription only (translation needs macOS 15+).")
        } catch {
            onMain("Couldn't start audio capture (Screen Recording permission?). \(error.localizedDescription)")
            isRunning = false
        }
    }

    func stop() {
        isRunning = false
        taskGeneration += 1
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        committedSource = ""
        lastCommittedSentence = ""
        stableCandidate = nil
        pendingCommits.removeAll()
        onMain("Stopped.")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRunning else { return }
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    private func onMain(_ s: String) { DispatchQueue.main.async { self.onStatus?(s) } }
}

// MARK: - Translation tab

@available(macOS 13.0, *)
final class TranslationPane: NSView, NSMenuDelegate {
    private let engine = LiveTranslator()
    private let audioPopup = NSPopUpButton()
    private let sourcePopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let startButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "Choose languages and press Start.")
    private let detectedLabel = NSTextField(labelWithString: "")
    private let outputView = NSTextView()

    private var sourceLocales: [Locale] = []
    private var running = false
    private var committedLength = 0
    private var liveSourceText = ""
    private var liveTransText = ""

    private static let targets: [(String, String)] = [
        ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Italian", "it"), ("Portuguese", "pt"), ("Chinese (Simplified)", "zh"),
        ("Japanese", "ja"), ("Korean", "ko"), ("Russian", "ru"), ("Arabic", "ar"),
        ("Hindi", "hi"), ("Dutch", "nl"), ("Polish", "pl"), ("Turkish", "tr"),
    ]

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build(); wireEngine() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        sourcePopup.addItem(withTitle: "Automatic (detect)")
        sourceLocales = SFSpeechRecognizer.supportedLocales().sorted {
            (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        }
        for loc in sourceLocales {
            sourcePopup.addItem(withTitle: Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier)
        }
        sourcePopup.selectItem(at: 0)
        for (name, _) in Self.targets { targetPopup.addItem(withTitle: name) }
        targetPopup.selectItem(at: 0)

        startButton.title = "Start"; startButton.bezelStyle = .rounded
        startButton.target = self; startButton.action = #selector(toggleRun)
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearOutput))
        clearButton.bezelStyle = .rounded

        rebuildAudioMenu()
        audioPopup.translatesAutoresizingMaskIntoConstraints = false
        audioPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let controls = NSStackView(views: [NSTextField(labelWithString: "Audio:"), audioPopup,
                                           NSTextField(labelWithString: "From:"), sourcePopup,
                                           NSTextField(labelWithString: "To:"), targetPopup,
                                           startButton, clearButton])
        controls.orientation = .horizontal; controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail; statusLabel.translatesAutoresizingMaskIntoConstraints = false
        detectedLabel.font = .systemFont(ofSize: 11, weight: .medium); detectedLabel.textColor = .systemBlue
        detectedLabel.alignment = .right; detectedLabel.translatesAutoresizingMaskIntoConstraints = false

        outputView.isEditable = false
        outputView.textContainerInset = NSSize(width: 6, height: 8)
        let scroll = NSScrollView(); scroll.documentView = outputView
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(controls); addSubview(statusLabel); addSubview(detectedLabel); addSubview(scroll)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
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

    /// Rebuilds the audio-source menu: System Audio, Microphone, then every
    /// running app so one app's audio (Teams, Zoom, Chrome…) can be isolated.
    /// Refreshed each time the menu opens so the app list is current.
    private func rebuildAudioMenu() {
        let selected = audioPopup.selectedItem?.representedObject
        let menu = audioPopup.menu ?? NSMenu()
        menu.removeAllItems()
        func add(_ title: String, _ rep: Any?) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.representedObject = rep
            menu.addItem(it)
        }
        add("System Audio", "system")
        add("Microphone", "mic")
        menu.addItem(.separator())
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPid }
            .compactMap { a in a.localizedName.map { ($0, Int(a.processIdentifier)) } }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        for (name, pid) in apps { add(name, pid) }
        if audioPopup.menu == nil { audioPopup.menu = menu }
        menu.delegate = self
        // Restore the previous selection (an app may have quit; fall back to System).
        let idx = menu.items.firstIndex {
            if let a = selected as? String, let b = $0.representedObject as? String { return a == b }
            if let a = selected as? Int, let b = $0.representedObject as? Int { return a == b }
            return false
        }
        audioPopup.selectItem(at: idx ?? 0)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == audioPopup.menu else { return }
        rebuildAudioMenu()
    }

    /// The engine AudioSource for the current dropdown selection.
    private func selectedAudioSource() -> AudioSource {
        let item = audioPopup.selectedItem
        if let s = item?.representedObject as? String, s == "mic" { return .microphone }
        if let pid = item?.representedObject as? Int, let name = item?.title {
            return .app(pid: pid_t(pid), name: name)
        }
        return .system
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

    @objc private func toggleRun() {
        if running {
            engine.stop(); running = false; startButton.title = "Start"
            sourcePopup.isEnabled = true; targetPopup.isEnabled = true; audioPopup.isEnabled = true
            return
        }
        let sel = sourcePopup.indexOfSelectedItem
        let source: Locale? = sel <= 0 ? nil : sourceLocales[sel - 1]
        let target = Locale(identifier: Self.targets[max(0, targetPopup.indexOfSelectedItem)].1)
        engine.setLanguages(source: source, target: target)
        engine.setAudioSource(selectedAudioSource())
        if let host = engine.translator.hostingView, host.superview == nil {
            host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            addSubview(host)
        }
        detectedLabel.stringValue = ""
        engine.start()
        running = true; startButton.title = "Stop"
        sourcePopup.isEnabled = false; targetPopup.isEnabled = false; audioPopup.isEnabled = false
    }

    func stopIfRunning() {
        if running {
            engine.stop(); running = false; startButton.title = "Start"
            sourcePopup.isEnabled = true; targetPopup.isEnabled = true; audioPopup.isEnabled = true
        }
    }
}
