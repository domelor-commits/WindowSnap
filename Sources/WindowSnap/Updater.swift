import Cocoa
#if canImport(Sparkle)
import Sparkle
#endif

/// Thin wrapper around Sparkle for auto-updates from GitHub Releases.
///
/// It stays dormant until BOTH of these are set in Info.plist:
///   • `SUFeedURL`      — the appcast URL (e.g. a GitHub Releases asset)
///   • `SUPublicEDKey`  — the EdDSA public key that matches the private key you
///                        sign each update with (`sign_update` from Sparkle)
///
/// Until those are filled in with real values (not the placeholders), the
/// background updater isn't started and "Check for Updates…" is hidden — so the
/// app runs perfectly well before update hosting is set up. See README for the
/// one-time GitHub + key setup.
final class UpdaterManager {
    static let shared = UpdaterManager()

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif

    /// True when a real appcast feed + public key are present (not placeholders).
    private(set) var isConfigured = false

    /// Read Info.plist and start the background updater if it's configured.
    func startIfConfigured() {
        let info = Bundle.main.infoDictionary
        let feed = (info?["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key  = (info?["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let placeholder =
            feed.isEmpty || feed.uppercased().contains("YOUR_GITHUB")
            || key.isEmpty || key.uppercased().contains("REPLACE_WITH")
        isConfigured = !placeholder

        guard isConfigured else {
            Logger.log("Updater: not configured (set SUFeedURL + SUPublicEDKey in Info.plist) — auto-update off")
            return
        }
        #if canImport(Sparkle)
        // startingUpdater:true reads SUFeedURL/SUPublicEDKey from Info.plist and
        // begins scheduled background checks (respecting SUEnableAutomaticChecks).
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        Logger.log("Updater: started (feed \(feed))")
        #else
        Logger.log("Updater: Sparkle not linked in this build")
        isConfigured = false
        #endif
    }

    /// Foreground "Check for Updates…" — shows Sparkle's UI (progress, release
    /// notes, install prompt). No-op when not configured.
    func checkForUpdates() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }
}
