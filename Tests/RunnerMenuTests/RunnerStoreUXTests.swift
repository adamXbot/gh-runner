import Foundation
import Testing
@testable import RunnerMenu

@MainActor
struct RunnerStoreUXTests {
    @Test func registrationDraftSurvivesNavigationAndRequiresExplicitDiscard() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let draft = store.registrationDraft
        draft.manualTarget = "example/private-repo"
        draft.runnerName = "my-edited-name"
        draft.labels = "custom"
        draft.operationIssue = RegistrationIssue(message: "Could not register", recovery: "Your folder was kept")
        store.selectedRunnerID = nil
        #expect(store.registrationDraft === draft)
        #expect(store.registrationDraft.runnerName == "my-edited-name")
        draft.isWorking = true
        store.discardRegistrationDraft()
        #expect(store.registrationDraft === draft)
        draft.isWorking = false
        store.discardRegistrationDraft()
        #expect(store.registrationDraft !== draft)
        #expect(store.registrationDraft.manualTarget.isEmpty)
    }

    @Test func startBlocksStopAndServiceChangesUntilTheProcessSettles() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let backend = UXBackend()
        await backend.holdStart()
        let store = fixture.store(backend: backend)
        let runner = fixture.runner
        store.start(runner)
        await backend.waitForStart()
        #expect(store.runnerOperations.contains(runner.id))
        #expect(!store.canStart(runner))
        #expect(!store.canStop(runner))
        store.stop(runner)
        store.installServiceOnly(runner)
        #expect(await backend.stops == 0)
        #expect(await backend.serviceInstalls == 0)
        await backend.finishStart()
        try await waitUntil { !store.runnerOperations.contains(runner.id) }
        // No listener was observed: optimistic Starting still prevents a conflicting action.
        #expect(store.status(for: runner).state == .starting)
        #expect(!store.canStop(runner))
        await backend.setRunning(runner)
        await store.refreshAll()
        #expect(store.canStop(runner))
    }

    @Test func foreignAndDedicatedRunnersAreExcludedFromLifecycleAndBatchActions() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let backend = UXBackend()
        let store = fixture.store(backend: backend)
        let foreign = RunnerInstance(directory: URL(fileURLWithPath: "/usr"), config: fixture.runner.config)
        #expect(!foreign.isOwnedByCurrentUser)
        store.runners = [foreign]
        #expect(store.startableRunners.isEmpty)
        #expect(store.mutationUnavailableReason(for: foreign) != nil)
        store.start(foreign)
        store.installServiceOnly(foreign)
        #expect(await backend.starts == 0)
        #expect(await backend.serviceInstalls == 0)
        store.executionMode = .dedicatedAccount
        #expect(!store.canStart(fixture.runner))
        #expect(store.updateUnavailableReason(for: fixture.runner) != nil)
    }

    @Test func updateOwnsProgressAndRejectsRepeatedActivationAcrossViews() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let backend = UXBackend()
        let updater = UXUpdater()
        let store = fixture.store(backend: backend, updater: updater)
        let runner = fixture.runner
        let update = Task { await store.applyUpdate(runner, info: Self.updateInfo, progress: { _ in }) }
        await updater.waitForDownload()
        #expect(store.updatePhases[runner.id] == .downloading(0))
        #expect(!store.canStart(runner))
        let duplicate = await store.applyUpdate(runner, info: Self.updateInfo, progress: { _ in })
        #expect(!duplicate)
        store.start(runner)
        store.uninstallService(runner)
        #expect(await backend.starts == 0)
        await updater.finishDownload()
        await updater.waitForExtraction()
        #expect(store.updatePhases[runner.id] == .installing)
        #expect(store.runnerOperations.contains(runner.id))
        await updater.finishExtraction()
        #expect(await update.value)
        #expect(store.updatePhases[runner.id] == nil)
        #expect(!store.runnerOperations.contains(runner.id))
        #expect(await updater.downloads == 1)
    }

    @Test func updateRejectsAJobThatStartsDuringDownloadAndReleasesTheLock() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let backend = UXBackend()
        let updater = UXUpdater()
        let store = fixture.store(backend: backend, updater: updater)
        let update = Task { await store.applyUpdate(fixture.runner, info: Self.updateInfo, progress: { _ in }) }
        await updater.waitForDownload()
        await backend.setBusy(fixture.runner)
        await updater.finishDownload()
        #expect(await update.value == false)
        #expect(await updater.extractions == 0)
        #expect(await backend.stops == 0)
        #expect(store.updatePhases.isEmpty)
        #expect(store.runnerOperations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: updater.package.path))
    }

    @Test func busyRunnerCannotBeginDownloading() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let updater = UXUpdater()
        let store = fixture.store(updater: updater)
        var status = RunnerLiveStatus()
        status.state = .running
        status.busy = true
        store.statuses[fixture.runner.id] = status
        #expect(store.updateUnavailableReason(for: fixture.runner)?.contains("job") == true)
        #expect(await store.applyUpdate(fixture.runner, info: Self.updateInfo, progress: { _ in }) == false)
        #expect(await updater.downloads == 0)
    }

    @Test func reconfigurationReportsAndPersistsUnconfirmedRemoteCleanup() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let backend = UXBackend()
        await backend.failUnregister()
        let store = fixture.store(backend: backend)
        let success = await store.registerExisting(
            directory: fixture.directory, target: .repo(owner: "example", name: "new-private-repo"),
            name: "moved-runner", labels: [], reconfigure: true
        )
        #expect(success)
        let notice = try #require(store.cleanupNotices[fixture.runner.id])
        #expect(notice.runnerName == "fixture-runner")
        #expect(notice.settingsURL?.absoluteString == "https://github.com/example/old-private-repo/settings/actions/runners")
        #expect(store.banner?.kind == .warning)
        #expect(store.banner?.text.contains("could not be confirmed") == true)
        let reopened = fixture.store()
        #expect(reopened.cleanupNotices[fixture.runner.id] == notice)
        reopened.dismissCleanupNotice(for: fixture.runner)
        #expect(fixture.store().cleanupNotices.isEmpty)
    }

    @Test func discoveryFailureIsVisibleDuringSetupAndClearedByCorrection() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        #expect(!store.addDiscoveryCandidate(fixture.directory.appendingPathComponent("missing")))
        #expect(store.discoveryIssue != nil)
        #expect(store.banner == nil)
        #expect(store.addDiscoveryCandidate(fixture.directory))
        #expect(store.discoveryIssue == nil)
        #expect(store.completeOnboarding(selectedRunnerIDs: []))
        #expect(store.discoveryIssue == nil)
    }

    @Test func simultaneousRefreshRequestsShareOneObservation() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let backend = UXBackend()
        await backend.holdObservation()
        let store = fixture.store(backend: backend)
        let first = Task { await store.refreshAll() }
        await backend.waitForObservation()
        var secondFinished = false
        let second = Task { await store.refreshAll(); secondFinished = true }
        await Task.yield()
        #expect(!secondFinished)
        #expect(await backend.observations == 1)
        await backend.finishObservation()
        await first.value
        await second.value
        await store.refreshAll()
        #expect(await backend.observations == 2)
    }

    @Test func pollIntervalSanitizesAndPersistsInvalidInputs() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        for (value, expected) in [(0.0, 2.0), (-10.0, 2.0), (1000.0, 30.0), (Double.nan, 5.0), (Double.infinity, 5.0), (-Double.infinity, 5.0)] {
            store.pollInterval = value
            #expect(store.pollInterval == expected)
            #expect(fixture.defaults.double(forKey: "pollInterval") == expected)
            #expect(fixture.store().pollInterval == expected)
        }
    }

    @Test func failedVersionReadsBackOffAndSuccessfulVersionsStayCached() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let backend = UXBackend()
        await backend.reportNoVersion()
        var time = Date(timeIntervalSince1970: 1000)
        let store = fixture.store(backend: backend, refreshClock: { time })
        await store.refreshAll()
        await store.refreshAll()
        #expect(await backend.versionRequests == [true, false])
        time = time.addingTimeInterval(61)
        await backend.reportVersion()
        await store.refreshAll()
        await store.refreshAll()
        #expect(await backend.versionRequests == [true, false, true, false])
        #expect(store.runners.first?.installedVersion == "3.0.0")
    }

    @Test func cancelledObservationDoesNotPublishAStaleSnapshot() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let backend = UXBackend()
        await backend.setRunning(fixture.runner)
        await backend.holdObservation()
        let store = fixture.store(backend: backend)
        let refresh = Task { await store.refreshAll() }
        await backend.waitForObservation()
        refresh.cancel()
        await backend.finishObservation()
        await refresh.value
        #expect(store.statuses.isEmpty)
        #expect(store.lastRefresh == nil)
        await store.refreshAll()
        #expect(store.status(for: fixture.runner).state == .running)
    }

    @Test func pollingDoesNotRetainTheStoreAcrossSleeps() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let backend = UXBackend()
        var store: RunnerStore? = fixture.store(backend: backend, pollingEnabled: true)
        let isStoreReleased = { [weak store] in store == nil }
        await backend.waitForObservation()
        store = nil
        try await waitUntil(isStoreReleased)
        #expect(isStoreReleased())
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(predicate())
    }

    static var updateInfo: UpdateInfo {
        let asset = GHRelease.Asset(name: "runner.tar.gz", browserDownloadUrl: "https://example.com/runner.tar.gz", size: 10)
        return UpdateInfo(currentVersion: "2.0.0", latest: GHRelease(tagName: "v3.0.0", name: nil, body: nil,
                         htmlUrl: "https://example.com/release", publishedAt: nil, assets: [asset]),
                          asset: asset, expectedSHA256: "test-hash", updateAvailable: true)
    }
}

