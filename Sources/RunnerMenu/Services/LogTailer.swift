import Foundation
import SwiftUI

/// The GitHub identity needed to open or cancel a workflow run.
struct WorkflowRunReference: Equatable, Sendable {
    let repository: String
    let runID: String

    var gitHubURL: URL? {
        URL(string: "https://github.com/\(repository)/actions/runs/\(runID)")
    }
}

/// A parsed job outcome from the runner's diagnostic log.
struct JobRecord: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var result: JobResult
    /// Completion time (or start time while still running).
    var timestamp: Date?
    var rawTime: String
    /// When the job started — kept so it can be matched to its Worker log.
    var startTimestamp: Date?
    /// How long the job ran (completion − start), when both timestamps are known.
    var duration: TimeInterval?

    /// Human-readable, locale-independent duration (e.g. "12s", "1m 24s", "1h 3m").
    var durationText: String? {
        guard let duration, duration >= 0 else { return nil }
        return Self.formatDuration(duration)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    enum JobResult: Equatable, Sendable {
        case running
        case succeeded
        case failed
        case canceled
        case skipped
        case other(String)

        init(_ raw: String) {
            switch raw.lowercased() {
            case "succeeded": self = .succeeded
            case "failed": self = .failed
            case "canceled", "cancelled": self = .canceled
            case "skipped": self = .skipped
            default: self = .other(raw)
            }
        }

        var label: String {
            switch self {
            case .running: return "Running"
            case .succeeded: return "Succeeded"
            case .failed: return "Failed"
            case .canceled: return "Canceled"
            case .skipped: return "Skipped"
            case .other(let s): return s
            }
        }

        var symbolName: String {
            switch self {
            case .running: return "circle.dotted"
            case .succeeded: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .canceled: return "minus.circle.fill"
            case .skipped: return "arrow.uturn.forward.circle"
            case .other: return "questionmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .running: return .blue
            case .succeeded: return .green
            case .failed: return .red
            case .canceled, .skipped: return .secondary
            case .other: return .secondary
            }
        }
    }
}

/// Result of parsing a runner's logs.
struct RunnerLogInsights: Equatable, Sendable {
    var currentJob: String?
    var history: [JobRecord]   // newest first
    var lastLine: String?
}

/// Reads and interprets the runner's `_diag` logs.
enum LogTailer {

    /// Enough rotations to preserve useful history without repeatedly reading an
    /// unbounded diagnostic directory on every status poll.
    private static let insightLogLimit = 12

