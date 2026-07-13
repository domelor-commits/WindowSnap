import Cocoa
import SwiftUI
import Speech
import ScreenCaptureKit
import Translation
import NaturalLanguage
import CoreMedia
import AVFoundation
import WhisperKit

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

@available(macOS 14.0, *)
final class LiveTranslator: NSObject, SCStreamDelegate, SCStreamOutput {
    var onLiveSource: ((String) -> Void)?
    var onLiveTranslation: ((String) -> Void)?
    var onFinal: ((_ source: String, _ translated: String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onDetectedLanguage: ((String) -> Void)?

    let translator = Translator()
    var autoDetect = false

    // WhisperKit speech-to-text (large-v3-turbo). The model is heavy to load, so
    // it's cached across Start/Stop.
    private static var shared: WhisperKit?
    private static var loadedHighAccuracy: Bool?   // mode the cached model was loaded for
    private var whisper: WhisperKit?
    private var whisperLang: String?             // ISO code; nil = Whisper auto-detect
    // Newest audio kept unconfirmed so a segment gets right-context before it is
    // finalized. Tonal, space-less languages (Thai, Lao, Khmer, Burmese) need
    // more surrounding audio to disambiguate tones and word boundaries, so this
    // is deliberately generous rather than the ~0.4s a Latin-script language
    // could get away with.
    private let holdback: Float = 1.0
    // Don't attempt a decode until at least this much audio has accumulated.
    // Whisper's large models are trained on long windows and transcribe sub-second
    // clips very poorly (garbled output / wrong tones for Thai); ~1.2s of context
    // dramatically improves accuracy at the cost of a little added latency.
    private let minTranscribeSamples = 19_200   // 1.2s at 16 kHz
    // Below this RMS the window is treated as silence and not transcribed
    // (speech is typically ~0.02+; near-silence ~0.001).
    private let silenceRMS: Float = 0.005

    // Audio capture → a rolling 16 kHz mono sample window.
    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?
    private var audioSource: AudioSource = .system
    private let audioQueue = DispatchQueue(label: "windowsnap.translate.audio")
    private var windowSamples: [Float] = []      // only touched on audioQueue
    private var transcribing = false

    // Ordered commit + translation (drives the book-style display).
    private var targetLocale = Locale(identifier: "en")
    private var lastPartialTranslate = Date.distantPast
    private var lastCommittedSentence = ""
    // Rolling tail of recently committed source text, fed to Whisper as a
    // conditioning prompt so each new window decodes with context (Whisper's
    // "condition on previous text"). Improves continuity and cuts re-hallucination,
    // which matters most for context-dependent scripts like Thai and Chinese.
    private var promptText = ""
    private let promptCharLimit = 200
    private var commitSeq = 0
    private var nextEmit = 0
    private var pendingCommits: [Int: (String, String)] = [:]
    private(set) var isRunning = false

    /// `sourceCode` is a Whisper language code ("zh", "en", …) or nil to auto-detect.
    func setLanguages(sourceCode: String?, target: Locale) {
        targetLocale = target
        autoDetect = (sourceCode == nil)
        whisperLang = sourceCode
        translator.configure(source: sourceCode.map { Locale(identifier: $0) }, target: target)
    }

    func setAudioSource(_ s: AudioSource) { audioSource = s }

    func start() {
        isRunning = true
        commitSeq = 0; nextEmit = 0; pendingCommits.removeAll()
        lastCommittedSentence = ""
        promptText = ""
        audioQueue.async { self.windowSamples.removeAll() }
        let highAccuracy = Settings.shared.translationHighAccuracy
        onStatus?(highAccuracy
            ? "Preparing Whisper large-v3 (higher accuracy)…"
            : "Preparing Whisper large-v3 turbo (fast)…")
        Task { [weak self] in
            guard let self = self else { return }
            do {
                self.whisper = try await Self.loadSharedWhisper(highAccuracy: highAccuracy) { [weak self] pct in
                    DispatchQueue.main.async {
                        guard self?.isRunning == true else { return }
                        self?.onStatus?("Downloading model… \(pct)%")
                    }
                }
                await MainActor.run {
                    guard self.isRunning else { return }
                    self.onStatus?("Model ready — listening…")
                    self.beginCapture()
                    self.runTranscriptionLoop()
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.onStatus?("Couldn't load the Whisper model: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Loads (or returns the cached) shared WhisperKit model for the current
    /// accuracy mode, reporting download percentage. Shared by live translation
    /// and Dictate Anywhere so the ~1.5 GB model is loaded once.
    static func loadSharedWhisper(highAccuracy: Bool,
                                  progress: ((Int) -> Void)? = nil) async throws -> WhisperKit {
        if let existing = shared, loadedHighAccuracy == highAccuracy { return existing }
        let models = (try? await WhisperKit.fetchAvailableModels()) ?? []
        let name = preferredModelName(from: models)
        Logger.log("Whisper loading model: \(name) (highAccuracy=\(highAccuracy))")
        // Download (with progress) into the local cache, then load from that folder.
        let folder = try await WhisperKit.download(variant: name) { p in
            progress?(Int((p.fractionCompleted * 100).rounded()))
        }
        let wk = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, load: true, download: false))
        shared = wk
        loadedHighAccuracy = highAccuracy
        Logger.log("Whisper model loaded")
        return wk
    }

    /// Picks the Whisper model to load based on the "Higher accuracy" setting.
    /// "distil" variants are always excluded — distil-whisper is English-focused
    /// and transcribes Thai/Chinese/etc. as garbled English.
    ///
    /// High accuracy on  → prefer OpenAI full `large-v3` (best for tonal/space-less
    ///                      languages like Thai), falling back to turbo.
    /// High accuracy off → prefer the distilled `large-v3` turbo (much faster,
    ///                      lower latency), falling back to the full model.
    static func preferredModelName(from models: [String]) -> String {
        let highAccuracy = Settings.shared.translationHighAccuracy
        func isLargeV3(_ m: String) -> Bool {
            m.localizedCaseInsensitiveContains("large-v3")
                && !m.localizedCaseInsensitiveContains("distil")
        }
        let largeV3 = models.filter(isLargeV3)
        let full  = largeV3.filter { !$0.localizedCaseInsensitiveContains("turbo") }
        let turbo = largeV3.filter {  $0.localizedCaseInsensitiveContains("turbo") }
        func pick(_ arr: [String]) -> String? {
            arr.first(where: { $0.localizedCaseInsensitiveContains("openai") }) ?? arr.first
        }
        if highAccuracy {
            return pick(full) ?? pick(turbo) ?? "openai_whisper-large-v3"
        } else {
            return pick(turbo) ?? pick(full) ?? "openai_whisper-large-v3_turbo"
        }
    }

    func stop() {
        isRunning = false
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop(); audioEngine = nil
        audioQueue.async { self.windowSamples.removeAll() }
        onMain("Stopped.")
    }

    // MARK: Audio capture

    private func beginCapture() {
        if case .microphone = audioSource { startMicrophone() }
        else { Task { await setupStream() } }
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
            config.width = 2; config.height = 2   // native audio format; we resample to 16 kHz mono
            let filter: SCContentFilter
            let sourceDesc: String
            switch audioSource {
            case .app(let pid, let name):
                guard let scApp = content.applications.first(where: { $0.processID == pid }) else {
                    onMain("\(name) isn't available to capture — is it still running?"); isRunning = false; return
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
            onMain("Listening to \(sourceDesc)…")
        } catch {
            onMain("Couldn't start audio capture (Screen Recording permission?). \(error.localizedDescription)")
            isRunning = false
        }
    }

    private func startMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    self.onStatus?("Microphone access denied. Enable WindowSnap under System Settings → Privacy & Security → Microphone.")
                    self.isRunning = false; return
                }
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                    guard let self = self, self.isRunning else { return }
                    guard let resampled = AudioProcessor.resampleAudio(fromBuffer: buffer,
                                                                       toSampleRate: 16000, channelCount: 1) else { return }
                    let floats = AudioProcessor.convertBufferToArray(buffer: resampled)
                    self.audioQueue.async { self.windowSamples.append(contentsOf: floats) }
                }
                do {
                    try engine.start(); self.audioEngine = engine
                    self.onStatus?("Listening to the microphone…")
                } catch {
                    self.onStatus?("Couldn't start the microphone — \(error.localizedDescription)"); self.isRunning = false
                }
            }
        }
    }

    private var loggedFormat = false

    // SCStreamOutput — runs on audioQueue (our sampleHandlerQueue). Convert
    // whatever format SCK delivers into 16 kHz mono via AVAudioConverter rather
    // than assuming the bytes are already 16 kHz mono float (which gave Whisper
    // garbled audio → English hallucinations).
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRunning else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let inFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr
        else { return }

        if !loggedFormat {
            loggedFormat = true
            Logger.log("Whisper audio in: \(Int(inFormat.sampleRate))Hz \(inFormat.channelCount)ch")
        }
        guard let out = AudioProcessor.resampleAudio(fromBuffer: inBuf, toSampleRate: 16000, channelCount: 1) else { return }
        let floats = AudioProcessor.convertBufferToArray(buffer: out)
        if !floats.isEmpty { windowSamples.append(contentsOf: floats) }
    }

