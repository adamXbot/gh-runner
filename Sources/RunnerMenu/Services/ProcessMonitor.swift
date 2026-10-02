import Foundation

/// Point-in-time resource info for a runner process.
struct ProcInfo: Equatable, Sendable {
    var pid: Int32
    var cpuPercent: Double
    var memoryMB: Double
    var etime: String
}

/// A single scan of running runner-related processes, keyed by runner directory.
struct ProcessScan: Sendable {
    /// Runner directory path -> the `Runner.Listener` process for it.
    var listeners: [String: ProcInfo] = [:]
    /// Runner directory paths that currently have a `Runner.Worker` (a job is executing).
    var busyDirectories: Set<String> = []

    /// Every runner directory visible in the current process snapshot.
    var runnerDirectories: [URL] {
        Set(listeners.keys).union(busyDirectories)
            .sorted()
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func listener(for directory: URL) -> ProcInfo? {
        listeners[ProcessMonitor.normalize(directory.path)]
    }
    func isBusy(_ directory: URL) -> Bool {
        busyDirectories.contains(ProcessMonitor.normalize(directory.path))
    }
}

/// Reads process state from `ps`. We map a process to its runner directory using
/// the executable's absolute path (`<dir>/bin/Runner.Listener`), which avoids
/// needing `lsof` or elevated permissions.
enum ProcessMonitor {

    private static let listenerMarker = "/bin/Runner.Listener"
    private static let workerMarker = "/bin/Runner.Worker"

    /// Canonical key for a directory path: resolves symlinks and `.`/`..` so the
    /// process-side path and the app-side path always compare equal.
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func scan() async -> ProcessScan {
        guard let result = try? await Shell.run(
            "ps", ["-axww", "-o", "pid=,pcpu=,rss=,etime=,comm="]
        ), result.succeeded else {
            return ProcessScan()
        }
        return parseSnapshot(result.stdout)
    }

    /// Parse executable paths, without copying unrelated processes' argument lists.
    static func parseSnapshot(_ output: String) -> ProcessScan {
        var scan = ProcessScan()
        for rawLine in output.split(separator: "\n") {
            guard rawLine.hasSuffix(listenerMarker) || rawLine.hasSuffix(workerMarker) else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Split into 4 leading fields (pid, cpu, rss, etime) + the command remainder.
            let fields = splitLeadingFields(line, count: 4)
            guard fields.leading.count == 4, let pid = Int32(fields.leading[0]), pid > 0 else { continue }
            let command = fields.remainder

            if let dir = directory(from: command, marker: listenerMarker) {
                let cpu = Double(fields.leading[1]) ?? 0
                let rssKB = Double(fields.leading[2]) ?? 0
                let info = ProcInfo(pid: pid, cpuPercent: cpu, memoryMB: rssKB / 1024.0, etime: fields.leading[3])
                scan.listeners[normalize(dir)] = info
            } else if let dir = directory(from: command, marker: workerMarker) {
                scan.busyDirectories.insert(normalize(dir))
            }
        }
        return scan
    }

    /// `ps comm` provides the executable path, rather than its arguments.
    private static func directory(from command: String, marker: String) -> String? {
        guard command.hasPrefix("/"), command.hasSuffix(marker),
              let range = command.range(of: marker, options: [.literal, .backwards]) else { return nil }
        let dir = String(command[command.startIndex..<range.lowerBound])
        return dir.isEmpty ? nil : dir
    }

    /// Split `line` into `count` whitespace-delimited leading tokens plus the rest.
    private static func splitLeadingFields(_ line: String, count: Int) -> (leading: [String], remainder: String) {
        var leading: [String] = []
        var idx = line.startIndex
        let end = line.endIndex

        func skipSpaces() {
            while idx < end, line[idx].isWhitespace { idx = line.index(after: idx) }
        }

        for _ in 0..<count {
            skipSpaces()
            guard idx < end else { break }
            let start = idx
            while idx < end, !line[idx].isWhitespace { idx = line.index(after: idx) }
            leading.append(String(line[start..<idx]))
        }
        skipSpaces()
        return (leading, String(line[idx..<end]))
    }
}
