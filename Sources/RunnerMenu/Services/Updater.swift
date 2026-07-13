import Foundation
import CryptoKit

/// Information about an available (or current) runner version.
struct UpdateInfo: Equatable, Sendable {
    var currentVersion: String?
    var latest: GHRelease
    var asset: GHRelease.Asset
    var expectedSHA256: String?
    var updateAvailable: Bool

    var latestVersion: String { latest.version }
    var hasVerifiableHash: Bool { expectedSHA256 != nil }
}

enum UpdateError: LocalizedError {
    case noMatchingAsset(arch: String)
    case downloadFailed(String)
    case hashMismatch(expected: String, actual: String)
    case hashUnavailable
    case extractionFailed(String)
    case runnerBusy

    var errorDescription: String? {
        switch self {
        case .noMatchingAsset(let arch):
            return "The latest release has no macOS \(arch) package."
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .hashMismatch(let expected, let actual):
            return "SHA-256 verification failed.\nExpected: \(expected)\nActual:   \(actual)\nThe download was discarded."
        case .hashUnavailable:
            return "Could not find a published SHA-256 for this package, so it can't be verified. Update aborted."
        case .extractionFailed(let msg):
            return "Extracting the package failed: \(msg)"
        case .runnerBusy:
            return "The runner is currently executing a job. Stop it (or wait) before updating."
        }
    }
}

/// Checks for, downloads, verifies, and installs runner updates.
struct Updater: Sendable {
    var github: GitHubClient

    /// The macOS architecture slug used in the runner asset names.
    static var archSlug: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    func checkForUpdate(_ instance: RunnerInstance) async throws -> UpdateInfo {
        let release = try await github.latestRunnerRelease()
        let arch = Self.archSlug
        guard let asset = release.assets.first(where: {
            $0.name.contains("osx-\(arch)") && $0.name.hasSuffix(".tar.gz")
        }) else {
            throw UpdateError.noMatchingAsset(arch: arch)
        }
        let expectedHash = Self.parseSHA256(for: asset.name, in: release.body)
        let current = instance.installedVersion
        let available = Self.isNewer(release.version, than: current)
        return UpdateInfo(
            currentVersion: current,
            latest: release,
            asset: asset,
            expectedSHA256: expectedHash,
            updateAvailable: available
        )
    }

    /// Download the asset, verifying its SHA-256 against the published value.
    /// Returns the path to the verified tarball in a temp location.
    func downloadVerifiedPackage(
        _ info: UpdateInfo,
        allowUnverified: Bool = false,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let expected = info.expectedSHA256 else {
            if allowUnverified {
                return try await download(info.asset, progress: progress)
            }
            throw UpdateError.hashUnavailable
        }
        let fileURL = try await download(info.asset, progress: progress)
        let actual = try Self.sha256Hex(of: fileURL)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            try? FileManager.default.removeItem(at: fileURL)
            throw UpdateError.hashMismatch(expected: expected, actual: actual)
        }
        return fileURL
    }

    /// Extract the tarball over the runner directory. The runner MUST be stopped.
    func extractPackage(at tarball: URL, into runnerDir: URL) async throws {
        let result = try await Shell.run("tar", ["xzf", tarball.path, "-C", runnerDir.path])
        guard result.succeeded else {
            throw UpdateError.extractionFailed(result.stderr)
        }
        try? FileManager.default.removeItem(at: tarball)
    }

    // MARK: - Download

    private func download(
        _ asset: GHRelease.Asset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let url = URL(string: asset.browserDownloadUrl) else {
            throw UpdateError.downloadFailed("Invalid asset URL")
        }
        var request = URLRequest(url: url)
        request.setValue("RunnerMenu", forHTTPHeaderField: "User-Agent")

        // A URLSession download task streams to disk in chunks (efficient) and the
        // delegate reports progress — far cheaper than iterating AsyncBytes per byte.
        let delegate = DownloadProgressDelegate(expectedSize: Int64(asset.size), progress: progress)
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
        }

        // The system deletes `tempURL` when we return; move it to our own temp path.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("runnermenu-\(UUID().uuidString)-\(asset.name)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            throw UpdateError.downloadFailed("Could not save download: \(error.localizedDescription)")
        }
        progress(1.0)
        return dest
    }

    // MARK: - Hashing & parsing

    static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Find a 64-hex SHA-256 associated with `assetName` in a release body.
    static func parseSHA256(for assetName: String, in body: String?) -> String? {
        guard let body else { return nil }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() {
            guard line.contains(assetName) else { continue }
            // Search this line and the next couple for a 64-hex token.
            for j in i..<min(i + 3, lines.count) {
                if let hash = firstHex64(in: lines[j]) { return hash }
            }
        }
        return nil
    }

    private static func firstHex64(in text: String) -> String? {
        let chars = Array(text)
        var run = 0
        var start = 0
        for (i, c) in chars.enumerated() {
            if c.isHexDigit {
                if run == 0 { start = i }
                run += 1
                if run == 64 {
                    // Ensure it isn't part of a longer hex run.
                    let nextIsHex = (i + 1 < chars.count) && chars[i + 1].isHexDigit
                    if !nextIsHex { return String(chars[start...i]) }
                }
            } else {
                run = 0
            }
        }
        return nil
    }

    /// Human-readable byte size, deterministic and locale-independent ("512 B", "1.5 KB", "65.0 MB").
    static func humanByteSize(_ bytes: Int) -> String {
        let b = max(0, bytes)
        if b < 1024 { return "\(b) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(b) / 1024
        var i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10) \(units[i])"
    }

    /// Semantic-ish "is `candidate` newer than `current`" using dotted integer parts.
    static func isNewer(_ candidate: String, than current: String?) -> Bool {
        guard let current, !current.isEmpty else { return true }
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(a.count, b.count)
        for i in 0..<n {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }
}

/// Reports download progress for a `URLSession` download task.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedSize: Int64
    private let progress: @Sendable (Double) -> Void

    init(expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(expectedSize)
        guard total > 0 else { return }
        progress(min(1.0, Double(totalBytesWritten) / total))
    }

    // Required by the protocol. The async `download(for:)` returns the file itself,
    // so this is a no-op.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
