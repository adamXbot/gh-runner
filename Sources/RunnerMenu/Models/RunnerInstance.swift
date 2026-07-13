import Foundation

/// A managed runner directory on disk. One instance == one `actions-runner`
/// folder, which GitHub binds to at most one repo/org at a time.
struct RunnerInstance: Identifiable, Equatable, Sendable {
    /// Stable identity derived from the directory path.
    let id: String
    var directory: URL
    var config: RunnerConfig?
    /// Version reported by `bin/Runner.Listener --version`, if resolvable.
    var installedVersion: String?

    init(directory: URL, config: RunnerConfig? = nil, installedVersion: String? = nil) {
        self.directory = directory.standardizedFileURL
        self.id = self.directory.path
        self.config = config
        self.installedVersion = installedVersion
    }

    /// Human-facing name: the registered agent name, else the folder name.
    var displayName: String {
        config?.agentName ?? directory.lastPathComponent
    }

    /// True when a `.runner` file exists and parsed.
    var isConfigured: Bool { config != nil }

    /// `owner/repo` or org/enterprise label when configured.
    var scopeLabel: String? { config?.scope.displayString }

    /// The GitHub web URL this runner is registered against.
    var gitHubURL: URL? {
        guard let s = config?.gitHubUrl else { return nil }
        return URL(string: s)
    }

    /// Whether the runner's core scripts are present (a real runner install).
    var looksLikeRunnerDirectory: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: directory.appendingPathComponent("run.sh").path)
            && fm.fileExists(atPath: directory.appendingPathComponent("config.sh").path)
    }

    static func == (lhs: RunnerInstance, rhs: RunnerInstance) -> Bool {
        lhs.id == rhs.id
            && lhs.config == rhs.config
            && lhs.installedVersion == rhs.installedVersion
    }
}
