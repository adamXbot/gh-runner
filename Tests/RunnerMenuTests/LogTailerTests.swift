import Foundation
import Testing
@testable import RunnerMenu

struct LogTailerTests {
    @Test func consoleDistinguishesMissingEmptyAndUnreadableLogs() throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let missing = LogTailer.readTail(in: runner, prefix: "Runner_")
        #expect(missing.url == nil)
        #expect(missing.issue == nil)
        let log = LogTailer.diagDirectory(for: runner).appendingPathComponent("Runner_1.log")
        try Data().write(to: log)
        let empty = LogTailer.readTail(in: runner, prefix: "Runner_")
        #expect(empty.url?.resolvingSymlinksInPath() == log.resolvingSymlinksInPath())
        #expect(empty.lines.isEmpty)
        #expect(empty.issue == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path) }
        let unreadable = LogTailer.readTail(in: runner, prefix: "Runner_")
        #expect(unreadable.issue?.contains("permissions") == true)
        #expect(unreadable.lines.isEmpty)
    }

    @Test func missingDiagnosticDirectoryIsAnEmptyState() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = LogTailer.readTail(in: missing, prefix: "Worker_")
        #expect(result.url == nil)
        #expect(result.issue == nil)
    }

    @Test func insightsPreserveHistoryAcrossRunnerLogRotations() throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let diag = LogTailer.diagDirectory(for: runner)
        let first = diag.appendingPathComponent("Runner_20260713-000000-utc.log")
        let second = diag.appendingPathComponent("Runner_20260713-010000-utc.log")

        try """
        [2026-07-13 00:00:00Z INFO Terminal] WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build
        [2026-07-13 00:01:00Z INFO Terminal] WRITE LINE: 2026-07-13 00:01:00Z: Job Build completed with result: Succeeded
        """.write(to: first, atomically: true, encoding: .utf8)
        try """
        [2026-07-13 01:00:00Z INFO Terminal] WRITE LINE: 2026-07-13 01:00:00Z: Listening for Jobs
        """.write(to: second, atomically: true, encoding: .utf8)
        try setModificationDate(100, for: first)
        try setModificationDate(200, for: second)

        let insights = LogTailer.insights(for: runner)

        #expect(insights.currentJob == nil)
        #expect(insights.history.count == 1)
        #expect(insights.history.first?.name == "Build")
        #expect(insights.history.first?.result == .succeeded)
        #expect(insights.lastLine == "Listening for Jobs")
        #expect(LogTailer.insights(for: runner).history.first?.id == insights.history.first?.id)
    }

    @Test func insightsTrackAJobStartedInTheNewestLog() throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let log = LogTailer.diagDirectory(for: runner)
            .appendingPathComponent("Runner_20260713-020000-utc.log")
        try """
        [2026-07-13 02:00:00Z INFO Terminal] WRITE LINE: 2026-07-13 02:00:00Z: Running job: Test
        """.write(to: log, atomically: true, encoding: .utf8)

        let insights = LogTailer.insights(for: runner)

        #expect(insights.currentJob == "Test")
        #expect(insights.history.first?.result == .running)
    }

    @Test func mergedTailInterleavesRunnersByTimestamp() throws {
        let a = try makeRunnerDirectory(); defer { try? FileManager.default.removeItem(at: a) }
        let b = try makeRunnerDirectory(); defer { try? FileManager.default.removeItem(at: b) }
        try """
        [2026-07-13 00:00:01Z INFO X] first
        [2026-07-13 00:00:03Z INFO X] third
        """.write(to: LogTailer.diagDirectory(for: a).appendingPathComponent("Runner_1.log"),
                  atomically: true, encoding: .utf8)
        try """
        [2026-07-13 00:00:02Z INFO X] second
        """.write(to: LogTailer.diagDirectory(for: b).appendingPathComponent("Runner_1.log"),
                  atomically: true, encoding: .utf8)

        let merged = LogTailer.mergedTail(runners: [(name: "A", directory: a), (name: "B", directory: b)])

        #expect(merged.map(\.runner) == ["A", "B", "A"])
        #expect(merged.map { $0.text.contains("first") || $0.text.contains("second") || $0.text.contains("third") }
                    .allSatisfy { $0 })
    }

    @Test func insightsComputeJobDuration() throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let log = LogTailer.diagDirectory(for: runner).appendingPathComponent("Runner_1.log")
        try """
        [2026-07-13 00:00:00Z INFO Terminal] WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build
        [2026-07-13 00:01:24Z INFO Terminal] WRITE LINE: 2026-07-13 00:01:24Z: Job Build completed with result: Succeeded
        """.write(to: log, atomically: true, encoding: .utf8)

        let insights = LogTailer.insights(for: runner)
        let job = try #require(insights.history.first)
        #expect(job.result == .succeeded)
        #expect(job.duration == 84)
        #expect(job.durationText == "1m 24s")
        #expect(job.startTimestamp != nil)   // start is preserved (for Worker-log matching)
    }

    @Test func runningJobHasNoDuration() throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        try "[2026-07-13 00:00:00Z INFO Terminal] WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build"
            .write(to: LogTailer.diagDirectory(for: runner).appendingPathComponent("Runner_1.log"),
                   atomically: true, encoding: .utf8)

        let job = try #require(LogTailer.insights(for: runner).history.first)
        #expect(job.result == .running)
        #expect(job.duration == nil)
        #expect(job.durationText == nil)
    }

    @Test func durationFormatterProducesShortStrings() {
        #expect(JobRecord.formatDuration(0) == "0s")
        #expect(JobRecord.formatDuration(12) == "12s")
        #expect(JobRecord.formatDuration(84) == "1m 24s")
        #expect(JobRecord.formatDuration(3 * 3600 + 5 * 60) == "3h 5m")
    }

    @Test func runIDParsesFromWorkerJobMessage() {
        // Mirrors the runner's Worker-log job-message shape: "k":"run_id" then "v":"<digits>".
        let text = """
                  "k": "repository",
                  "v": "octo-org/octo-repo"
                },
                {
                  "k": "run_id",
                  "v": "29227574780"
                },
                {
                  "k": "server_url",
                  "v": "https://github.com"
        """
        #expect(LogTailer.runID(inWorkerText: text) == "29227574780")
        #expect(LogTailer.runID(inWorkerText: "nothing here") == nil)
        #expect(LogTailer.runID(inWorkerText: "\"run_id\"\n\"v\": \"not-a-number\"") == nil)
    }

    @Test func workflowRunReferenceParsesRepositoryAndRunID() throws {
        let text = """
                {
                  "k": "repository",
                  "v": "octo-org/octo-repo"
                },
                {
                  "k": "run_id",
                  "v": "29227574780"
                }
        """
        let reference = try #require(LogTailer.workflowRunReference(inWorkerText: text))
        #expect(reference.repository == "octo-org/octo-repo")
        #expect(reference.runID == "29227574780")
        #expect(reference.gitHubURL?.absoluteString
                == "https://github.com/octo-org/octo-repo/actions/runs/29227574780")
        #expect(LogTailer.workflowRunReference(inWorkerText: text.replacingOccurrences(
            of: "octo-org/octo-repo", with: "not-a-repository"
        )) == nil)
    }

    @Test func workerFileTimestampParsesFilename() throws {
        let url = URL(fileURLWithPath: "/x/_diag/Worker_20260713-061804-utc.log")
        let date = try #require(LogTailer.workerFileTimestamp(url))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(c.year == 2026 && c.month == 7 && c.day == 13)
        #expect(c.hour == 6 && c.minute == 18 && c.second == 4)
        #expect(LogTailer.workerFileTimestamp(URL(fileURLWithPath: "/x/notaworker.log")) == nil)
    }

    @Test func workerLogMatchesJobByNearestStartTime() throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let diag = LogTailer.diagDirectory(for: runner)
        // Two worker logs a minute apart.
        for name in ["Worker_20260713-061804-utc.log", "Worker_20260713-061925-utc.log"] {
            try "x".write(to: diag.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX"); iso.timeZone = TimeZone(identifier: "UTC")
        iso.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        var job = JobRecord(id: "j1", name: "Build", result: .succeeded,
                            timestamp: iso.date(from: "2026-07-13 06:19:30Z"), rawTime: "",
                            startTimestamp: iso.date(from: "2026-07-13 06:19:27Z"))
        #expect(LogTailer.workerLog(for: job, in: runner)?.lastPathComponent == "Worker_20260713-061925-utc.log")
        job.startTimestamp = iso.date(from: "2026-07-13 06:18:05Z")
        #expect(LogTailer.workerLog(for: job, in: runner)?.lastPathComponent == "Worker_20260713-061804-utc.log")
    }

    @Test func tailToleratesNonUTF8Bytes() throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let log = LogTailer.diagDirectory(for: runner).appendingPathComponent("Runner_1.log")
        // "Hi" + an invalid UTF-8 byte + newline + "there" — a strict decode would return nil.
        var data = Data("Hi".utf8)
        data.append(0xFF)
        data.append(contentsOf: "\nthere".utf8)
        try data.write(to: log)

        let lines = LogTailer.tail(log)
        #expect(!lines.isEmpty)
        #expect(lines.contains { $0.contains("Hi") })
        #expect(lines.contains { $0.contains("there") })
    }

    @Test func cachedInsightsReuseUnchangedFilesAndRefreshOnlyChangedRotations() async throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let diag = LogTailer.diagDirectory(for: runner)
        let first = diag.appendingPathComponent("Runner_1.log")
        let second = diag.appendingPathComponent("Runner_2.log")
        try "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build\n".write(to: first, atomically: true, encoding: .utf8)
        try "ordinary diagnostic output\n".write(to: second, atomically: true, encoding: .utf8)
        try setModificationDate(100, for: first)
        try setModificationDate(200, for: second)
        let reads = LogReadCounter()
        let cache = LogTailer.InsightCache { url, offset, count in
            reads.record()
            return LogTailer.readLogRange(url, offset: offset, count: count)
        }
        let initial = await cache.insights(for: [runner])
        let unchanged = await cache.insights(for: [runner])
        #expect(initial == unchanged)
        #expect(reads.count == 2)
        #expect(initial[runner.path] == LogTailer.insights(for: runner))

        let handle = try FileHandle(forWritingTo: second)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("WRITE LINE: 2026-07-13 00:01:24Z: Job Build completed with result: Succeeded\n".utf8))
        try handle.close()
        let updated = await cache.insights(for: [runner])
        #expect(reads.count == 4)
        #expect(updated[runner.path] == LogTailer.insights(for: runner))
        #expect(updated[runner.path]?.history.first?.duration == 84)
        #expect(updated[runner.path]?.currentJob == nil)
    }

    @Test func cachedInsightsFollowTruncationReplacementRotationAndDeletion() async throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let diag = LogTailer.diagDirectory(for: runner)
        let log = diag.appendingPathComponent("Runner_1.log")
        let cache = LogTailer.InsightCache()
        try "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build\n".write(to: log, atomically: true, encoding: .utf8)
        let started = await cache.insights(for: [runner])
        #expect(started[runner.path]?.currentJob == "Build")

        // In-place truncation must discard the old job state.
        try Data().write(to: log)
        let truncated = await cache.insights(for: [runner])
        #expect(truncated[runner.path]?.history.isEmpty == true)
        // Atomic replacement is detected even when size and modification time match.
        let oldText = "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build\n"
        try oldText.write(to: log, atomically: true, encoding: .utf8)
        try setModificationDate(100, for: log)
        _ = await cache.insights(for: [runner])
        try oldText.replacingOccurrences(of: "Build", with: "Tests").write(to: log, atomically: true, encoding: .utf8)
        try setModificationDate(100, for: log)
        let replaced = await cache.insights(for: [runner])
        #expect(replaced[runner.path]?.currentJob == "Tests")

        let next = diag.appendingPathComponent("Runner_2.log")
        try "WRITE LINE: 2026-07-13 00:01:00Z: Job Tests completed with result: Succeeded\n".write(to: next, atomically: true, encoding: .utf8)
        let rotated = await cache.insights(for: [runner])
        #expect(rotated[runner.path] == LogTailer.insights(for: runner))
        #expect(rotated[runner.path]?.history.first?.result == .succeeded)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.removeItem(at: next)
        let deleted = await cache.insights(for: [runner])
        #expect(deleted[runner.path]?.history.isEmpty == true)
        #expect(deleted[runner.path]?.currentJob == nil)
    }

    @Test func cachedInsightsRetryReadFailuresAndForgetRemovedRunners() async throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let log = LogTailer.diagDirectory(for: runner).appendingPathComponent("Runner_1.log")
        try "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build\n".write(to: log, atomically: true, encoding: .utf8)
        let reads = LogReadCounter()
        let cache = LogTailer.InsightCache { url, offset, count in
            reads.record()
            return reads.count == 1 ? nil : LogTailer.readLogRange(url, offset: offset, count: count)
        }
        let failed = await cache.insights(for: [runner])
        #expect(failed[runner.path]?.history.isEmpty == true)
        let recovered = await cache.insights(for: [runner])
        #expect(recovered[runner.path]?.currentJob == "Build")
        #expect(reads.count == 2)
        _ = await cache.insights(for: [])
        _ = await cache.insights(for: [runner])
        #expect(reads.count == 3)
    }

    @Test func boundedTailMatchesWholeFileTailAcrossBlockBoundaries() throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let log = LogTailer.diagDirectory(for: runner).appendingPathComponent("Runner_1.log")
        for finalNewline in [false, true] {
            let content = (0..<10_000).map { "\($0): résumé 🛠 " + String(repeating: "x", count: 20) }
                .joined(separator: "\n") + (finalNewline ? "\n" : "")
            try content.write(to: log, atomically: true, encoding: .utf8)
            for limit in [1, 80, 400, 4000, 20_000] {
                let expected = content.split(separator: "\n", omittingEmptySubsequences: false).suffix(limit).map(String.init)
                #expect(LogTailer.tail(log, maxLines: limit) == expected)
                #expect(LogTailer.readTail(at: log, maxLines: limit).lines == expected)
            }
        }
        #expect(LogTailer.tail(log, maxLines: 0).isEmpty)
        #expect(LogTailer.tail(log, maxLines: -1).isEmpty)
    }

    @Test func boundedTailPreservesBlankLinesAndVeryLongLines() throws {
        let runner = try makeRunnerDirectory()
        defer { try? FileManager.default.removeItem(at: runner) }
        let log = LogTailer.diagDirectory(for: runner).appendingPathComponent("Runner_1.log")
        let longLine = String(repeating: "é", count: 100_000)
        try ("older\n\n" + longLine + "\nlast\n").write(to: log, atomically: true, encoding: .utf8)
        #expect(LogTailer.tail(log, maxLines: 4) == ["", longLine, "last", ""])
        try Data().write(to: log)
        #expect(LogTailer.tail(log).isEmpty)
    }

    private func makeRunnerDirectory() throws -> URL {
        let runner = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: LogTailer.diagDirectory(for: runner),
            withIntermediateDirectories: true
        )
        return runner
    }

    private func setModificationDate(_ interval: TimeInterval, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: interval)],
            ofItemAtPath: url.path
        )
    }
}

private final class LogReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
