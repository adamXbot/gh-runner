import Foundation

/// Synthetic fixtures only. Compile against the production reader and process parser.
@main
struct PerformanceBenchmark {
    static func main() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--verify-live-processes") {
            guard index + 1 < CommandLine.arguments.count else { throw BenchmarkError.missingFixturePath }
            let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("runner-") }
            let scan = await ProcessMonitor.scan()
            let listeners = directories.filter { scan.listener(for: $0) != nil }.count
            let workers = directories.filter { scan.isBusy($0) }.count
            guard directories.count == 8, listeners == 8, workers == 1 else { throw BenchmarkError.missingProcesses }
            let data = try JSONSerialization.data(withJSONObject: ["configured_runners": directories.count,
                "listeners_found": listeners, "busy_runners_found": workers], options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runner-menu-benchmark-\(UUID().uuidString)")
        let keep = CommandLine.arguments.contains("--keep-fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if !keep { try? FileManager.default.removeItem(at: root) } }
        let marker = try JSONSerialization.data(withJSONObject: ["purpose": "RunnerMenu performance fixture", "runner_count": 8])
        try marker.write(to: root.appendingPathComponent("performance-fixture.json"))
        var directories: [URL] = []
        let diagnostic = "[2026-07-13 00:00:00Z INFO Listener] ordinary diagnostic output\n"
        let filler = String(repeating: diagnostic, count: (1024 * 1024) / diagnostic.utf8.count)
        var fileBytes = 0
        for runner in 0..<8 {
            let directory = root.appendingPathComponent("runner-\(runner)")
            directories.append(directory)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("_diag"), withIntermediateDirectories: true)
            let config = RunnerConfig(agentId: runner + 1, agentName: "Fixture \(runner)", gitHubUrl: "https://github.com/example/performance-fixture")
            try JSONEncoder().encode(config).write(to: directory.appendingPathComponent(".runner"))
            for script in ["run.sh", "config.sh"] { try Data().write(to: directory.appendingPathComponent(script)) }
            for rotation in 0..<4 {
                let log = directory.appendingPathComponent("_diag/Runner_\(rotation).log")
                let content = "WRITE LINE: 2026-07-13 00:00:00Z: Running job: Build \(rotation)\n" + filler
                    + "WRITE LINE: 2026-07-13 00:00:05Z: Job Build \(rotation) completed with result: Succeeded\n"
                let data = Data(content.utf8)
                try data.write(to: log)
                fileBytes += data.count
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(rotation + 1))], ofItemAtPath: log.path)
            }
        }
        let reads = ByteCounter()
        let cache = LogTailer.InsightCache { url, offset, count in
            let data = LogTailer.readLogRange(url, offset: offset, count: count)
            reads.add(data?.count ?? 0)
            return data
        }
        let cold = await measure(count: 1) { _ = await cache.insights(for: directories) }
        let coldBytes = reads.bytes
        let warm = await measure { _ = await cache.insights(for: directories) }
        let warmBytes = reads.bytes - coldBytes
        let active = directories[0].appendingPathComponent("_diag/Runner_3.log")
        let appended = Data("WRITE LINE: 2026-07-13 00:01:00Z: Running job: Appended Build\n".utf8)
        let handle = try FileHandle(forWritingTo: active)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()
        let beforeAppend = reads.bytes
        let append = await measure(count: 1) { _ = await cache.insights(for: directories) }
        let appendBytes = reads.bytes - beforeAppend
        let actual = await cache.insights(for: directories)
        for directory in directories {
            guard actual[directory.path] == LogTailer.insights(for: directory) else {
                throw BenchmarkError.mismatchedInsights
            }
        }
        let mergedCache = LogTailer.MergedTailCache()
        let sources = directories.enumerated().map { (name: "Fixture \($0.offset)", directory: $0.element) }
        _ = await mergedCache.mergedTail(runners: sources)
        let mergedWarm = await measure { _ = await mergedCache.mergedTail(runners: sources) }
        let merged = await measure { _ = LogTailer.mergedTail(runners: directories.enumerated().map { (name: "Fixture \($0.offset)", directory: $0.element) }) }
        let tail = try LogTailer.tailSnapshot(at: active, maxLines: 400)
        let tailTime = await measure { _ = LogTailer.tail(active, maxLines: 400) }
        let unrelated = (0..<10_000).map { "\($0 + 100) 0.0 1024 00:01 /Applications/Unrelated\($0).app/App" }.joined(separator: "\n")
        let snapshot = unrelated + "\n1 0.5 1024 01:00 /tmp/fixture/bin/Runner.Listener\n"
        let process = await measure { _ = ProcessMonitor.parseSnapshot(snapshot) }
        let workerDirectory = root.appendingPathComponent("worker-fixture")
        try FileManager.default.createDirectory(at: workerDirectory.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let start = formatter.date(from: "20260713-000000")!
        for index in 0..<1000 {
            let name = "Worker_\(formatter.string(from: start.addingTimeInterval(Double(index) * 60)))-utc.log"
            try Data().write(to: workerDirectory.appendingPathComponent("_diag/\(name)"))
        }
        let job = JobRecord(id: "fixture", name: "Build", result: .running, timestamp: start.addingTimeInterval(500 * 60), rawTime: "")
        let worker = await measure { _ = LogTailer.workerLog(for: job, in: workerDirectory) }
        var result: [String: Any] = [
            "schema_version": 1,
            "workload": ["runners": 8, "rotations_per_runner": 4, "log_bytes": fileBytes, "process_rows": 10_001, "worker_logs": 1000],
            "cold_insights": ["median_ms": median(cold), "bytes_read": coldBytes],
            "unchanged_insights": ["median_ms": median(warm), "samples_ms": warm, "bytes_read": warmBytes],
            "appended_insights": ["median_ms": median(append), "bytes_read": appendBytes, "appended_bytes": appended.count],
            "tail_400_lines": ["median_ms": median(tailTime), "bytes_read": tail.bytesRead],
            "merged_8_runners_uncached": ["median_ms": median(merged)],
            "merged_8_runners_cached": ["median_ms": median(mergedWarm)],
            "process_10001_rows": ["median_ms": median(process)],
            "worker_lookup_1000_logs": ["median_ms": median(worker)],
            "cached_matches_uncached": true
        ]
        if keep { result["fixture_root"] = root.path }
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }

    private static func measure(count: Int = 9, _ work: () async -> Void) async -> [Double] {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<count {
            let start = clock.now
            await work()
            let elapsed = start.duration(to: clock.now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        return samples
    }
    private static func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }
}

private enum BenchmarkError: Error { case mismatchedInsights, missingFixturePath, missingProcesses }
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ count: Int) { lock.lock(); defer { lock.unlock() }; total += count }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return total }
}
