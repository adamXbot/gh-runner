import Foundation
import Observation
import RunnerAgentProtocol

/// A transient message shown as a banner in the panel.
struct BannerMessage: Identifiable, Equatable {
    enum Kind { case info, success, error }
    let id = UUID()
    var text: String
    var kind: Kind
}

/// What clicking a recent job opens.
enum JobClickAction: String, CaseIterable, Sendable {
    case github
    case localLog

    var label: String {
        switch self {
        case .github: return "Open on GitHub"
        case .localLog: return "View local logs"
        }
    }
}

/// The central observable model. All UI reads from here; all actions route through here.
@MainActor
@Observable
final class RunnerStore {

    // MARK: - Published state
    var runners: [RunnerInstance] = []
    var statuses: [String: RunnerLiveStatus] = [:]
    var insights: [String: RunnerLogInsights] = [:]
    var ghAuth: GHAuthStatus = .unknown
    var selectedRunnerID: String?
    var banner: BannerMessage?
    var adminRepos: [GHRepo] = []
    var isLoadingRepos = false
    var lastRefresh: Date?
    var executionMode: RunnerExecutionMode = .currentAccount {
        didSet {
            guard isReady else { return }
            defaults.set(executionMode.rawValue, forKey: Keys.executionMode)
        }
    }
    private(set) var onboardingCompleted = false
    private(set) var isDiscoveringRunners = false
    private(set) var discoveredRunners: [RunnerInstance] = []
    private(set) var runnerAgentRegistrationState: RunnerAgentRegistrationState = RunnerAgentManager.status
    private(set) var runnerAgentHealth: RunnerAgentHealth?
    private(set) var agentDiscoveredRunners: [RunnerAgentRunnerRecord] = []
    private(set) var runnerAgentError: String?
    private(set) var isWorkingWithRunnerAgent = false
    private(set) var inFlight: Set<String> = []