@MainActor
private struct StoreFixture {
    let directory: URL
    let runner: RunnerInstance
    let defaults: UserDefaults
    let suite: String
    let gh: URL

    init() throws {
        suite = "runner-store-ux-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["run.sh", "config.sh"] { try Data().write(to: directory.appendingPathComponent(name)) }
        let config = RunnerConfig(agentId: 1, agentName: "fixture-runner", gitHubUrl: "https://github.com/example/old-private-repo")
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent(".runner"))
        runner = RunnerInstance(directory: directory, config: config)
        gh = directory.appendingPathComponent("gh-fixture")
        // Every API call is local. No live GitHub runner or token is used.
        try """
        #!/bin/sh
        case "$*" in
          *registration-token*|*remove-token*) printf '{"token":"fixture-token","expires_at":"2099-01-01T00:00:00Z"}' ;;
          *runners*) exit 0 ;;
          *api*) printf 'true' ;;
          *) exit 1 ;;
        esac
        """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        defaults.set([directory.path], forKey: "runnerDirectories")
        defaults.set(gh.path, forKey: "ghPath")
    }

    func store(backend: any RunnerExecutionBackend = UXBackend(), updater: (any RunnerUpdating)? = nil,
               pollingEnabled: Bool = false, refreshClock: @escaping () -> Date = { Date() }) -> RunnerStore {
        RunnerStore(backend: backend, defaults: defaults, updater: updater,
                    pollingEnabled: pollingEnabled, refreshClock: refreshClock)
    }
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor UXBackend: RunnerExecutionBackend {
    var starts = 0, stops = 0, serviceInstalls = 0, observations = 0
    private var observationGate: CheckedContinuation<Void, Never>?
    private var holdingObservation = false
    var versionRequests: [Bool] = []
    private var hasVersion = true
    func reportNoVersion() { hasVersion = false }
    func reportVersion() { hasVersion = true }
    private var startGate: CheckedContinuation<Void, Never>?
    private var hold = false
    private var unregisterFails = false
    private var scan = ProcessScan()

    func holdObservation() { holdingObservation = true }
    func waitForObservation() async { while observations == 0 { await Task.yield() } }
    func finishObservation() {
        holdingObservation = false
        observationGate?.resume()
        observationGate = nil
    }
    func holdStart() { hold = true }
    func waitForStart() async { while starts == 0 { await Task.yield() } }
    func finishStart() { hold = false; startGate?.resume(); startGate = nil }
    func setRunning(_ runner: RunnerInstance) {
        scan.listeners[ProcessMonitor.normalize(runner.directory.path)] = ProcInfo(pid: 123, cpuPercent: 0, memoryMB: 0, etime: "00:01")
    }
    func setBusy(_ runner: RunnerInstance) { scan.busyDirectories.insert(ProcessMonitor.normalize(runner.directory.path)) }
    func failUnregister() { unregisterFails = true }
    func observe(_ requests: [RunnerObservationRequest]) async throws -> [String: RunnerRuntimeObservation] {
        observations += 1
        versionRequests.append(contentsOf: requests.map(\.includeVersion))
        if holdingObservation { await withCheckedContinuation { observationGate = $0 } }
        return Dictionary(uniqueKeysWithValues: requests.map {
            ($0.runner.id, RunnerRuntimeObservation(installedVersion: hasVersion && $0.includeVersion ? "3.0.0" : nil, process: scan.listener(for: $0.runner.directory),
                busy: scan.isBusy($0.runner.directory), insights: nil, serviceInstalled: false))
        })
    }
    func installedVersion(for runner: RunnerInstance) async -> String? { "3.0.0" }
    func freshProcessScan() async -> ProcessScan { scan }
    func start(_ runner: RunnerInstance, mode: StartMode) async throws {
        starts += 1
        if hold { await withCheckedContinuation { startGate = $0 } }
    }
    func stop(_ runner: RunnerInstance, pid: Int32?, force: Bool) async throws { stops += 1 }
    func register(_ request: RegistrationRequest) async throws {
        let config = RunnerConfig(agentId: 2, agentName: request.name, gitHubUrl: request.target.webURLString)
        try JSONEncoder().encode(config).write(to: request.directory.appendingPathComponent(".runner"))
    }
    func unregister(_ runner: RunnerInstance, token: String) async throws {
        if unregisterFails { throw UpdateError.downloadFailed("fixture removal failure") }
        try await removeLocalConfig(runner.directory)
    }
    func removeLocalConfig(_ directory: URL) async throws { try FileManager.default.removeItem(at: directory.appendingPathComponent(".runner")) }
    func installService(_ runner: RunnerInstance) async throws { serviceInstalls += 1 }
    func installServiceOnly(_ runner: RunnerInstance) async throws { serviceInstalls += 1 }
    func startService(_ runner: RunnerInstance) async throws {}
    func stopService(_ runner: RunnerInstance) async throws {}
    func uninstallService(_ runner: RunnerInstance) async throws {}
    func serviceStatus(_ runner: RunnerInstance) async throws -> String { "fixture" }
    nonisolated func serviceLogDirectory(for runner: RunnerInstance) -> URL? { nil }
}

