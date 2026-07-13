import Foundation

/// Result of running a subprocess.
struct ShellResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }

    /// stdout trimmed of surrounding whitespace/newlines.
    var out: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum ShellError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(command: String, code: Int32, stderr: String)
    case executableNotFound(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg):
            return "Failed to launch process: \(msg)"
        case .nonZeroExit(let command, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` exited with code \(code)\(detail.isEmpty ? "" : ":\n\(detail)")"
        case .executableNotFound(let name):
            return "Could not find `\(name)` on the PATH."
        }
    }
}

/// A small async wrapper around `Process`. All work happens off the main thread.
enum Shell {

    /// A reasonably complete PATH so tools installed by Homebrew / the runner are found
    /// even though a GUI-launched app inherits a minimal environment.
    static let augmentedPath: String = {
        let extra = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(NSHomeDirectory())/.local/bin"
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var parts = existing.split(separator: ":").map(String.init)
        for p in extra where !parts.contains(p) { parts.append(p) }
        return parts.joined(separator: ":")
    }()

    /// Resolve an executable name to an absolute path using the augmented PATH.
    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in augmentedPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run `executable args…`. Does not throw on non-zero exit — inspect `ShellResult.exitCode`.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: URL? = nil,
        extraEnv: [String: String] = [:]
    ) async throws -> ShellResult {
        guard let launchPath = which(executable) else {
            throw ShellError.executableNotFound(executable)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Run the whole blocking dance off the calling thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = augmentedPath
                for (k, v) in extraEnv { env[k] = v }
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ShellError.launchFailed(error.localizedDescription))
                    return
                }

                // Drain both pipes to EOF concurrently so a full 64 KB pipe buffer on
                // one stream can never deadlock the other (gh output can be large).
                let group = DispatchGroup()
                let outBox = LockedData()
                let errBox = LockedData()
                group.enter()
                DispatchQueue.global().async {
                    outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }

                process.waitUntilExit()
                group.wait()

                let result = ShellResult(
                    stdout: outBox.string,
                    stderr: errBox.string,
                    exitCode: process.terminationStatus
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Convenience that throws on non-zero exit.
    @discardableResult
    static func runChecked(
        _ executable: String,
        _ arguments: [String] = [],
        cwd: URL? = nil,
        extraEnv: [String: String] = [:]
    ) async throws -> ShellResult {
        let result = try await run(executable, arguments, cwd: cwd, extraEnv: extraEnv)
        guard result.succeeded else {
            let cmd = ([executable] + arguments).joined(separator: " ")
            throw ShellError.nonZeroExit(command: cmd, code: result.exitCode, stderr: result.stderr)
        }
        return result
    }
}

/// Thread-safe accumulator for pipe data read from a background queue.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(d)
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
