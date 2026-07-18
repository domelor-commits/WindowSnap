import Cocoa
import SwiftUI
import Speech
import ScreenCaptureKit
import Translation
import NaturalLanguage
import CoreMedia
import AVFoundation
import WhisperKit

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