    // MARK: - Settings (persisted in UserDefaults)
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let dirs = "runnerDirectories"
        static let poll = "pollInterval"
        static let startMode = "startMode"
        static let ghPath = "ghPath"
        static let runnersBase = "runnersBaseDirectory"
        static let jobClickAction = "jobClickAction"
        static let executionMode = "runnerExecutionMode"
        static let onboardingCompleted = "runnerOnboardingCompleted"
    }
    private var isReady = false

    /// What clicking a recent job does.
    var jobClickAction: JobClickAction = .github {
        didSet {
            guard isReady else { return }
            defaults.set(jobClickAction.rawValue, forKey: Keys.jobClickAction)
        }
    }

    /// Default parent folder for new runners (so they land together with consistent names).
    var runnersBaseDirectoryPath: String = "" {
        didSet {
            guard isReady else { return }
            defaults.set(runnersBaseDirectoryPath, forKey: Keys.runnersBase)
        }
    }
    var runnersBaseDirectory: URL? {
        runnersBaseDirectoryPath.isEmpty ? nil : URL(fileURLWithPath: runnersBaseDirectoryPath)
    }

    var runnerDirectoryPaths: [String] = [] {
        didSet {
            guard isReady else { return }
            defaults.set(runnerDirectoryPaths, forKey: Keys.dirs)
            rebuildRunners()
        }
    }
    var pollInterval: Double = 5 {
        didSet {
            guard isReady else { return }
            defaults.set(pollInterval, forKey: Keys.poll)
            if pollTask != nil { startPolling() }
        }
    }
    var startMode: StartMode = .supervised {
        didSet {
            guard isReady else { return }
            defaults.set(startMode.rawValue, forKey: Keys.startMode)
        }
    }
    var ghPath: String = "gh" {
        didSet {
            guard isReady else { return }
            defaults.set(ghPath, forKey: Keys.ghPath)
        }
    }

    // MARK: - Services
    private var github: GitHubClient { GitHubClient(ghPath: ghPath) }
    private var updater: Updater { Updater(github: github) }
    private let backend: any RunnerExecutionBackend
    private let runnerAgentClient = RunnerAgentClient()

    private var pollTask: Task<Void, Never>?
    private var lastAuthCheck: Date?
    private var lastAgentDiscovery: Date?
    /// When a transient (.starting/.stopping) state should expire and yield to reality.
    private var transientDeadline: [String: Date] = [:]
    /// How long a transient state may persist before the real process state wins.
    private let transientTimeout: TimeInterval = 20

    // MARK: - Lifecycle

    init(backend: any RunnerExecutionBackend = LocalRunnerExecutionBackend()) {
        self.backend = backend
        loadSettings()
        rebuildRunners()
        isReady = true
        startPolling()
    }

    private func loadSettings() {
        if let dirs = defaults.array(forKey: Keys.dirs) as? [String] {
            runnerDirectoryPaths = dirs
        } else {
            // Default: ~/actions-runner if it exists.
            let candidate = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("actions-runner")
            runnerDirectoryPaths = FileManager.default.fileExists(atPath: candidate.path) ? [candidate.path] : []
        }
        if defaults.object(forKey: Keys.poll) != nil {
            pollInterval = max(2, defaults.double(forKey: Keys.poll))
        }
        if let raw = defaults.string(forKey: Keys.startMode), let m = StartMode(rawValue: raw) {
            startMode = m
        }
        if let p = defaults.string(forKey: Keys.ghPath), !p.isEmpty {
            ghPath = p
        }
        if let base = defaults.string(forKey: Keys.runnersBase) {
            runnersBaseDirectoryPath = base
        }
        if let raw = defaults.string(forKey: Keys.jobClickAction), let a = JobClickAction(rawValue: raw) {
            jobClickAction = a
        }
        if let raw = defaults.string(forKey: Keys.executionMode),
           let mode = RunnerExecutionMode(rawValue: raw) {
            executionMode = mode
        }
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
    }

    // MARK: - Recent job → GitHub / local logs

    /// The local `Worker_*.log` for a job, if it can be matched.
    func jobWorkerLog(_ job: JobRecord, in runner: RunnerInstance) -> URL? {
        LogTailer.workerLog(for: job, in: runner.directory)
    }

    /// A GitHub URL for the job: the specific Actions run if the `run_id` can be recovered
    /// from the job's Worker log, otherwise the repository's Actions page.
    func jobGitHubURL(_ job: JobRecord, in runner: RunnerInstance) async -> URL? {
        if let reference = await workflowRunReference(for: job, in: runner) {
            return reference.gitHubURL
        }
        return runner.gitHubURL?.appendingPathComponent("actions")
    }

    /// Cancel the workflow run that owns a currently executing local job.
    func cancelJob(_ job: JobRecord, in runner: RunnerInstance) {
        let key = "cancel-job-\(runner.id)"
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task { [self] in
            defer { inFlight.remove(key) }
            do {
                guard let reference = await workflowRunReference(for: job, in: runner) else {
                    banner = BannerMessage(
                        text: "Could not identify the GitHub workflow run for \(job.name) yet. Wait a moment and try again.",
                        kind: .error
                    )
                    return
                }
                try await github.cancelWorkflowRun(reference)
                banner = BannerMessage(text: "Cancellation requested for \(job.name).", kind: .success)
                try? await Task.sleep(nanoseconds: 800_000_000)
                await refreshAll()
            } catch {
                banner = BannerMessage(
                    text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    kind: .error
                )
            }
        }
    }

    /// Resolve the Worker-log metadata for a job. Repository-scoped runners can
    /// fall back to their configured repository if an older log omitted it.
    private func workflowRunReference(for job: JobRecord,
                                      in runner: RunnerInstance) async -> WorkflowRunReference? {
        let dir = runner.directory
        let fallbackRepository = runner.config?.repoSlug
        return await Task.detached(priority: .utility) {
            guard let workerLog = LogTailer.workerLog(for: job, in: dir) else { return nil }
            if let reference = LogTailer.workflowRunReference(fromWorkerLog: workerLog) {
                return reference
            }
            guard let fallbackRepository,
                  let runID = LogTailer.runID(fromWorkerLog: workerLog) else { return nil }
            return WorkflowRunReference(repository: fallbackRepository, runID: runID)
        }.value
    }

    // MARK: - Runner labels

    /// Fetch a runner's labels (default + custom) from GitHub. Nil on error (banner shown).
    func fetchRunnerLabels(_ instance: RunnerInstance) async -> [RunnerLabel]? {
        guard let cfg = instance.config, let target = GHTarget(scope: cfg.scope) else {
            banner = BannerMessage(text: "This runner isn't bound to a repo/org whose labels can be edited.", kind: .error)
            return nil
        }
        do {
            return try await github.runnerLabels(for: target, runnerID: cfg.agentId)
        } catch {
            banner = BannerMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
            return nil
        }
    }

    /// Replace a runner's custom labels on GitHub. Returns the resulting full set, or nil on error.
    func saveRunnerLabels(_ instance: RunnerInstance, custom: [String]) async -> [RunnerLabel]? {
        guard let cfg = instance.config, let target = GHTarget(scope: cfg.scope) else { return nil }
        do {
            let updated = try await github.setCustomLabels(for: target, runnerID: cfg.agentId, labels: custom)
            banner = BannerMessage(text: "Updated labels for \(instance.displayName).", kind: .success)
            return updated
        } catch {
            banner = BannerMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
            return nil
        }
    }

    var selectedRunner: RunnerInstance? {
        guard let selectedRunnerID else { return runners.first }
        return runners.first { $0.id == selectedRunnerID } ?? runners.first
    }

    func status(for instance: RunnerInstance) -> RunnerLiveStatus {
        statuses[instance.id] ?? .unknown
    }
    func insight(for instance: RunnerInstance) -> RunnerLogInsights? {
        insights[instance.id]
    }
    func isInFlight(_ key: String) -> Bool { inFlight.contains(key) }

    // MARK: - Directory / runner discovery

    private func rebuildRunners() {
        var rebuilt: [RunnerInstance] = []
        for path in runnerDirectoryPaths {
            let dir = URL(fileURLWithPath: path)
            let previous = runners.first { $0.id == dir.standardizedFileURL.path }
            let instance = RunnerInstance(
                directory: dir,
                config: RunnerConfig.load(from: dir),
                installedVersion: previous?.installedVersion
            )
            rebuilt.append(instance)
        }
        runners = rebuilt
        if selectedRunnerID == nil || !runners.contains(where: { $0.id == selectedRunnerID }) {
            selectedRunnerID = runners.first?.id
        }
    }

    func addDirectory(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !runnerDirectoryPaths.contains(path) else {
            banner = BannerMessage(text: "That directory is already added.", kind: .info)
            return
        }
        let instance = RunnerInstance(directory: url)
        guard instance.looksLikeRunnerDirectory else {
            banner = BannerMessage(text: "\(url.lastPathComponent) doesn't look like a runner directory (no run.sh/config.sh).", kind: .error)
            return
        }
        runnerDirectoryPaths.append(path)
        selectedRunnerID = path
        Task { await refreshAll() }
    }

    func removeDirectory(_ instance: RunnerInstance) {
        runnerDirectoryPaths.removeAll { $0 == instance.id }
    }

    // MARK: - Onboarding / discovery

    /// Run the bounded, read-only search used by onboarding and Settings.
    func discoverExistingRunners() async {
        guard !isDiscoveringRunners else { return }
        isDiscoveringRunners = true
        defer { isDiscoveringRunners = false }
        let explicit = runnerDirectoryPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        discoveredRunners = await RunnerDiscovery.discoverDefault(explicitDirectories: explicit)
    }

    func isManagedRunner(_ instance: RunnerInstance) -> Bool {
        runnerDirectoryPaths.contains(instance.id)
    }

    /// Add selected discovery results without dropping any folders already managed.
    func addDiscoveredRunners(withIDs ids: Set<String>) {
        var paths = runnerDirectoryPaths
        var seen = Set(paths)
        for runner in discoveredRunners where ids.contains(runner.id) {
            if seen.insert(runner.id).inserted { paths.append(runner.id) }
        }
        if paths != runnerDirectoryPaths { runnerDirectoryPaths = paths }
    }

    /// Add a manually chosen folder to the pending discovery results without
    /// persisting it before the user finishes onboarding.
    @discardableResult
    func addDiscoveryCandidate(_ url: URL) -> Bool {
        let directory = url.standardizedFileURL
        let instance = RunnerInstance(
            directory: directory,
            config: RunnerConfig.load(from: directory)
        )
        guard instance.looksLikeRunnerDirectory else {
            banner = BannerMessage(
                text: "\(directory.lastPathComponent) doesn't look like a runner directory (no run.sh/config.sh).",
                kind: .error
            )
            return false
        }
        if !discoveredRunners.contains(where: { $0.id == instance.id }) {
            discoveredRunners.append(instance)
            discoveredRunners.sort {
                $0.directory.path.localizedStandardCompare($1.directory.path) == .orderedAscending
            }
        }
        return true
    }

    /// Complete setup only for a backend that is actually available. Selecting
    /// dedicated mode cannot silently fall back to running jobs as the admin user.
    @discardableResult
    func completeOnboarding(selectedRunnerIDs: Set<String>) -> Bool {
        switch executionMode {
        case .currentAccount:
            addDiscoveredRunners(withIDs: selectedRunnerIDs)
        case .dedicatedAccount:
            guard runnerAgentReady else {
                banner = BannerMessage(
                    text: runnerAgentError ?? "Runner Agent must be enabled and healthy before dedicated mode can be selected.",
                    kind: .error
                )
                return false
            }
        }
        onboardingCompleted = true
        defaults.set(true, forKey: Keys.onboardingCompleted)
        Task { await refreshAll() }
        return true
    }

    func reviewOnboarding() {
        onboardingCompleted = false
        defaults.set(false, forKey: Keys.onboardingCompleted)
    }

    // MARK: - Read-only Runner Agent

    var runnerAccountExists: Bool { RunnerAgentManager.runnerAccountExists }
    var runnerAgentHasProductionSigningIdentity: Bool {
        RunnerAgentManager.hasProductionSigningIdentity
    }
    var runnerAgentReady: Bool {
        guard runnerAgentRegistrationState == .enabled,
              let health = runnerAgentHealth else { return false }
        return health.protocolVersion == RunnerAgentConstants.protocolVersion
            && health.accountName == RunnerAgentConstants.accountName
            && health.effectiveUserID != 0
    }

    func refreshRunnerAgent() async {
        runnerAgentRegistrationState = RunnerAgentManager.status
        runnerAgentHealth = nil
        runnerAgentError = nil
        guard runnerAgentRegistrationState == .enabled else { return }
        do {
            let health = try await runnerAgentClient.health()
            guard health.protocolVersion == RunnerAgentConstants.protocolVersion else {
                throw RunnerAgentClientError.incompatibleProtocol(
                    expected: RunnerAgentConstants.protocolVersion,
                    received: health.protocolVersion
                )
            }
            guard health.accountName == RunnerAgentConstants.accountName else {
                throw RunnerAgentClientError.wrongAccount(
                    expected: RunnerAgentConstants.accountName,
                    received: health.accountName
                )
            }
            guard health.effectiveUserID != 0 else { throw RunnerAgentClientError.rootAgent }
            runnerAgentHealth = health
        } catch {
            runnerAgentError = error.localizedDescription
        }
    }

    func registerRunnerAgent() async {
        guard !isWorkingWithRunnerAgent else { return }
        isWorkingWithRunnerAgent = true
        defer { isWorkingWithRunnerAgent = false }
        do {
            try RunnerAgentManager.register()
            await refreshRunnerAgent()
            banner = BannerMessage(
                text: runnerAgentRegistrationState == .requiresApproval
                    ? "Runner Agent registered. Approve it in System Settings › General › Login Items."
                    : "Runner Agent registered.",
                kind: .success
            )
        } catch {
            runnerAgentRegistrationState = RunnerAgentManager.status
            runnerAgentError = error.localizedDescription
            banner = BannerMessage(text: error.localizedDescription, kind: .error)
        }
    }

    func unregisterRunnerAgent() async {
        guard !isWorkingWithRunnerAgent else { return }
        isWorkingWithRunnerAgent = true
        defer { isWorkingWithRunnerAgent = false }
        do {
            try RunnerAgentManager.unregister()
            runnerAgentRegistrationState = RunnerAgentManager.status
            runnerAgentHealth = nil
            agentDiscoveredRunners = []
            banner = BannerMessage(text: "Runner Agent unregistered.", kind: .success)
        } catch {
            runnerAgentError = error.localizedDescription
            banner = BannerMessage(text: error.localizedDescription, kind: .error)
        }
    }

    func openRunnerAgentSystemSettings() {
        RunnerAgentManager.openSystemSettings()
    }

    func discoverDedicatedRunners() async {
        guard runnerAgentReady, !isWorkingWithRunnerAgent else { return }
        isWorkingWithRunnerAgent = true
        defer { isWorkingWithRunnerAgent = false }
        do {
            let records = try await runnerAgentClient.discoverRunners()
            let expectedUserID = runnerAgentHealth?.effectiveUserID
            let expectedHome = runnerAgentHealth?.homeDirectory ?? ""
            let homePrefix = expectedHome.hasSuffix("/") ? expectedHome : expectedHome + "/"
            agentDiscoveredRunners = records.filter { record in
                record.ownerUserID == expectedUserID
                    && !expectedHome.isEmpty
                    && record.directoryPath.hasPrefix(homePrefix)
            }
            lastAgentDiscovery = Date()
            runnerAgentError = nil
        } catch {
            runnerAgentError = error.localizedDescription
        }
    }

    // MARK: - Polling

    func startPolling() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshAll() async {
        if executionMode == .dedicatedAccount {
            await refreshRunnerAgent()
            if runnerAgentReady,
               lastAgentDiscovery == nil
                || Date().timeIntervalSince(lastAgentDiscovery!) > 30 {
                await discoverDedicatedRunners()
            }
            statuses = [:]
            insights = [:]
            lastRefresh = Date()
            return
        }

        // Refresh gh auth at most every 30s.
        if lastAuthCheck == nil || Date().timeIntervalSince(lastAuthCheck!) > 30 {
            ghAuth = await github.authStatus()
            lastAuthCheck = Date()
        }

        let requests = runners.map {
            RunnerObservationRequest(runner: $0, includeVersion: $0.installedVersion == nil)
        }
        let observations: [String: RunnerRuntimeObservation]
        do {
            observations = try await backend.observe(requests)
        } catch {
            let message = "Runner service unavailable: \(error.localizedDescription)"
            statuses = Dictionary(uniqueKeysWithValues: runners.map { instance in
                var status = RunnerLiveStatus()
                status.state = .unknown
                status.lastError = message
                return (instance.id, status)
            })
            insights = [:]
            lastRefresh = Date()
            return
        }
        var newStatuses: [String: RunnerLiveStatus] = [:]
        var newInsights: [String: RunnerLogInsights] = [:]

        for instance in runners {
            let observation = observations[instance.id]

            // Fill in the installed version lazily.
            if instance.installedVersion == nil,
               let version = observation?.installedVersion,
               let idx = runners.firstIndex(where: { $0.id == instance.id }) {
                runners[idx].installedVersion = version
            }

            var status = RunnerLiveStatus()
            status.serviceInstalled = observation?.serviceInstalled ?? false

            guard instance.isConfigured else {
                status.state = .notConfigured
                newStatuses[instance.id] = preserveTransient(status, id: instance.id)
                continue
            }

            let logInsights = observation?.insights
                ?? RunnerLogInsights(currentJob: nil, history: [], lastLine: nil)
            newInsights[instance.id] = logInsights

            if let proc = observation?.process {
                status.state = .running
                status.pid = proc.pid
                status.cpuPercent = proc.cpuPercent
                status.memoryMB = proc.memoryMB
                status.uptime = Self.humanUptime(proc.etime)
                status.busy = (observation?.busy ?? false) || (logInsights.currentJob != nil)
                status.currentJob = status.busy ? logInsights.currentJob : nil
            } else {
                status.state = .stopped
            }
            newStatuses[instance.id] = preserveTransient(status, id: instance.id)
        }

        statuses = newStatuses
        insights = newInsights
        lastRefresh = Date()
    }

    /// Keep a transient starting/stopping state visible until the process actually
    /// appears/disappears — but never longer than `transientTimeout`, so a start
    /// that silently fails can't pin the UI in ".starting" forever.
    private func preserveTransient(_ computed: RunnerLiveStatus, id: String) -> RunnerLiveStatus {
        guard let prev = statuses[id] else { return computed }
        // Expire a stale transient and let the real state through.
        if let deadline = transientDeadline[id], Date() > deadline {
            transientDeadline[id] = nil
            return computed
        }
        if prev.state == .starting && computed.state != .running {
            var s = computed; s.state = .starting; return s
        }
        if prev.state == .stopping && computed.state == .running {
            var s = computed; s.state = .stopping; return s
        }
        // Reached a settled state — drop the deadline.
        if computed.state == .running || computed.state == .stopped {
            transientDeadline[id] = nil
        }
        return computed
    }

    // MARK: - Actions

    func start(_ instance: RunnerInstance) {
        perform(key: "start-\(instance.id)", resetTransient: instance.id) { [self] in
            setTransient(instance.id, .starting)
            try await backend.start(instance, mode: startMode)
            banner = BannerMessage(text: "Starting \(instance.displayName)…", kind: .info)
        }
    }

    func stop(_ instance: RunnerInstance, force: Bool = false) {
        perform(key: "stop-\(instance.id)", resetTransient: instance.id) { [self] in
            setTransient(instance.id, .stopping)
            let pid = statuses[instance.id]?.pid
            try await backend.stop(instance, pid: pid, force: force)
            banner = BannerMessage(text: "Stopping \(instance.displayName)…", kind: .info)
        }
    }

    // MARK: - Aggregates (overview / dashboard)

    /// Runners currently executing a job.
    var busyCount: Int { runners.filter { statuses[$0.id]?.busy == true }.count }
    /// Summed CPU% across all runner processes.
    var totalCPU: Double { runners.compactMap { statuses[$0.id]?.cpuPercent }.reduce(0, +) }
    /// Summed resident memory (MB) across all runner processes.
    var totalMemoryMB: Double { runners.compactMap { statuses[$0.id]?.memoryMB }.reduce(0, +) }

    // MARK: - Batch actions

    /// Configured runners that are not currently running.
    var startableRunners: [RunnerInstance] {
        guard executionMode == .currentAccount else { return [] }
        return runners.filter { $0.isConfigured && !(statuses[$0.id]?.isRunning ?? false) }
    }
    /// Runners with a live process.
    var runningRunners: [RunnerInstance] {
        guard executionMode == .currentAccount else { return [] }
        return runners.filter { statuses[$0.id]?.isRunning ?? false }
    }

    func startAll() {
        let targets = startableRunners
        for r in targets { start(r) }
        if !targets.isEmpty {
            banner = BannerMessage(text: "Starting \(targets.count) runner\(targets.count == 1 ? "" : "s")…", kind: .info)
        }
    }

    func stopAll(force: Bool = false) {
        let targets = runningRunners
        for r in targets { stop(r, force: force) }
        if !targets.isEmpty {
            banner = BannerMessage(text: "Stopping \(targets.count) runner\(targets.count == 1 ? "" : "s")…", kind: .info)
        }
    }

    /// Check every configured runner and apply verified updates to idle ones.
    func updateAll() async {
        guard allowLocalRunnerMutation() else { return }
        let key = "update-all"
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key); defer { inFlight.remove(key) }
        var updated = 0, upToDate = 0, skipped = 0, failed = 0
        for r in runners where r.isConfigured {
            guard let info = try? await updater.checkForUpdate(r) else { failed += 1; continue }
            if !info.updateAvailable { upToDate += 1; continue }
            if statuses[r.id]?.busy == true { skipped += 1; continue }
            if !info.hasVerifiableHash { skipped += 1; continue }
            let ok = await applyUpdate(r, info: info, progress: { _ in })
            if ok { updated += 1 } else { failed += 1 }
        }
        var parts = ["\(updated) updated", "\(upToDate) up to date"]
        if skipped > 0 { parts.append("\(skipped) skipped (busy/unverifiable)") }
        if failed > 0 { parts.append("\(failed) failed") }
        banner = BannerMessage(text: "Update all — " + parts.joined(separator: ", ") + ".",
                               kind: failed > 0 ? .error : .success)
    }

    func installService(_ instance: RunnerInstance) {
        perform(key: "svc-install-\(instance.id)", resetTransient: instance.id) { [self] in
            setTransient(instance.id, .starting)
            try await backend.installService(instance)
            banner = BannerMessage(text: "Installed & started launchd service for \(instance.displayName).", kind: .success)
        }
    }

    func installServiceOnly(_ instance: RunnerInstance) {
        perform(key: "svc-install-\(instance.id)") { [self] in
            try await backend.installServiceOnly(instance)
            banner = BannerMessage(text: "Installed launchd service for \(instance.displayName) (not started).", kind: .success)
        }
    }

    func startService(_ instance: RunnerInstance) {
        perform(key: "svc-start-\(instance.id)", resetTransient: instance.id) { [self] in
            setTransient(instance.id, .starting)
            try await backend.startService(instance)
            banner = BannerMessage(text: "Started service for \(instance.displayName).", kind: .info)
        }
    }

    func stopService(_ instance: RunnerInstance) {
        perform(key: "svc-stop-\(instance.id)", resetTransient: instance.id) { [self] in
            setTransient(instance.id, .stopping)
            try await backend.stopService(instance)
            banner = BannerMessage(text: "Stopped service for \(instance.displayName).", kind: .info)
        }
    }

    func uninstallService(_ instance: RunnerInstance) {
        perform(key: "svc-uninstall-\(instance.id)") { [self] in
            try await backend.uninstallService(instance)
            banner = BannerMessage(text: "Removed launchd service for \(instance.displayName).", kind: .success)
        }
    }

    /// Run `svc.sh status` and surface the output.
    func showServiceStatus(_ instance: RunnerInstance) async {
        guard allowLocalRunnerMutation() else { return }
        do {
            let status = try await backend.serviceStatus(instance)
            banner = BannerMessage(text: status, kind: .info)
        } catch {
            banner = BannerMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
        }
    }

    /// The launchd log directory for a runner's service, if installed.
    func serviceLogDirectory(_ instance: RunnerInstance) -> URL? {
        guard executionMode == .currentAccount else { return nil }
        return backend.serviceLogDirectory(for: instance)
    }

    /// Register an existing runner directory against a GitHub target. Returns success.
    ///
    /// A runner folder can only serve one repo. If `directory` is ALREADY configured,
    /// registering it again means MOVING it (removing it from its current repo) — that
    /// requires the explicit `reconfigure` opt-in, since it's destructive and is the
    /// wrong choice for "add a second repo" (use `createAndRegister` with a new folder).
    func registerExisting(directory: URL, target: GHTarget, name: String, labels: [String],
                          options: RegisterOptions = RegisterOptions(),
                          reconfigure: Bool = false) async -> Bool {
        guard allowLocalRunnerMutation() else { return false }
        let key = "register-\(directory.path)"
        guard !inFlight.contains(key) else { return false }
        inFlight.insert(key); defer { inFlight.remove(key) }
        do {
            let existingConfig = RunnerConfig.load(from: directory)
            let instance = RunnerInstance(directory: directory, config: existingConfig)

            // Already configured: block unless the user explicitly opted to reconfigure.
            if let existingConfig, !reconfigure {
                let old = existingConfig.scope.displayString
                banner = BannerMessage(
                    text: "This folder already runs a runner for \(old). One folder serves one repo — to add a runner for \(target.displayString) while keeping this one, use “New runner” (a separate folder). To move this runner instead, choose Reconfigure.",
                    kind: .error)
                return false
            }

            if statuses[instance.id]?.isRunning == true {
                try await backend.stop(instance, pid: statuses[instance.id]?.pid, force: false)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            // Reconfiguring: remove the current registration first (config.sh refuses to
            // configure an already-configured folder). Prefer a clean server-side removal;
            // fall back to local-only removal if we lack admin on the old repo.
            if let existingConfig, reconfigure {
                if let oldTarget = GHTarget(scope: existingConfig.scope) {
                    do {
                        let removeToken = try await github.createRemoveToken(for: oldTarget)
                        try await backend.unregister(instance, token: removeToken.token)
                    } catch {
                        try await backend.removeLocalConfig(directory)
                    }
                } else {
                    try await backend.removeLocalConfig(directory)
                }
            }

            let token = try await github.createRegistrationToken(for: target)
            let request = RegistrationRequest(directory: directory, target: target, name: name,
                                              labels: labels, token: token.token, replace: true,
                                              runnerGroup: options.runnerGroup,
                                              disableUpdate: options.disableUpdate,
                                              ephemeral: options.ephemeral,
                                              noDefaultLabels: options.noDefaultLabels)
            try await backend.register(request)
            if !runnerDirectoryPaths.contains(directory.standardizedFileURL.path) {
                runnerDirectoryPaths.append(directory.standardizedFileURL.path)
            } else {
                rebuildRunners()
            }
            selectedRunnerID = directory.standardizedFileURL.path
            banner = BannerMessage(text: "Registered runner \(name) on \(target.displayString).", kind: .success)
            await refreshAll()
            return true
        } catch {
            banner = BannerMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
            return false
        }
    }

    /// Download the latest runner package into a new directory and register it. Returns success.
    func createAndRegister(parent: URL, folderName: String, target: GHTarget,
                           name: String, labels: [String],
                           options: RegisterOptions = RegisterOptions(),
                           addToGitignore: Bool = false,
                           progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        guard allowLocalRunnerMutation() else { return false }
        let key = "create-\(folderName)"
        guard !inFlight.contains(key) else { return false }
        inFlight.insert(key); defer { inFlight.remove(key) }
        do {
            let newDir = parent.appendingPathComponent(folderName)
            // Refuse to clobber an already-configured runner in the target folder.
            if RunnerConfig.load(from: newDir) != nil {
                banner = BannerMessage(
                    text: "“\(folderName)” already contains a configured runner. Choose a different folder name.",
                    kind: .error)
                return false
            }
            if FileManager.default.fileExists(atPath: newDir.appendingPathComponent("config.sh").path) == false {
                try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            }
            if addToGitignore {
                Self.addGitignoreEntry(folder: folderName, inParent: parent)
            }
            // Reuse the updater's verified download of the latest release.
            let placeholder = RunnerInstance(directory: newDir)
            let info = try await updater.checkForUpdate(placeholder)
            let pkg = try await updater.downloadVerifiedPackage(info, progress: progress)
            try await updater.extractPackage(at: pkg, into: newDir)
            let token = try await github.createRegistrationToken(for: target)
            let request = RegistrationRequest(directory: newDir, target: target, name: name,
                                              labels: labels, token: token.token, replace: true,
                                              runnerGroup: options.runnerGroup,
                                              disableUpdate: options.disableUpdate,
                                              ephemeral: options.ephemeral,
                                              noDefaultLabels: options.noDefaultLabels)
            try await backend.register(request)
            runnerDirectoryPaths.append(newDir.standardizedFileURL.path)
            selectedRunnerID = newDir.standardizedFileURL.path
            banner = BannerMessage(text: "Created and registered \(name) on \(target.displayString).", kind: .success)
            await refreshAll()
            return true
        } catch {
            banner = BannerMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
            return false
        }
    }

    /// Append `<folder>/` to `<parent>/.gitignore`, creating the file and avoiding duplicates.
    /// Handy when the runner lives inside a repo checkout and shouldn't be committed.
    static func addGitignoreEntry(folder: String, inParent parent: URL) {
        let gitignore = parent.appendingPathComponent(".gitignore")
        let entry = "\(folder)/"
        var contents = (try? String(contentsOf: gitignore, encoding: .utf8)) ?? ""
        let existing = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if existing.contains(entry) || existing.contains(folder) { return }
        if contents.isEmpty {
            contents = "# Added by Runner Menu\n\(entry)\n"
        } else {
            if !contents.hasSuffix("\n") { contents += "\n" }
            contents += "\(entry)\n"
        }
        try? contents.write(to: gitignore, atomically: true, encoding: .utf8)
    }

    /// Unregister a runner from GitHub (keeps the directory).
    func unregister(_ instance: RunnerInstance) {
        guard let scope = instance.config?.scope, let target = GHTarget(scope: scope) else {
            banner = BannerMessage(text: "This runner isn't bound to a repo/org that supports removal via API.", kind: .error)
            return
        }
        perform(key: "unregister-\(instance.id)") { [self] in
            if statuses[instance.id]?.isRunning == true {
                try await backend.stop(instance, pid: statuses[instance.id]?.pid, force: false)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            let token = try await github.createRemoveToken(for: target)
            try await backend.unregister(instance, token: token.token)
            rebuildRunners()
            banner = BannerMessage(text: "Unregistered \(instance.displayName).", kind: .success)
        }
    }

    // MARK: - Repos (for the register sheet)

    /// Force a fresh `gh auth status` check (used by Settings).
    func forceAuthRecheck() async {
        lastAuthCheck = nil
        ghAuth = await github.authStatus()
        lastAuthCheck = Date()
    }

    func loadAdminRepos() {
        guard !isLoadingRepos else { return }
        isLoadingRepos = true
        Task { [self] in
            defer { isLoadingRepos = false }
            do {
                adminRepos = try await github.adminRepos()
            } catch {
                banner = BannerMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
            }
        }
    }

    // MARK: - Updates

    func checkForUpdate(_ instance: RunnerInstance) async -> UpdateInfo? {
        do {
            return try await updater.checkForUpdate(instance)
        } catch {
            banner = BannerMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
            return nil
        }
    }

    func applyUpdate(_ instance: RunnerInstance, info: UpdateInfo,
                     allowUnverified: Bool = false,
                     progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        guard allowLocalRunnerMutation() else { return false }
        // Refuse to update mid-job.
        if statuses[instance.id]?.busy == true {
            banner = BannerMessage(text: UpdateError.runnerBusy.errorDescription ?? "Runner busy", kind: .error)
            return false
        }
        do {
            let pkg = try await updater.downloadVerifiedPackage(info, allowUnverified: allowUnverified, progress: progress)

            // The download takes tens of seconds; a job may have started meanwhile.
            // Re-check with a FRESH scan (not the polled cache) before anything destructive.
            let freshScan = await backend.freshProcessScan()
            if freshScan.isBusy(instance.directory) {
                try? FileManager.default.removeItem(at: pkg)
                banner = BannerMessage(text: UpdateError.runnerBusy.errorDescription ?? "Runner busy", kind: .error)
                return false
            }
            let wasRunning = freshScan.listener(for: instance.directory) != nil

            if wasRunning {
                setTransient(instance.id, .stopping)
                try await backend.stop(
                    instance,
                    pid: freshScan.listener(for: instance.directory)?.pid,
                    force: false
                )
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            try await updater.extractPackage(at: pkg, into: instance.directory)
            // Refresh the recorded version.
            if let idx = runners.firstIndex(where: { $0.id == instance.id }) {
                runners[idx].installedVersion = await backend.installedVersion(for: instance)
            }
            if wasRunning {
                setTransient(instance.id, .starting)
                try await backend.start(instance, mode: startMode)
            }
            banner = BannerMessage(text: "Updated \(instance.displayName) to \(info.latestVersion).", kind: .success)
            await refreshAll()
            return true
        } catch {
            banner = BannerMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
            return false
        }
    }

    // MARK: - Helpers

    private func setTransient(_ id: String, _ state: RunnerLiveStatus.State) {
        var s = statuses[id] ?? RunnerLiveStatus()
        s.state = state
        statuses[id] = s
        transientDeadline[id] = Date().addingTimeInterval(transientTimeout)
    }

    /// Run an async action, tracking in-flight state and surfacing errors as banners.
    /// On failure, `resetTransient` clears any optimistic transient for that runner
    /// so a failed start/stop doesn't leave the UI stuck.
    private func perform(key: String, resetTransient id: String? = nil,
                         _ work: @escaping () async throws -> Void) {
        guard allowLocalRunnerMutation() else { return }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task { [self] in
            defer { inFlight.remove(key) }
            do {
                try await work()
            } catch {
                banner = BannerMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
                // Force the optimistic transient to expire on the next refresh so a
                // failed start/stop reverts to the real state instead of sticking.
                if let id { transientDeadline[id] = .distantPast }
            }
            // Give the process a moment, then refresh.
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refreshAll()
        }
    }

    /// Phase 2 dedicated mode is intentionally read-only. No code path may
    /// silently fall back to executing a local controller operation as the admin.
    @discardableResult
    private func allowLocalRunnerMutation() -> Bool {
        guard executionMode == .currentAccount else {
            banner = BannerMessage(
                text: "Dedicated-account mode is read-only until Runner Agent lifecycle control is implemented.",
                kind: .error
            )
            return false
        }
        return true
    }

    /// Convert `ps` etime ("15:28", "01:02:03", "1-02:03:04") to "15m", "1h 2m", "1d 2h".
    static func humanUptime(_ etime: String) -> String {
        var days = 0
        var rest = etime
        if let dashRange = etime.range(of: "-") {
            days = Int(etime[etime.startIndex..<dashRange.lowerBound]) ?? 0
            rest = String(etime[dashRange.upperBound...])
        }
        let parts = rest.split(separator: ":").map { Int($0) ?? 0 }
        var hours = 0, minutes = 0
        switch parts.count {
        case 3: hours = parts[0]; minutes = parts[1]
        case 2: minutes = parts[0]
        default: break
        }
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "just now"
    }
}
