import Foundation

/// The macOS account whose UID owns runner processes and job workspaces.
enum RunnerExecutionMode: String, CaseIterable, Identifiable, Sendable {
    case currentAccount
    case dedicatedAccount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentAccount: return "This Account"
        case .dedicatedAccount: return "Dedicated Runner Account"
        }
    }
}
