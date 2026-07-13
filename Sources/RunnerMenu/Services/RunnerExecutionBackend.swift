import Foundation

/// One runner requested during a batched runtime refresh.
struct RunnerObservationRequest: Sendable {
    var runner: RunnerInstance
    /// Versions change rarely, so the store asks only until it obtains one.
    var includeVersion: Bool
}

/// Runtime data obtained from the account that owns and executes a runner.
struct RunnerRuntimeObservation: Equatable, Sendable {
    var installedVersion: String?
    var process: ProcInfo?
    var busy: Bool
    var insights: RunnerLogInsights?
    var serviceInstalled: Bool
}

/// Security boundary between the menu UI and the account that executes jobs.
///
/// The local implementation preserves today's same-user behavior. The cross-user
/// implementation will send these semantic operations to the signed Runner Agent;
/// it must not grow an arbitrary-command or arbitrary-file API.
protocol RunnerExecutionBackend: Sendable {
    func observe(_ requests: [RunnerObservationRequest]) async throws -> [String: RunnerRuntimeObservation]
    func installedVersion(for runner: RunnerInstance) async -> String?
    func freshProcessScan() async -> ProcessScan

    func start(_ runner: RunnerInstance, mode: StartMode) async throws
    func stop(_ runner: RunnerInstance, pid: Int32?, force: Bool) async throws

    func register(_ request: RegistrationRequest) async throws
    func unregister(_ runner: RunnerInstance, token: String) async throws
    func removeLocalConfig(_ directory: URL) async throws

    func installService(_ runner: RunnerInstance) async throws
    func installServiceOnly(_ runner: RunnerInstance) async throws
    func startService(_ runner: RunnerInstance) async throws
    func stopService(_ runner: RunnerInstance) async throws
    func uninstallService(_ runner: RunnerInstance) async throws
    func serviceStatus(_ runner: RunnerInstance) async throws -> String
    func serviceLogDirectory(for runner: RunnerInstance) -> URL?
}

/// Direct, same-user backend used until the cross-user Runner Agent is active.
struct LocalRunnerExecutionBackend: RunnerExecutionBackend {
    private let controller: RunnerController

    init(controller: RunnerController = RunnerController()) {
        self.controller = controller
    }

    func observe(_ requests: [RunnerObservationRequest]) async throws -> [String: RunnerRuntimeObservation] {
        let scan = await ProcessMonitor.scan()
        var result: [String: RunnerRuntimeObservation] = [:]

        for request in requests {
            let runner = request.runner
            let insights = runner.isConfigured ? LogTailer.insights(for: runner.directory) : nil
            let version = request.includeVersion ? await installedVersion(for: runner) : nil
            result[runner.id] = RunnerRuntimeObservation(
                installedVersion: version,
                process: scan.listener(for: runner.directory),
                busy: scan.isBusy(runner.directory),
                insights: insights,
                serviceInstalled: controller.serviceInstalled(in: runner.directory)
            )
        }
        return result
    }

    func installedVersion(for runner: RunnerInstance) async -> String? {
        let bin = runner.directory.appendingPathComponent("bin/Runner.Listener")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else { return nil }
        let result = try? await Shell.run(bin.path, ["--version"], cwd: runner.directory)
        guard let result, result.succeeded else { return nil }
        return result.out.isEmpty ? nil : result.out
    }

    func freshProcessScan() async -> ProcessScan {
        await ProcessMonitor.scan()
    }

    func start(_ runner: RunnerInstance, mode: StartMode) async throws {
        try await controller.start(runner, mode: mode)
    }

    func stop(_ runner: RunnerInstance, pid: Int32?, force: Bool) async throws {
        try await controller.stop(runner, pid: pid, force: force)
    }

    func register(_ request: RegistrationRequest) async throws {
        try await controller.register(request)
    }

    func unregister(_ runner: RunnerInstance, token: String) async throws {
        try await controller.unregister(runner, token: token)
    }

    func removeLocalConfig(_ directory: URL) async throws {
        try await controller.removeLocalConfig(directory)
    }

    func installService(_ runner: RunnerInstance) async throws {
        try await controller.installService(runner)
    }

    func installServiceOnly(_ runner: RunnerInstance) async throws {
        try await controller.installServiceOnly(runner)
    }

    func startService(_ runner: RunnerInstance) async throws {
        try await controller.startService(runner)
    }

    func stopService(_ runner: RunnerInstance) async throws {
        try await controller.stopService(runner)
    }

    func uninstallService(_ runner: RunnerInstance) async throws {
        try await controller.uninstallService(runner)
    }

    func serviceStatus(_ runner: RunnerInstance) async throws -> String {
        try await controller.serviceStatus(runner)
    }

    func serviceLogDirectory(for runner: RunnerInstance) -> URL? {
        controller.serviceLogDirectory(for: runner)
    }
}
