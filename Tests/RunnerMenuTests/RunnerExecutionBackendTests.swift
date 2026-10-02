import Foundation
import Testing
@testable import RunnerMenu

struct RunnerExecutionBackendTests {
    @Test func observationDetectsServiceMarker() async throws {
        let directory = try temporaryRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data().write(to: directory.appendingPathComponent(".service"))
        let runner = RunnerInstance(directory: directory)
        let backend = LocalRunnerExecutionBackend(processScan: { ProcessScan() })

        let observations = try await backend.observe([
            RunnerObservationRequest(runner: runner, includeVersion: false)
        ])
        let observation = try #require(observations[runner.id])

        #expect(observation.serviceInstalled)
        #expect(observation.installedVersion == nil)
        #expect(observation.process == nil)
        #expect(observation.insights == nil)
    }

    @Test func observationReadsVersionOnlyWhenRequested() async throws {
        let directory = try temporaryRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let listener = binDirectory.appendingPathComponent("Runner.Listener")
        try "#!/bin/sh\nprintf '2.999.0\\n'\n".write(to: listener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: listener.path)

        let runner = RunnerInstance(directory: directory)
        let backend = LocalRunnerExecutionBackend(processScan: { ProcessScan() })
        let withoutVersion = try await backend.observe([
            RunnerObservationRequest(runner: runner, includeVersion: false)
        ])
        let withVersion = try await backend.observe([
            RunnerObservationRequest(runner: runner, includeVersion: true)
        ])

        #expect(withoutVersion[runner.id]?.installedVersion == nil)
        #expect(withVersion[runner.id]?.installedVersion == "2.999.0")
    }

    @Test func batchedObservationRunsOneProcessScanAndEmptyRequestsRunNone() async throws {
        let a = try temporaryRunnerDirectory()
        let b = try temporaryRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let calls = ScanCounter()
        let backend = LocalRunnerExecutionBackend(processScan: { await calls.scan() })
        #expect(try await backend.observe([]).isEmpty)
        #expect(await calls.count == 0)
        let runners = [RunnerInstance(directory: a), RunnerInstance(directory: b)]
        _ = try await backend.observe(runners.map { RunnerObservationRequest(runner: $0, includeVersion: false) })
        #expect(await calls.count == 1)
    }

    private func temporaryRunnerDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-backend-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor ScanCounter {
    var count = 0
    func scan() -> ProcessScan { count += 1; return ProcessScan() }
}
