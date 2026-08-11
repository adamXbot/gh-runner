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

    /// Short name of the macOS account that owns the runner directory, and so
    /// the account its jobs execute as.
    ///
    /// Worth surfacing because the account IS the security boundary on a
    /// persistent host: a runner sitting in an administrator's home runs every
    /// pull request with that administrator's reach. Discovery finds runners
    /// through the process table, which spans all users, so a row can easily
    /// describe a runner this app cannot control and should not be trusted to.
    var ownerAccountName: String? {
        guard let uid = ownerUserID else { return nil }
        return Self.accountName(forUserID: uid)
    }

    var ownerUserID: uid_t? {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: directory.path),
              let owner = attributes[.ownerAccountID] as? NSNumber else { return nil }
        return uid_t(truncating: owner)
    }

    /// False when the directory belongs to a different macOS account. Those
    /// runners are visible but not operable: `svc.sh` talks to launchd in the
    /// owner's GUI session, which this process cannot reach.
    var isOwnedByCurrentUser: Bool {
        guard let uid = ownerUserID else { return true }
        return uid == getuid()
    }

    private static func accountName(forUserID uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
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
