import Foundation
import Darwin
import Testing
@testable import RunnerAgent

struct RunnerAgentDiscoveryTests {
    @Test func discoversOnlyDirectoriesOwnedByExpectedAccount() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = root.appendingPathComponent("actions-runner-repo", isDirectory: true)
        try makeRunner(at: runner)

        let owned = RunnerAgentDiscovery.discover(
            in: [root],
            ownerUserID: geteuid()
        )
        let wrongOwner = RunnerAgentDiscovery.discover(
            in: [root],
            ownerUserID: geteuid() &+ 1
        )

        #expect(owned.count == 1)
        #expect(owned.first?.displayName == "test-runner")
        #expect(owned.first?.scopeLabel == "owner/repo")
        #expect(wrongOwner.isEmpty)
    }

    @Test func agentDiscoveryDoesNotFollowSymlinkedRunner() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let runner = outside.appendingPathComponent("real-runner", isDirectory: true)
        try makeRunner(at: runner)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-runner"),
            withDestinationURL: runner
        )

        let discovered = RunnerAgentDiscovery.discover(
            in: [root],
            explicitDirectories: [root.appendingPathComponent("linked-runner")],
            ownerUserID: geteuid()
        )

        #expect(discovered.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRunner(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("run.sh"))
        try Data().write(to: directory.appendingPathComponent("config.sh"))
        let config = #"{"agentName":"test-runner","gitHubUrl":"https://github.com/owner/repo"}"#
        try config.write(
            to: directory.appendingPathComponent(".runner"),
            atomically: true,
            encoding: .utf8
        )
    }
}
