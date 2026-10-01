import Foundation

enum RunnerUpdatePhase: Equatable, Sendable {
    case downloading(Double), verifying, checkingIdle, stopping, installing, restarting

    var label: String {
        switch self {
        case .downloading: return "Downloading runner package…"
        case .verifying: return "Verifying download…"
        case .checkingIdle: return "Checking that the runner is idle…"
        case .stopping: return "Stopping the runner…"
        case .installing: return "Installing the runner package…"
        case .restarting: return "Restarting the runner…"
        }
    }
    var downloadFraction: Double? {
        if case .downloading(let fraction) = self { return fraction }
        return nil
    }
}

/// Persisted until the user confirms cleanup of the previous GitHub registration.
struct RegistrationCleanupNotice: Codable, Equatable {
    let runnerName: String
    let scope: String
    let settingsURL: URL?

    var message: String {
        "The previous registration for \(runnerName) on \(scope) could not be confirmed as removed. Check GitHub and remove it if it remains."
    }

    init(config: RunnerConfig) {
        runnerName = config.agentName
        scope = config.scope.displayString
        switch config.scope {
        case .repo(let owner, let name):
            settingsURL = URL(string: "https://github.com/\(owner)/\(name)/settings/actions/runners")
        case .org(let org):
            settingsURL = URL(string: "https://github.com/organizations/\(org)/settings/actions/runners")
        case .enterprise(let name):
            settingsURL = URL(string: "https://github.com/enterprises/\(name)/settings/actions/runners")
        case .unknown: settingsURL = nil
        }
    }
}
