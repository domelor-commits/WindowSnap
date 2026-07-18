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