private actor UXUpdater: RunnerUpdating {
    nonisolated let package = FileManager.default.temporaryDirectory.appendingPathComponent("ux-package-\(UUID().uuidString)")
    var downloads = 0, extractions = 0
    private var downloadGate: CheckedContinuation<Void, Never>?
    private var extractionGate: CheckedContinuation<Void, Never>?
    func checkForUpdate(_ instance: RunnerInstance) async throws -> UpdateInfo { await RunnerStoreUXTests.updateInfo }
    func waitForDownload() async { while downloads == 0 { await Task.yield() } }
    func waitForExtraction() async { while extractions == 0 { await Task.yield() } }
    func finishDownload() { downloadGate?.resume(); downloadGate = nil }
    func finishExtraction() { extractionGate?.resume(); extractionGate = nil }
    func downloadVerifiedPackage(_ info: UpdateInfo, allowUnverified: Bool, progress: @escaping @Sendable (Double) -> Void,
                                 onVerification: @escaping @Sendable () -> Void) async throws -> URL {
        downloads += 1
        try Data().write(to: package)
        await withCheckedContinuation { downloadGate = $0 }
        progress(1)
        onVerification()
        return package
    }
    func extractPackage(at package: URL, into directory: URL) async throws {
        extractions += 1
        await withCheckedContinuation { extractionGate = $0 }
    }
}
