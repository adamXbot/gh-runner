import Foundation

/// Finds existing GitHub Actions runner installations without traversing the
/// whole disk. Discovery is deliberately read-only and never follows symlinks.
enum RunnerDiscovery {
    private static let skippedDirectoryNames: Set<String> = [
        "Library", "Applications", "node_modules", "DerivedData", ".build"
    ]

    /// Search useful locations for the interactive account and include runner
    /// paths already visible in the process table or saved by the app.
    static func discoverDefault(explicitDirectories: [URL] = []) async -> [RunnerInstance] {
        let processScan = await ProcessMonitor.scan()
        let activeDirectories = processScan.runnerDirectories
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
        ]

        return await Task.detached(priority: .utility) {
            discover(
                in: roots,
                explicitDirectories: explicitDirectories + activeDirectories,
                maximumDepth: 5
            )
        }.value
    }

    /// Synchronous core kept separate so the bounded traversal can be tested
    /// against temporary directories.
    static func discover(
        in roots: [URL],
        explicitDirectories: [URL] = [],
        maximumDepth: Int = 5
    ) -> [RunnerInstance] {
        let fileManager = FileManager.default
        var found: [String: RunnerInstance] = [:]

        @discardableResult
        func addIfRunner(_ candidate: URL) -> Bool {
            let directory = candidate.standardizedFileURL
            let instance = RunnerInstance(
                directory: directory,
                config: RunnerConfig.load(from: directory)
            )
            guard instance.looksLikeRunnerDirectory else { return false }
            found[instance.id] = instance
            return true
        }

        explicitDirectories.forEach { _ = addIfRunner($0) }

        for rawRoot in roots {
            let root = rawRoot.standardizedFileURL
            guard fileManager.fileExists(atPath: root.path) else { continue }
            if addIfRunner(root) { continue }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                // Use the enumerator's own level rather than subtracting URL path
                // components. macOS aliases /var to /private/var, which otherwise
                // makes identical locations appear to have different depths.
                let depth = enumerator.level
                guard depth > 0 else { continue }

                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true else { continue }

                if values?.isSymbolicLink == true
                    || skippedDirectoryNames.contains(url.lastPathComponent)
                    || depth > maximumDepth {
                    enumerator.skipDescendants()
                    continue
                }

                if addIfRunner(url) {
                    // Runner work directories can be very large and cannot contain
                    // another supported installation for this discovery pass.
                    enumerator.skipDescendants()
                } else if depth == maximumDepth {
                    enumerator.skipDescendants()
                }
            }
        }

        return found.values.sorted {
            $0.directory.path.localizedStandardCompare($1.directory.path) == .orderedAscending
        }
    }
}