    // MARK: Transcription loop

    private func runTranscriptionLoop() {
        Task { [weak self] in
            while let self = self, self.isRunning {
                await self.transcribeStep()
                try? await Task.sleep(nanoseconds: 100_000_000)   // transcribe as fast as the model allows
            }
        }
    }

    private func transcribeStep() async {
        guard let whisper = whisper, !transcribing else { return }
        let samples: [Float] = audioQueue.sync { windowSamples }
        guard samples.count >= minTranscribeSamples else { return }   // need enough context
        transcribing = true
        defer { transcribing = false }
        let rms = (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        // Silence gate: when the whole window is essentially quiet, skip the decode.
        // Whisper otherwise hallucinates text (or parrots the prompt) on silence.
        // Trim the buffer so a long silent stretch can't grow it without bound.
        guard rms >= silenceRMS else {
            audioQueue.async {
                if self.windowSamples.count > self.minTranscribeSamples {
                    self.windowSamples.removeFirst(self.windowSamples.count - self.minTranscribeSamples)
                }
            }
            return
        }
        // Robust decoding tuned for accuracy on hard languages like Thai:
        //  • usePrefillPrompt + explicit language pin the correct language tokens
        //    (auto-detect only when the user picked "Automatic"), so Thai audio
        //    isn't mis-decoded as romanized/English.
        //  • temperature fallback retries a collapsed decode instead of emitting
        //    a repetition loop.
        //  • compression-ratio / log-prob / no-speech thresholds drop hallucinated
        //    or low-confidence output rather than committing garbage.
        //  • promptTokens condition the decode on recently committed text so the
        //    model keeps context across the rolling windows. WhisperKit trims these
        //    to its max prompt length and strips special tokens itself.
        var options = DecodingOptions(
            task: .transcribe,
            language: whisperLang,
            temperature: 0.0,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: whisperLang == nil,
            skipSpecialTokens: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )
        if !promptText.isEmpty, let toks = whisper.tokenizer?.encode(text: " " + promptText), !toks.isEmpty {
            options.promptTokens = toks
        }
        guard let results = try? await whisper.transcribe(audioArray: samples, decodeOptions: options),
              let result = results.first else { return }
        Logger.log(String(format: "Whisper lang=%@ set=%@ rms=%.3f: %@",
                          result.language, whisperLang ?? "auto", rms,
                          String(result.segments.map { $0.text }.joined().prefix(40))))
        await MainActor.run { self.handleWhisper(result, windowCount: samples.count) }
    }

    /// Confirms Whisper segments whose audio ended more than `holdback` before the
    /// window's newest audio (older segments are stable), commits them as lines,
    /// drops their audio from the window, and shows the rest as the live line.
    private func handleWhisper(_ result: TranscriptionResult, windowCount: Int) {
        guard isRunning else { return }
        if autoDetect, !result.language.isEmpty {
            onDetectedLanguage?(Locale.current.localizedString(forLanguageCode: result.language) ?? result.language)
        }
        let windowDur = Float(windowCount) / 16000
        let cutoff = windowDur - holdback
        var confirmedEnd: Float = 0
        var live = ""
        for seg in result.segments {
            if seg.end <= cutoff {
                let t = Self.cleanSegment(seg.text)
                if !t.isEmpty { commitIfFresh(t) }
                confirmedEnd = seg.end
            } else {
                live += seg.text
            }
        }
        // Window very long with nothing confirmable: force-confirm all but the last.
        if confirmedEnd == 0, windowDur > 12, result.segments.count > 1 {
            for seg in result.segments.dropLast() {
                let t = Self.cleanSegment(seg.text)
                if !t.isEmpty { commitIfFresh(t) }
                confirmedEnd = seg.end
            }
            live = result.segments.last?.text ?? ""
        }
        if confirmedEnd > 0 {
            let drop = Int(confirmedEnd * 16000)
            audioQueue.async {
                if drop < self.windowSamples.count { self.windowSamples.removeFirst(drop) }
                else { self.windowSamples.removeAll() }
            }
        }
        let liveTrim = Self.cleanSegment(live)
        onLiveSource?(liveTrim)
        throttledLiveTranslate(liveTrim)
    }

    /// Strips Whisper's non-speech markers so music/applause/etc. aren't shown or
    /// translated: musical-note glyphs and bracketed cues like "[Music]",
    /// "(applause)", "[BLANK_AUDIO]". Real words (including the Thai word for
    /// "song") are left untouched — only these markers are removed.
    private static let nonSpeechRegex = try! NSRegularExpression(
        pattern: "[\\[(【]\\s*(music|applause|laughter|blank[ _]?audio|silence|no speech|noise|sound|inaudible|foreign|speaking foreign language)\\s*[\\])】]",
        options: [.caseInsensitive])
    static func cleanSegment(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "♪", with: "")
                 .replacingOccurrences(of: "♫", with: "")
        let range = NSRange(t.startIndex..., in: t)
        t = nonSpeechRegex.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Commit + translate (ordered)

    private func commitIfFresh(_ raw: String) {
        let src = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, src != lastCommittedSentence else { return }
        lastCommittedSentence = src
        // Grow the conditioning prompt with this line, keeping only the recent tail.
        promptText = String((promptText + " " + src).suffix(promptCharLimit))
        commitLine(src)
    }

    private func commitLine(_ src: String) {
        let seq = commitSeq; commitSeq += 1
        translator.translate(src) { tr in
            DispatchQueue.main.async {
                guard seq >= self.nextEmit else { return }
                self.pendingCommits[seq] = (src, tr)
                self.emitReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, seq >= self.nextEmit, self.pendingCommits[seq] == nil else { return }
            self.pendingCommits[seq] = (src, src)
            self.emitReady()
        }
    }

    private func emitReady() {
        while let (src, tr) = pendingCommits[nextEmit] {
            pendingCommits.removeValue(forKey: nextEmit)
            nextEmit += 1
            onFinal?(src, tr)
        }
    }

    private func throttledLiveTranslate(_ src: String) {
        let t = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, Date().timeIntervalSince(lastPartialTranslate) > 0.5 else { return }
        lastPartialTranslate = Date()
        let markerSeq = commitSeq
        translator.translate(t) { tr in
            DispatchQueue.main.async {
                guard markerSeq == self.commitSeq else { return }
                self.onLiveTranslation?(tr)
            }
        }
    }

    private func onMain(_ s: String) { DispatchQueue.main.async { self.onStatus?(s) } }
}

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
