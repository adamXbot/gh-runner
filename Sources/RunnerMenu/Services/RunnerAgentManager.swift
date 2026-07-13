import Foundation
import ServiceManagement
import Darwin
import RunnerAgentProtocol

enum RunnerAgentRegistrationState: String, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    var label: String {
        switch self {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Awaiting approval"
        case .notFound: return "Not found in this app bundle"
        case .unknown: return "Unknown"
        }
    }
}

enum RunnerAgentManagerError: LocalizedError {
    case runnerAccountMissing

    var errorDescription: String? {
        switch self {
        case .runnerAccountMissing:
            return "Create the standard macOS account named ‘runner’ before registering the Runner Agent."
        }
    }
}

enum RunnerAgentManager {
    private static var service: SMAppService {
        SMAppService.daemon(plistName: RunnerAgentConstants.launchDaemonPlistName)
    }

    static var status: RunnerAgentRegistrationState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    static var runnerAccountExists: Bool {
        getpwnam(RunnerAgentConstants.accountName) != nil
    }

    static var hasProductionSigningIdentity: Bool {
        RunnerAgentCodeSigning.currentTeamIdentifier() != nil
    }

    static func register() throws {
        guard runnerAccountExists else { throw RunnerAgentManagerError.runnerAccountMissing }
        try service.register()
    }

    static func unregister() throws {
        try service.unregister()
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
