import Foundation
import Darwin
import RunnerAgentProtocol

enum RunnerAgentDiscovery {
    private static let maximumResults = 200
    private static let skippedDirectoryNames: Set<String> = [
        "Library", "Applications", "node_modules", "DerivedData", ".build"
    ]

    static func discover() -> [RunnerAgentRunnerRecord] {
        let userID = geteuid()
        let home = accountHomeDirectory(userID: userID)
        let explicitRoots = [
            home.appendingPathComponent("actions-runner", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/RunnerMenu/Runners", isDirectory: true)
        ]
        return discover(in: [home], explicitDirectories: explicitRoots, ownerUserID: userID)
    }

    static func discover(
        in roots: [URL],
        explicitDirectories: [URL] = [],
        ownerUserID: uid_t,
        maximumDepth: Int = 5
    ) -> [RunnerAgentRunnerRecord] {
        let fileManager = FileManager.default
        let searchRoots = roots.map(\.standardizedFileURL)
        var found: [String: RunnerAgentRunnerRecord] = [:]

        @discardableResult
        func addIfRunner(_ candidate: URL, trustedRoot: URL) -> Bool {
            guard found.count < maximumResults else { return false }
            let directory = candidate.standardizedFileURL
            guard !containsSymbolicLink(below: trustedRoot, in: directory),
                  ownsDirectory(directory, userID: ownerUserID),
                  fileManager.fileExists(atPath: directory.appendingPathComponent("run.sh").path),
                  fileManager.fileExists(atPath: directory.appendingPathComponent("config.sh").path)
            else { return false }

            let config = loadConfig(directory.appendingPathComponent(".runner"))
            let record = RunnerAgentRunnerRecord(
                id: directory.path,
                directoryPath: directory.path,
                displayName: config?.agentName ?? directory.lastPathComponent,
                scopeLabel: config.flatMap { scopeLabel(from: $0.gitHubUrl) },
                configured: config != nil,
                ownerUserID: UInt32(ownerUserID)
            )
            found[record.id] = record
            return true
        }

        for directory in explicitDirectories {
            guard let trustedRoot = searchRoots.first(where: { contains(directory, within: $0) }) else {
                continue
            }
            _ = addIfRunner(directory, trustedRoot: trustedRoot)
        }

        for root in searchRoots where found.count < maximumResults {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            if addIfRunner(root, trustedRoot: root) { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                if found.count >= maximumResults { enumerator.skipDescendants(); break }
                let depth = enumerator.level
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true else { continue }
                if values?.isSymbolicLink == true
                    || skippedDirectoryNames.contains(url.lastPathComponent)
                    || depth > maximumDepth {
                    enumerator.skipDescendants()
                    continue
                }
                if addIfRunner(url, trustedRoot: root) || depth == maximumDepth {
                    enumerator.skipDescendants()
                }
            }
        }

        return found.values.sorted {
            $0.directoryPath.localizedStandardCompare($1.directoryPath) == .orderedAscending
        }
    }

    private static func accountHomeDirectory(userID: uid_t) -> URL {
        guard let record = getpwuid(userID), let path = record.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func ownsDirectory(_ directory: URL, userID: uid_t) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
              let owner = attributes[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == UInt32(userID)
    }

    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func containsSymbolicLink(below root: URL, in candidate: URL) -> Bool {
        let root = root.standardizedFileURL
        let candidate = candidate.standardizedFileURL
        guard contains(candidate, within: root) else { return true }
        guard candidate.path != root.path else { return false }

        let relativePath = candidate.path.dropFirst(root.path.count)
        var component = root
        for name in relativePath.split(separator: "/") {
            component.appendPathComponent(String(name))
            let values = try? component.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true { return true }
        }
        return false
    }

    private struct MinimalConfig: Decodable {
        let agentName: String
        let gitHubUrl: String
    }

    private static func loadConfig(_ url: URL) -> MinimalConfig? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 64 * 1024 else { return nil }
        guard var data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        return try? JSONDecoder().decode(MinimalConfig.self, from: data)
    }

    private static func scopeLabel(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0].lowercased() != "enterprises" {
            return "\(parts[0])/\(parts[1])"
        }
        if parts.count == 1 { return "\(parts[0]) (org)" }
        if parts.count >= 2, parts[0].lowercased() == "enterprises" {
            return "\(parts[1]) (enterprise)"
        }
        return nil
    }
}
