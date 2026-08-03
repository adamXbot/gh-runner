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

    /// Newest log file with the given prefix (e.g. "Runner_", "Worker_").
    static func newestLog(in runnerDir: URL, prefix: String) -> URL? {
        logFiles(in: runnerDir, prefix: prefix).first
    }

    /// Matching log files, newest first. Modification time is authoritative because
    /// the active runner log continues to change after its timestamped filename is set.
    private static func logFiles(in runnerDir: URL, prefix: String) -> [URL] {
        let diag = diagDirectory(for: runnerDir)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: diag, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if da != db { return da > db }
                return a.lastPathComponent > b.lastPathComponent
            }
    }

    /// Read a log file, tolerating non-UTF-8 bytes (job stdout often isn't clean UTF-8).
    /// A single invalid byte must not blank the whole log — invalid bytes become U+FFFD.
    static func readLossy(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Last `maxLines` lines of a file (whole-file read; runner logs are small).
    static func tail(_ url: URL, maxLines: Int = 200) -> [String] {
        guard let content = readLossy(url) else { return [] }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(lines.suffix(maxLines))
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

    /// Merge the recent Runner-log tails of several runners into one time-ordered stream,
    /// each line tagged with its runner. Used by the dashboard's combined log view.
    static func mergedTail(runners: [(name: String, directory: URL)],
                           perRunner: Int = 80, limit: Int = 500) -> [MergedLogLine] {
        var collected: [(runner: String, text: String, ts: Date?)] = []
        for runner in runners {
            guard let log = newestLog(in: runner.directory, prefix: "Runner_") else { continue }
            var lastTs: Date?
            for line in tail(log, maxLines: perRunner) where !line.isEmpty {
                let ts = leadingTimestamp(line) ?? lastTs
                if ts != nil { lastTs = ts }
                collected.append((runner.name, line, ts))
            }
        }
        // Stable sort by timestamp; index tiebreak keeps same-time lines in order.
        let indexed = collected.enumerated().sorted { a, b in
            switch (a.element.ts, b.element.ts) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            case (nil, .some): return true
            case (.some, nil): return false
            case (nil, nil): return a.offset < b.offset
            }
        }
        return indexed.suffix(limit).enumerated().map { i, item in
            MergedLogLine(id: i, runner: item.element.runner, text: item.element.text, timestamp: item.element.ts)
        }
    }

    /// Parse job start/completion events across recent Runner log rotations.
    static func insights(for runnerDir: URL) -> RunnerLogInsights {
        // Parse oldest-to-newest so completion and "Listening for Jobs" events can
        // settle state opened in an earlier file. The result is reversed for display.
        let logURLs = Array(logFiles(in: runnerDir, prefix: "Runner_")
            .prefix(insightLogLimit)
            .reversed())
        guard !logURLs.isEmpty else {
            return RunnerLogInsights(currentJob: nil, history: [], lastLine: nil)
        }

        var history: [JobRecord] = []
        var openJob: String?
        var lastMeaningfulLine: String?

        for logURL in logURLs {
            guard let content = readLossy(logURL) else { continue }
            for (lineNumber, rawLine) in content.split(separator: "\n").enumerated() {
                guard let range = rawLine.range(of: "WRITE LINE: ") else { continue }
                let payload = String(rawLine[range.upperBound...])
                // payload == "<timestamp>Z: <message>"
                guard let sepRange = payload.range(of: ": ") else { continue }
                let timeString = String(payload[payload.startIndex..<sepRange.lowerBound])
                let message = String(payload[sepRange.upperBound...])
                lastMeaningfulLine = message
                let date = utcFormatter.date(from: timeString)
                let recordID = "\(logURL.lastPathComponent):\(lineNumber)"

                if let name = value(after: "Running job: ", in: message) {
                    openJob = name
                    history.append(JobRecord(id: recordID, name: name, result: .running,
                                             timestamp: date, rawTime: timeString,
                                             startTimestamp: date))
                } else if message.hasPrefix("Job "), let resultRange = message.range(of: " completed with result: ") {
                    let name = String(message[message.index(message.startIndex, offsetBy: 4)..<resultRange.lowerBound])
                    let resultText = String(message[resultRange.upperBound...])
                    // Close out the matching open record if present.
                    if let idx = history.lastIndex(where: { $0.name == name && $0.result == .running }) {
                        history[idx].result = JobRecord.JobResult(resultText)
                        // Compute duration from the recorded start BEFORE overwriting it.
                        if let start = history[idx].timestamp, let end = date {
                            history[idx].duration = end.timeIntervalSince(start)
                        }
                        history[idx].timestamp = date ?? history[idx].timestamp
                    } else {
                        history.append(JobRecord(id: recordID, name: name,
                                                 result: JobRecord.JobResult(resultText),
                                                 timestamp: date, rawTime: timeString))
                    }
                    if openJob == name { openJob = nil }
                } else if message.contains("Listening for Jobs") {
                    openJob = nil
                }
            }
        }

        return RunnerLogInsights(
            currentJob: openJob,
            history: history.reversed(),
            lastLine: lastMeaningfulLine
        )
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
        for url in logFiles(in: runnerDir, prefix: "Worker_") {
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: stamp)
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
