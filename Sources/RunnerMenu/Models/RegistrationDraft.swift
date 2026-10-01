import Foundation
import Observation

/// Kept for the app session, including progress and recoverable errors.
@MainActor
@Observable
final class RegistrationDraft {
    enum Mode: String, CaseIterable, Identifiable {
        case existing = "Existing folder"
        case new = "New runner"
        var id: String { rawValue }
    }

    var mode: Mode = .new
    var search = ""
    var selectedRepo: GHRepo?
    var manualTarget = ""
    var showAdvanced = false
    var runnerName = ""
    var runnerNameEdited = false
    var labels = ""
    var existingDir: URL?
    var reconfigure = false
    var parentDir: URL?
    var folderName = ""
    var folderNameEdited = false
    var addToGitignore = false
    var isWorking = false
    var registrationPhase: RegistrationPhase?
    var operationIssue: RegistrationIssue?
    // Advanced registration options (map to config.sh flags).
    var showOptions = false
    var runnerGroup = ""
    var disableUpdate = false
    var ephemeral = false
    var noDefaultLabels = false

}
