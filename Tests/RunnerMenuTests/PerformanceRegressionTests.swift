import Foundation
import Testing
@testable import RunnerMenu

struct PerformanceRegressionTests {
    @Test func growingLogReadsOnlyNewBytesAndCheckpoints() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        let filler = String(repeating: "ordinary diagnostic output\n", count: 50_000)
        let content = filler + "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build\n"
        try content.write(to: log, atomically: true, encoding: .utf8)
        let reads = ReadMetrics()
        let cache = LogTailer.InsightCache { url, offset, count in
            let data = LogTailer.readLogRange(url, offset: offset, count: count)
            reads.record(data?.count ?? 0)
            return data
        }
        let initial = await cache.insights(for: [root])
        let initialBytes = reads.bytes
        #expect(initialBytes == content.utf8.count)
        #expect(initial[root.path]?.currentJob == "Build")
        _ = await cache.insights(for: [root])
        #expect(reads.bytes == initialBytes)
        let completion = Data("WRITE LINE: 2026-07-13 00:01:24Z: Job Build completed with result: Succeeded\n".utf8)
        try append(completion, to: log)
        let updated = await cache.insights(for: [root])
        #expect(reads.bytes - initialBytes == completion.count + 512)
        #expect(updated[root.path] == LogTailer.insights(for: root))
        #expect(updated[root.path]?.history.first?.duration == 84)
    }

    @Test func incrementalReaderCompletesPartialUTF8AndKeepsStableJobIdentity() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        var first = Data("\nordinary\n\nWRITE LINE: 2026-07-13 00:00:00Z: Running job: Caf".utf8)
        first.append(0xC3)
        try first.write(to: log)
        let cache = LogTailer.InsightCache()
        let provisional = await cache.insights(for: [root])
        let id = provisional[root.path]?.history.first?.id
        var remaining = Data([0xA9])
        remaining.append(contentsOf: "\n\nWRITE LINE: 2026-07-13 00:00:05Z: Job Café completed with result: Succeeded\n".utf8)
        try append(remaining, to: log)
        let completed = await cache.insights(for: [root])
        #expect(completed[root.path] == LogTailer.insights(for: root))
        #expect(completed[root.path]?.history.count == 1)
        #expect(completed[root.path]?.history.first?.id == id)
        #expect(completed[root.path]?.history.first?.name == "Café")
        #expect(completed[root.path]?.history.first?.duration == 5)
    }

    @Test func incrementalReaderReplaysDetectedInPlaceRewriteWithGrowth() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        try "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Old\n".write(to: log, atomically: true, encoding: .utf8)
        let cache = LogTailer.InsightCache()
        _ = await cache.insights(for: [root])
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("WRITE LINE: 2026-07-13 00:00:01Z: Running job: Replacement\nmore diagnostic output\n".utf8))
        try handle.close()
        let replaced = await cache.insights(for: [root])
        #expect(replaced[root.path] == LogTailer.insights(for: root))
        #expect(replaced[root.path]?.history.count == 1)
        #expect(replaced[root.path]?.currentJob == "Replacement")
    }

    @Test func cacheRejectsAFileRewrittenDuringTheReadAndRetries() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        try "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Old\n".write(to: log, atomically: true, encoding: .utf8)
        let replacement = Data("WRITE LINE: 2026-07-13 00:00:00Z: Running job: New\n".utf8)
        let reads = ReadMetrics()
        let cache = LogTailer.InsightCache { url, offset, count in
            let data = LogTailer.readLogRange(url, offset: offset, count: count)
            reads.record(data?.count ?? 0)
            if reads.calls == 1, let handle = try? FileHandle(forWritingTo: url) {
                try? handle.write(contentsOf: replacement)
                try? handle.close()
                try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: url.path)
            }
            return data
        }
        #expect(await cache.insights(for: [root])[root.path]?.history.isEmpty == true)
        #expect(await cache.insights(for: [root])[root.path]?.currentJob == "New")
    }

    @Test func cacheDropsUnreadableDataAndRecoversAfterPermissionChange() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        try "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build\n".write(to: log, atomically: true, encoding: .utf8)
        let cache = LogTailer.InsightCache()
        _ = await cache.insights(for: [root])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path) }
        let unreadable = await cache.insights(for: [root])
        #expect(unreadable[root.path]?.history.isEmpty == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        let recovered = await cache.insights(for: [root])
        #expect(recovered[root.path]?.currentJob == "Build")
    }

    @Test func parallelReadersShareTheParsedSnapshot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        let data = Data("WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build\n".utf8)
        try data.write(to: log)
        let reads = ReadMetrics()
        let cache = LogTailer.InsightCache { url, offset, count in
            let data = LogTailer.readLogRange(url, offset: offset, count: count)
            reads.record(data?.count ?? 0)
            return data
        }
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<30 { group.addTask { await cache.insights(for: [root])[root.path]?.currentJob == "Build" } }
            for await correct in group { #expect(correct) }
        }
        #expect(reads.bytes == data.count)
    }

    @Test func logHistoryReadsAtMostTwelveRotations() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 {
            let log = root.appendingPathComponent("_diag/Runner_\(index).log")
            try "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Job\(index)\n".write(to: log, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: log.path)
        }
        let reads = ReadMetrics()
        let cache = LogTailer.InsightCache { url, offset, count in
            let data = LogTailer.readLogRange(url, offset: offset, count: count)
            reads.record(data?.count ?? 0)
            return data
        }
        let result = await cache.insights(for: [root])
        #expect(reads.calls == 12)
        #expect(result[root.path]?.history.count == 12)
        #expect(result[root.path]?.history.first?.name == "Job19")
    }

    @Test func tailReadsOneBlockFromALargeFile() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.seekToEnd()
        let recent = (0..<1000).map { "recent line \($0)" }.joined(separator: "\n")
        try handle.write(contentsOf: Data(("\n" + recent).utf8))
        try handle.close()
        let tail = try LogTailer.tailSnapshot(at: log, maxLines: 400)
        #expect(tail.bytesRead == 64 * 1024)
        #expect(tail.lines.count == 400)
        #expect(tail.lines.first == "recent line 600")
        #expect(tail.lines.last == "recent line 999")
    }

    @Test func tailAndJobParserHandleWindowsNewlines() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        try "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build\r\nWRITE LINE: 2026-07-13 00:00:05Z: Job Build completed with result: Succeeded\r\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(LogTailer.tail(log, maxLines: 1) == [""])
        #expect(LogTailer.tail(log, maxLines: 2).first?.hasSuffix("Succeeded") == true)
        let result = await LogTailer.InsightCache().insights(for: [root])
        #expect(result[root.path]?.history.first?.result == .succeeded)
        #expect(result[root.path]?.history.first?.duration == 5)
        #expect(result[root.path] == LogTailer.insights(for: root))
    }

    @Test func newestLogUsesModificationTimeAndDeterministicTieBreak() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Runner_A.log", "Runner_B.log", "Worker_Z.log"] {
            let log = root.appendingPathComponent("_diag/\(name)")
            try Data().write(to: log)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: log.path)
        }
        #expect(LogTailer.newestLog(in: root, prefix: "Runner_")?.lastPathComponent == "Runner_B.log")
        let first = root.appendingPathComponent("_diag/Runner_A.log")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: first.path)
        #expect(LogTailer.newestLog(in: root, prefix: "Runner_")?.lastPathComponent == "Runner_A.log")
    }

    @Test func mergedTailReusesUnchangedSourcesAndReadsOnlyChangedLog() async throws {
        let first = try fixture(), second = try fixture()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let firstLog = first.appendingPathComponent("_diag/Runner_1.log")
        let secondLog = second.appendingPathComponent("_diag/Runner_1.log")
        try "[2026-07-13 00:00:00Z INFO] first\ncontinued".write(to: firstLog, atomically: true, encoding: .utf8)
        try "untimed\n[2026-07-13 00:00:01Z INFO] second".write(to: secondLog, atomically: true, encoding: .utf8)
        let reads = ReadMetrics()
        let cache = LogTailer.MergedTailCache { url, count in
            reads.record(0)
            return try LogTailer.tailSnapshot(at: url, maxLines: count).lines
        }
        let sources = [(name: "First", directory: first), (name: "Second", directory: second)]
        let initial = await cache.mergedTail(runners: sources)
        #expect(initial == LogTailer.mergedTail(runners: sources))
        #expect(initial.first?.text == "untimed")
        #expect(initial.filter { $0.runner == "First" }.map(\.timestamp).first == initial.filter { $0.runner == "First" }.map(\.timestamp).last)
        _ = await cache.mergedTail(runners: sources)
        #expect(reads.calls == 2)
        try append(Data("\n[2026-07-13 00:00:02Z INFO] updated".utf8), to: secondLog)
        let changed = await cache.mergedTail(runners: sources)
        #expect(changed == LogTailer.mergedTail(runners: sources))
        #expect(changed.last?.text.hasSuffix("updated") == true)
        #expect(reads.calls == 3)
    }

    @Test func mergedTailHandlesNamesLimitsRemovalAndRotation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        try "one\ntwo\nthree".write(to: log, atomically: true, encoding: .utf8)
        let reads = ReadMetrics()
        let cache = LogTailer.MergedTailCache { url, count in
            reads.record(0)
            return try LogTailer.tailSnapshot(at: url, maxLines: count).lines
        }
        _ = await cache.mergedTail(runners: [("Original", root)])
        let renamed = await cache.mergedTail(runners: [("Renamed", root)], limit: 1)
        #expect(renamed.map(\.runner) == ["Renamed"])
        #expect(renamed.map(\.text) == ["three"])
        #expect(reads.calls == 1)
        let shorter = await cache.mergedTail(runners: [("Renamed", root)], perRunner: 2)
        #expect(shorter.map(\.text) == ["two", "three"])
        #expect(reads.calls == 2)
        let newer = root.appendingPathComponent("_diag/Runner_2.log")
        try "rotated".write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: newer.path)
        let rotated = await cache.mergedTail(runners: [("Renamed", root)], perRunner: 2)
        #expect(rotated.map(\.text) == ["rotated"])
        #expect(reads.calls == 3)
        _ = await cache.mergedTail(runners: [])
        _ = await cache.mergedTail(runners: [("Renamed", root)], perRunner: 2)
        #expect(reads.calls == 4)
        try FileManager.default.removeItem(at: newer)
        let previous = await cache.mergedTail(runners: [("Renamed", root)], perRunner: 2)
        #expect(previous.map(\.text) == ["two", "three"])
        #expect(reads.calls == 5)
        #expect(await cache.mergedTail(runners: [("Renamed", root)], perRunner: 0).isEmpty)
        #expect(await cache.mergedTail(runners: [("Renamed", root)], limit: 0).isEmpty)
    }

    @Test func mergedTailRetriesFailedReadsWithoutCachingEmptyResult() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("_diag/Runner_1.log")
        try "recovered".write(to: log, atomically: true, encoding: .utf8)
        let reads = ReadMetrics()
        let cache = LogTailer.MergedTailCache { url, count in
            reads.record(0)
            if reads.calls == 1 { throw CocoaError(.fileReadUnknown) }
            return try LogTailer.tailSnapshot(at: url, maxLines: count).lines
        }
        #expect(await cache.mergedTail(runners: [("Fixture", root)]).isEmpty)
        #expect(await cache.mergedTail(runners: [("Fixture", root)]).map(\.text) == ["recovered"])
        _ = await cache.mergedTail(runners: [("Fixture", root)])
        #expect(reads.calls == 2)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("performance-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        return root
    }

    private func append(_ data: Data, to log: URL) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private final class ReadMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var totalBytes = 0
    private var totalCalls = 0
    func record(_ count: Int) { lock.lock(); defer { lock.unlock() }; totalBytes += count; totalCalls += 1 }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return totalBytes }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return totalCalls }
}
