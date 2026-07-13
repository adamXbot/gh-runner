import Foundation

/// The persisted configuration of a self-hosted runner, read from the `.runner`
/// file that `config.sh` writes into the runner directory.
struct RunnerConfig: Codable, Equatable, Sendable {
    var agentId: Int
    var agentName: String
    var poolId: Int?
    var poolName: String?
    var serverUrl: String?
    var gitHubUrl: String
    var workFolder: String?

    enum CodingKeys: String, CodingKey {
        case agentId, agentName, poolId, poolName, serverUrl, gitHubUrl, workFolder
    }

    /// The scope of a registration derived from the configured GitHub URL.
    enum Scope: Equatable, Sendable {
        case repo(owner: String, name: String)
        case org(String)
        case enterprise(String)
        case unknown

        var displayString: String {
            switch self {
            case .repo(let owner, let name): return "\(owner)/\(name)"
            case .org(let org): return "\(org) (org)"
            case .enterprise(let ent): return "\(ent) (enterprise)"
            case .unknown: return "Unknown"
            }
        }
    }

    var scope: Scope { Self.scope(from: gitHubUrl) }

    /// `owner/repo` when this runner is bound to a single repository.
    var repoSlug: String? {
        if case let .repo(owner, name) = scope { return "\(owner)/\(name)" }
        return nil
    }

    /// A best-effort parse of the GitHub URL into a scope.
    static func scope(from urlString: String) -> Scope {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else { return .unknown }
        // Path components excluding the leading "/".
        let parts = url.path.split(separator: "/").map(String.init)
        switch parts.count {
        case 2:
            if parts[0].lowercased() == "enterprises" { return .enterprise(parts[1]) }
            return .repo(owner: parts[0], name: parts[1])
        case 1:
            return .org(parts[0])
        default:
            if parts.count >= 2 && parts[0].lowercased() == "enterprises" {
                return .enterprise(parts[1])
            }
            return .unknown
        }
    }

    /// Load `.runner` from a runner directory. The file may carry a UTF-8 BOM.
    static func load(from directory: URL) -> RunnerConfig? {
        let fileURL = directory.appendingPathComponent(".runner")
        guard var data = try? Data(contentsOf: fileURL) else { return nil }
        // Strip a UTF-8 byte-order mark if present (GitHub writes one).
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if data.count >= 3 && Array(data.prefix(3)) == bom {
            data.removeFirst(3)
        }
        return try? JSONDecoder().decode(RunnerConfig.self, from: data)
    }
}
