import Foundation
import Testing
@testable import RunnerMenu

struct RunnerDiscoveryTests {
    @Test func findsRunnerDirectoriesWithinBoundedDepth() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let topLevel = root.appendingPathComponent("actions-runner-one", isDirectory: true)
        let atDepthLimit = root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("actions-runner-two", isDirectory: true)
        let tooDeep = atDepthLimit.appendingPathComponent("nested-runner", isDirectory: true)
        try makeRunner(at: topLevel)
        try makeRunner(at: atDepthLimit)
        try makeRunner(at: tooDeep)

        let results = RunnerDiscovery.discover(in: [root], maximumDepth: 2)
        let ids = Set(results.map(\.id))

        #expect(ids.contains(topLevel.standardizedFileURL.path))
        #expect(ids.contains(atDepthLimit.standardizedFileURL.path))
        #expect(!ids.contains(tooDeep.standardizedFileURL.path))
    }

    @Test func skipsSymlinksAndLargeDependencyTrees() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let realRunner = outside.appendingPathComponent("real-runner", isDirectory: true)
        try makeRunner(at: realRunner)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-runner"),
            withDestinationURL: realRunner
        )
        let dependencyRunner = root
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("actions-runner-hidden", isDirectory: true)
        try makeRunner(at: dependencyRunner)

        let discovered = RunnerDiscovery.discover(in: [root])

        #expect(discovered.isEmpty)
    }

    @Test func includesExplicitRunnerOutsideSearchRoots() throws {
        let root = try temporaryDirectory()
        let explicit = try temporaryDirectory()
            .appendingPathComponent("saved-runner", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: explicit.deletingLastPathComponent())
        }
        try makeRunner(at: explicit)

        let discovered = RunnerDiscovery.discover(
            in: [root],
            explicitDirectories: [explicit]
        )

        #expect(discovered.map(\.id) == [explicit.standardizedFileURL.path])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-discovery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRunner(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("run.sh"))
        try Data().write(to: directory.appendingPathComponent("config.sh"))
    }
}
