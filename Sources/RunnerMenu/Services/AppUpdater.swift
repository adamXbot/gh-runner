import Foundation
import Sparkle

/// Sparkle self-update for Runner Menu itself.
///
/// Distinct from `Updater.swift`, which updates the *GitHub Actions runner*
/// binaries this app manages. Both are called "updates" and neither is the
/// other: one replaces `bin/Runner.Listener` inside a runner directory, this
/// one replaces the app.
///
/// Refuses to run unsigned. Sparkle verifies an update's EdDSA signature
/// against `SUPublicEDKey` in Info.plist; ship without that key and the app
/// happily downloads and installs whatever the feed serves, which for an app
/// that manages CI hosts is a remote-code-execution channel rather than a
/// convenience. So an absent or placeholder key disables updating entirely and
/// says so, instead of degrading to unverified installs.
@MainActor
@Observable
final class AppUpdater {
    /// Nil when updating is unavailable — see `unavailableReason`.
    private let controller: SPUStandardUpdaterController?
    let unavailableReason: String?

    var canCheckForUpdates: Bool { controller != nil }

    init(bundle: Bundle = .main) {
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String

        switch Self.validate(publicKey: key, feedURL: feed) {
        case .some(let reason):
            controller = nil
            unavailableReason = reason
        case .none:
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            unavailableReason = nil
        }
    }

    /// Returns a human-readable reason updating is unavailable, or nil when the
    /// configuration is sound. Kept static and pure so it can be tested without
    /// starting a real updater.
    static func validate(publicKey: String?, feedURL: String?) -> String? {
        guard let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return "No SUPublicEDKey in Info.plist — updates are disabled because their signatures could not be verified."
        }
        // The build script substitutes the real key; catch a build that shipped
        // with the placeholder still in place.
        if key.hasPrefix("REPLACE_") || key.contains("$(") {
            return "SUPublicEDKey is still a placeholder (\(key)) — updates are disabled until the real key is baked in."
        }
        guard let feed = feedURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !feed.isEmpty else {
            return "No SUFeedURL in Info.plist — there is no appcast to check."
        }
        guard let url = URL(string: feed), url.scheme?.lowercased() == "https" else {
            return "SUFeedURL must be an https URL — refusing to fetch an appcast over an unauthenticated channel."
        }
        return nil
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
