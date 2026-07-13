import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` to open the app at login (the app itself, not the runner).
enum LoginItem {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static var statusDescription: String {
        switch status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not enabled"
        case .requiresApproval: return "Requires approval in System Settings › General › Login Items"
        case .notFound: return "Unavailable (run from a built .app bundle)"
        @unknown default: return "Unknown"
        }
    }

    /// Register or unregister the app as a login item. Throws on failure.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
