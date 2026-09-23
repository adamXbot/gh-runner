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
    case runnerAccountNotReady(RunnerAccountStatus)

    var errorDescription: String? {
        switch self {
        case .runnerAccountNotReady(let status):
            return status.guidance
        }
    }
}

enum RunnerAccountStatus: Equatable {
    case missing
    case administrator
    case standard
    case unableToVerify

    var isReady: Bool { self == .standard }

    var guidance: String {
        switch self {
        case .missing:
            return "Create a standard macOS account with the short name ‘runner’ in System Settings › Users & Groups."
        case .administrator:
            return "The ‘runner’ account has administrator access. Change it to a standard account in Users & Groups before enabling Runner Agent."
        case .standard:
            return "The ‘runner’ account exists and is a standard account."
        case .unableToVerify:
            return "Runner Menu could not verify the ‘runner’ account's group membership. Check it in Users & Groups, then refresh status."
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

    static var runnerAccountStatus: RunnerAccountStatus {
        guard let account = getpwnam(RunnerAgentConstants.accountName) else { return .missing }
        let uid = account.pointee.pw_uid
        let primaryGroup = account.pointee.pw_gid
        guard uid != 0, let adminGroup = getgrnam("admin")?.pointee.gr_gid else {
            return .unableToVerify
        }

        var count: Int32 = 16
        var groups = [gid_t](repeating: 0, count: Int(count))
        var result = RunnerAgentConstants.accountName.withCString {
            getgrouplist($0, Int32(primaryGroup), &groups, &count)
        }
        if result == -1, count > 0 {
            groups = [gid_t](repeating: 0, count: Int(count))
            result = RunnerAgentConstants.accountName.withCString {
                getgrouplist($0, Int32(primaryGroup), &groups, &count)
            }
        }
        guard result != -1 else { return .unableToVerify }
        return groups.prefix(Int(count)).contains(adminGroup) ? .administrator : .standard
    }

    static var hasProductionSigningIdentity: Bool {
        RunnerAgentCodeSigning.currentTeamIdentifier() != nil
    }

    static func register() throws {
        let accountStatus = runnerAccountStatus
        guard accountStatus.isReady else {
            throw RunnerAgentManagerError.runnerAccountNotReady(accountStatus)
        }
        try service.register()
    }

    static func unregister() throws {
        try service.unregister()
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