    private static let workerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return f
    }()

    static func diagDirectory(for runner: URL) -> URL {
        runner.appendingPathComponent("_diag")
    }

    private struct LogSignature: Equatable, Sendable {
        let size: UInt64
        let modified: Date
        let created: Date?
        let inode: UInt64
        let permissions: UInt16

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
            self.size = size.uint64Value
            self.modified = modified
            self.created = attributes[.creationDate] as? Date
            self.inode = inode.uint64Value
            self.permissions = permissions.uint16Value
        }

        func canAppend(to previous: Self) -> Bool {
            inode == previous.inode && created == previous.created
                && permissions == previous.permissions && size > previous.size
        }
    }

    private struct LogFile: Equatable, Sendable {
        let url: URL
        let signature: LogSignature
    }

    private static func matchingLogs(in runnerDir: URL, prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: diagDirectory(for: runnerDir), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "log" }
    }

    private static func logFiles(in runnerDir: URL, prefix: String) throws -> [LogFile] {
        try matchingLogs(in: runnerDir, prefix: prefix).compactMap { url in
            LogSignature(url).map { LogFile(url: url, signature: $0) }
        }
    }

    private static func older(_ a: LogFile, than b: LogFile) -> Bool {
        a.signature.modified == b.signature.modified
            ? a.url.lastPathComponent < b.url.lastPathComponent
            : a.signature.modified < b.signature.modified
    }

    /// Select the newest log in one pass; metadata is read once per matching file.
    static func newestLog(in runnerDir: URL, prefix: String) -> URL? {
        newestLogFile(in: runnerDir, prefix: prefix)?.url
    }

    private static func newestLogFile(in runnerDir: URL, prefix: String) -> LogFile? {
        (try? logFiles(in: runnerDir, prefix: prefix))?.max { older($0, than: $1) }
    }

    /// Read a log file, tolerating non-UTF-8 bytes (job stdout often isn't clean UTF-8).
    /// A single invalid byte must not blank the whole log — invalid bytes become U+FFFD.
    static func readLossy(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Read backwards in small blocks so live views do not decode the whole log.
    /// Preserve the existing empty final line when a file ends with a newline.
    static func tail(_ url: URL, maxLines: Int = 200) -> [String] {
        (try? tailSnapshot(at: url, maxLines: maxLines).lines) ?? []
    }

    struct TailSnapshot: Sendable {
        let lines: [String]
        let bytesRead: Int
    }

    static func tailSnapshot(at url: URL, maxLines: Int) throws -> TailSnapshot {
        guard maxLines > 0 else { return TailSnapshot(lines: [], bytesRead: 0) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        guard offset > 0 else { return TailSnapshot(lines: [], bytesRead: 0) }
        var blocks: [Data] = []
        var newlineCount = 0
        while offset > 0, newlineCount <= maxLines {
            let length = min(offset, 64 * 1024)
            offset -= length
            try handle.seek(toOffset: offset)
            let block = try handle.read(upToCount: Int(length)) ?? Data()
            newlineCount += block.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            blocks.append(block)
        }
        var data = Data()
        for block in blocks.reversed() { data.append(block) }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).suffix(maxLines).map {
            String(decoding: $0.last == 0x0D ? $0.dropLast() : $0[...], as: UTF8.self)
        }
        return TailSnapshot(lines: lines, bytesRead: data.count)
    }

    struct ReadResult: Equatable, Sendable {
        let url: URL?
        let lines: [String]
        let issue: String?
    }

    static func readTail(in runnerDir: URL, prefix: String, maxLines: Int = 400) -> ReadResult {
        do {
            let newest = try logFiles(in: runnerDir, prefix: prefix).max { older($0, than: $1) }?.url
            guard let newest else { return ReadResult(url: nil, lines: [], issue: nil) }
            return readTail(at: newest, maxLines: maxLines)
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                return ReadResult(url: nil, lines: [], issue: nil)
            }
            return ReadResult(url: nil, lines: [], issue: logReadIssue(error))
        }
    }

    static func readTail(at url: URL, maxLines: Int = 400) -> ReadResult {
        do {
            return ReadResult(url: url, lines: try tailSnapshot(at: url, maxLines: maxLines).lines, issue: nil)
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                return ReadResult(url: nil, lines: [], issue: nil)
            }
            return ReadResult(url: url, lines: [], issue: logReadIssue(error))
        }
    }

    private static func logReadIssue(_ error: Error) -> String {
        let fileError = error as NSError
        let underlying = fileError.userInfo[NSUnderlyingErrorKey] as? NSError
        let posixError = fileError.domain == NSPOSIXErrorDomain ? fileError : underlying
        if fileError.code == NSFileReadNoPermissionError
            || (posixError?.domain == NSPOSIXErrorDomain
                && [Int(EACCES), Int(EPERM)].contains(posixError?.code ?? 0)) {
            return "Runner Menu cannot read this log. Check folder permissions or open it from the runner owner's macOS account."
        }
        return "Could not read the log: \(error.localizedDescription) Check the log folder in Finder."
    }

    /// One line in the combined dashboard log, tagged with the runner it came from.
    struct MergedLogLine: Identifiable, Equatable, Sendable {
        let id: Int
        let runner: String
        let text: String
        let timestamp: Date?
    }

    /// Parse the leading `[YYYY-MM-DD HH:MM:SSZ` timestamp from a raw runner log line.
    static func leadingTimestamp(_ line: String) -> Date? {
        guard line.hasPrefix("[") else { return nil }
        let stamp = String(line.dropFirst().prefix(20))  // "2026-07-13 00:00:00Z"
        return utcFormatter.date(from: stamp)
    }

    private struct TimedLine: Sendable {
        let text: String
        let timestamp: Date?
    }

    private static func timedLines(_ lines: [String], timestamps: inout [String: Date]) -> [TimedLine] {
        var previous: Date?
        return lines.filter { !$0.isEmpty }.map { line in
            var date: Date?
            if line.hasPrefix("[") {
                let stamp = String(line.dropFirst().prefix(20))
                date = timestamps[stamp] ?? utcFormatter.date(from: stamp)
                if let date { timestamps[stamp] = date }
            }
            let timestamp = date ?? previous
            if timestamp != nil { previous = timestamp }
            return TimedLine(text: line, timestamp: timestamp)
        }
    }

    private static func merge(_ tails: [(name: String, lines: [TimedLine])], limit: Int) -> [MergedLogLine] {
        guard limit > 0 else { return [] }
        let collected = tails.flatMap { tail in tail.lines.map { (runner: tail.name, line: $0) } }
        let indexed = collected.enumerated().sorted { a, b in
            switch (a.element.line.timestamp, b.element.line.timestamp) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            case (nil, .some): return true
            case (.some, nil): return false
            case (nil, nil): return a.offset < b.offset
            }
        }
        return indexed.suffix(limit).enumerated().map { i, item in
            MergedLogLine(id: i, runner: item.element.runner, text: item.element.line.text,
                          timestamp: item.element.line.timestamp)
        }
    }

    /// One-off merge; repeated live reads use MergedTailCache instead.
    static func mergedTail(runners: [(name: String, directory: URL)],
                           perRunner: Int = 80, limit: Int = 500) -> [MergedLogLine] {
        guard perRunner > 0, limit > 0 else { return [] }
        var timestamps: [String: Date] = [:]
        let tails = runners.compactMap { runner -> (name: String, lines: [TimedLine])? in
            guard let log = newestLog(in: runner.directory, prefix: "Runner_") else { return nil }
            return (runner.name, timedLines(tail(log, maxLines: perRunner), timestamps: &timestamps))
        }
        return merge(tails, limit: limit)
    }

    actor MergedTailCache {
        private struct Source: Equatable {
            let name: String
            let directory: URL
            let file: LogFile?
        }
        private struct CachedTail {
            let file: LogFile
            let limit: Int
            let lines: [TimedLine]
        }
        private var tails: [URL: CachedTail] = [:]
        private var previousSources: [Source] = []
        private var previousLimits: (perRunner: Int, total: Int)?
        private var previousResult: [MergedLogLine] = []
        private let readTail: @Sendable (URL, Int) throws -> [String]

        init(readTail: @escaping @Sendable (URL, Int) throws -> [String] = { try LogTailer.tailSnapshot(at: $0, maxLines: $1).lines }) {
            self.readTail = readTail
        }

        func mergedTail(runners: [(name: String, directory: URL)],
                        perRunner: Int = 80, limit: Int = 500) -> [MergedLogLine] {
            guard perRunner > 0, limit > 0, !Task.isCancelled else { return [] }
            let sources = runners.map { Source(name: $0.name, directory: $0.directory,
                                               file: newestLogFile(in: $0.directory, prefix: "Runner_")) }
            if previousSources == sources, previousLimits?.perRunner == perRunner, previousLimits?.total == limit {
                return previousResult
            }
            var collected: [(name: String, lines: [TimedLine])] = []
            var timestamps: [String: Date] = [:]
            var cacheable = true
            for source in sources {
                guard let file = source.file else { continue }
                let lines: [TimedLine]
                if let cached = tails[file.url], cached.file == file, cached.limit == perRunner {
                    lines = cached.lines
                } else {
                    do {
                        lines = timedLines(try readTail(file.url, perRunner), timestamps: &timestamps)
                        tails[file.url] = CachedTail(file: file, limit: perRunner, lines: lines)
                    } catch {
                        tails[file.url] = nil
                        cacheable = false
                        continue
                    }
                }
                collected.append((source.name, lines))
            }
            let retained = Set(sources.compactMap { $0.file?.url })
            tails = tails.filter { retained.contains($0.key) }
            previousResult = merge(collected, limit: limit)
            previousSources = cacheable ? sources : []
            previousLimits = cacheable ? (perRunner, limit) : nil
            return previousResult
        }
    }

    /// Read just the requested bytes, keeping a growing listener log off the hot path.
    static func readLogRange(_ url: URL, offset: UInt64, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch { return nil }
    }

    /// Per-backend cache, isolated from the UI. Unchanged snapshots reuse their result;
    /// append-only logs parse new bytes, retaining incomplete lines until they finish.
    actor InsightCache {
        private struct CachedLog {
            var signature: LogSignature
            var events: [LogEvent] = []
            var pendingLine = Data()
            var lineNumber = 0
            var head = Data()
            var anchor = Data()
        }

        private struct CachedRunner {
            let files: [LogFile]
            let insights: RunnerLogInsights
        }

        private var logs: [URL: CachedLog] = [:]
        private var runners: [String: CachedRunner] = [:]
        private let readFile: @Sendable (URL, UInt64, Int) -> Data?

        init(readFile: @escaping @Sendable (URL, UInt64, Int) -> Data? = { LogTailer.readLogRange($0, offset: $1, count: $2) }) {
            self.readFile = readFile
        }

        func insights(for directories: [URL]) -> [String: RunnerLogInsights] {
            var result: [String: RunnerLogInsights] = [:]
            var retained: Set<URL> = []
            for directory in directories {
                guard !Task.isCancelled else { break }
                let files = insightLogs(in: directory)
                retained.formUnion(files.map(\.url))
                if let cached = runners[directory.path], cached.files == files {
                    result[directory.path] = cached.insights
                    continue
                }
                var events: [LogEvent] = []
                var cacheable = true
                for file in files {
                    let cached = logs[file.url]
                    let parsed: CachedLog?
                    if cached?.signature == file.signature {
                        parsed = cached
                    } else {
                        parsed = read(file, previous: cached)
                    }
                    logs[file.url] = parsed
                    if let parsed {
                        events.append(contentsOf: parsed.events)
                        events.append(contentsOf: logEvents(in: String(decoding: parsed.pendingLine, as: UTF8.self),
                                                           filename: file.url.lastPathComponent, firstLine: parsed.lineNumber))
                    } else {
                        cacheable = false
                    }
                }
                let insights = LogTailer.insights(from: events)
                result[directory.path] = insights
                runners[directory.path] = cacheable ? CachedRunner(files: files, insights: insights) : nil
            }
            logs = logs.filter { retained.contains($0.key) }
            let paths = Set(directories.map(\.path))
            runners = runners.filter { paths.contains($0.key) }
            return result
        }

        private func read(_ file: LogFile, previous: CachedLog?) -> CachedLog? {
            var parsed = CachedLog(signature: file.signature)
            var offset: UInt64 = 0
            if let previous, file.signature.canAppend(to: previous.signature) {
                let anchorOffset = previous.signature.size - UInt64(previous.anchor.count)
                guard let anchor = readFile(file.url, anchorOffset, previous.anchor.count) else { return nil }
                let head = anchorOffset == 0 ? Data(anchor.prefix(previous.head.count))
                    : readFile(file.url, 0, previous.head.count)
                if anchor == previous.anchor, head == previous.head {
                    parsed = previous
                    parsed.signature = file.signature
                    offset = previous.signature.size
                }
                // A changed checkpoint means rewrite or truncation followed by regrowth.
                // Replay instead of mixing old job events with new file contents.
            }
            while offset < file.signature.size {
                guard !Task.isCancelled else { return nil }
                let length = Int(min(256 * 1024, file.signature.size - offset))
                guard let data = readFile(file.url, offset, length), data.count == length else { return nil }
                if parsed.head.count < 256 {
                    parsed.head.append(data.prefix(256 - parsed.head.count))
                }
                parsed.anchor = Data((parsed.anchor + data).suffix(256))
                parsed.pendingLine.append(data)
                if let newline = parsed.pendingLine.lastIndex(of: 0x0A) {
                    let complete = parsed.pendingLine[...newline]
                    let text = String(decoding: complete, as: UTF8.self)
                    let events = parsedEvents(in: text, filename: file.url.lastPathComponent,
                                              firstLine: parsed.lineNumber)
                    parsed.events.append(contentsOf: events.events)
                    parsed.lineNumber = events.nextLine
                    parsed.pendingLine = Data(parsed.pendingLine.suffix(from: newline + 1))
                }
                offset += UInt64(length)
            }
            guard let current = LogSignature(file.url), current.inode == file.signature.inode,
                  current.created == file.signature.created, current.permissions == file.signature.permissions,
                  current.size >= file.signature.size,
                  current.size > file.signature.size || current.modified == file.signature.modified else { return nil }
            return parsed
        }
    }

    private struct LogEvent: Sendable {
        let id: String
        let message: String
        let timeString: String
        let date: Date?
    }

    private static func insightLogs(in runnerDir: URL) -> [LogFile] {
        let files = (try? logFiles(in: runnerDir, prefix: "Runner_")) ?? []
        return Array(files.sorted { older($1, than: $0) }.prefix(insightLogLimit).reversed())
    }

    /// Uncached entry point for one-off reads and comparison with cached polling.
    static func insights(for runnerDir: URL) -> RunnerLogInsights {
        let events = insightLogs(in: runnerDir).flatMap { file in
            readLossy(file.url).map { logEvents(in: $0, filename: file.url.lastPathComponent) } ?? []
        }
        return insights(from: events)
    }

    private static func logEvents(in content: String, filename: String, firstLine: Int = 0) -> [LogEvent] {
        parsedEvents(in: content, filename: filename, firstLine: firstLine).events
    }

    private static func parsedEvents(in content: String, filename: String,
                                     firstLine: Int) -> (events: [LogEvent], nextLine: Int) {
        let normalized = content.utf8.contains(0x0D)
            ? content.replacingOccurrences(of: "\r\n", with: "\n") : content
        let lines = normalized.split(separator: "\n")
        let events = lines.enumerated().compactMap { lineNumber, rawLine -> LogEvent? in
            guard let range = rawLine.range(of: "WRITE LINE: ", options: .literal) else { return nil }
            let payload = rawLine[range.upperBound...]
            guard let separator = payload.range(of: ": ", options: .literal) else { return nil }
            let timeString = String(payload[..<separator.lowerBound])
            let message = String(payload[separator.upperBound...])
            let isJobEvent = message.hasPrefix("Running job: ") || message.hasPrefix("Job ")
            return LogEvent(id: "\(filename):\(firstLine + lineNumber)", message: message,
                            timeString: timeString, date: isJobEvent ? utcFormatter.date(from: timeString) : nil)
        }
        return (events, firstLine + lines.count)
    }

    private static func insights(from events: [LogEvent]) -> RunnerLogInsights {
        var history: [JobRecord] = []
        var openJob: String?
        var lastMeaningfulLine: String?
        for event in events {
            let message = event.message
            lastMeaningfulLine = message
            if let name = value(after: "Running job: ", in: message) {
                openJob = name
                history.append(JobRecord(id: event.id, name: name, result: .running,
                                         timestamp: event.date, rawTime: event.timeString,
                                         startTimestamp: event.date))
            } else if message.hasPrefix("Job "),
                      let range = message.range(of: " completed with result: ", options: .literal) {
                let name = String(message[message.index(message.startIndex, offsetBy: 4)..<range.lowerBound])
                let resultText = String(message[range.upperBound...])
                if let index = history.lastIndex(where: { $0.name == name && $0.result == .running }) {
                    history[index].result = JobRecord.JobResult(resultText)
                    if let start = history[index].timestamp, let end = event.date {
                        history[index].duration = end.timeIntervalSince(start)
                    }
                    history[index].timestamp = event.date ?? history[index].timestamp
                } else {
                    history.append(JobRecord(id: event.id, name: name, result: JobRecord.JobResult(resultText),
                                             timestamp: event.date, rawTime: event.timeString))
                }
                if openJob == name { openJob = nil }
            } else if message.contains("Listening for Jobs") {
                openJob = nil
            }
        }
        return RunnerLogInsights(currentJob: openJob, history: history.reversed(), lastLine: lastMeaningfulLine)
    }

    private static func value(after prefix: String, in message: String) -> String? {
        guard message.hasPrefix(prefix) else { return nil }
        return String(message.dropFirst(prefix.count))
    }

    // MARK: - Per-job Worker logs & GitHub run linking

    /// The `Worker_*.log` for a job — the one created nearest the job's start time.
    /// Jobs run sequentially on one runner, so nearest-time matching is reliable.
    static func workerLog(for job: JobRecord, in runnerDir: URL) -> URL? {
        guard let start = job.startTimestamp ?? job.timestamp else { return nil }
        var best: (url: URL, delta: TimeInterval)?
        for url in (try? matchingLogs(in: runnerDir, prefix: "Worker_")) ?? [] {
            guard let ts = workerFileTimestamp(url) else { continue }
            let delta = abs(ts.timeIntervalSince(start))
            if best == nil || delta < best!.delta { best = (url, delta) }
        }
        // Only trust a reasonably close match.
        if let best, best.delta <= 120 { return best.url }
        return nil
    }

    /// Parse the UTC start time encoded in a Worker log filename
    /// ("Worker_20260713-061804-utc.log" -> 2026-07-13 06:18:04Z).
    static func workerFileTimestamp(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent      // Worker_20260713-061804-utc
        let parts = name.split(separator: "_")
        guard parts.count >= 2 else { return nil }
        let stamp = parts[1].replacingOccurrences(of: "-utc", with: "") // 20260713-061804
        return workerFormatter.date(from: stamp)
    }

    /// Extract the repository and GitHub Actions `run_id` from a Worker log's
    /// job message. Both are needed to address the workflow run via GitHub.
    static func workflowRunReference(fromWorkerLog url: URL) -> WorkflowRunReference? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: handle.readData(ofLength: 300_000), as: UTF8.self)
        return workflowRunReference(inWorkerText: text)
    }

    /// Testable core of `workflowRunReference(fromWorkerLog:)`.
    static func workflowRunReference(inWorkerText text: String) -> WorkflowRunReference? {
        guard let repository = jobMessageValue(for: "repository", in: text),
              case .repo = GHTarget.parseManual(repository),
              let runID = runID(inWorkerText: text) else { return nil }
        return WorkflowRunReference(repository: repository, runID: runID)
    }

    /// Extract the GitHub Actions `run_id` from a Worker log's job message
    /// (a `"k": "run_id"` / `"v": "<digits>"` pair near the top of the file).
    static func runID(fromWorkerLog url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: handle.readData(ofLength: 300_000), as: UTF8.self)
        return runID(inWorkerText: text)
    }

    /// Testable core of `runID(fromWorkerLog:)`.
    static func runID(inWorkerText text: String) -> String? {
        guard let value = jobMessageValue(for: "run_id", in: text) else { return nil }
        return (!value.isEmpty && value.allSatisfy(\.isNumber)) ? value : nil
    }

    /// Pull a `"k": "<key>"` / `"v": "<value>"` pair from the runner's
    /// serialized job-message properties.
    private static func jobMessageValue(for key: String, in text: String) -> String? {
        guard let k = text.range(of: "\"\(key)\"") else { return nil }
        let after = text[k.upperBound...]
        guard let v = after.range(of: "\"v\"") else { return nil }
        let rest = after[v.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        let valueStart = rest.index(after: open)
        guard let close = rest[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(rest[valueStart..<close])
    }
}
