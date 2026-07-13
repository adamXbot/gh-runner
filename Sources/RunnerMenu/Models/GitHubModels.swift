import Foundation

/// A repository as returned by the GitHub REST API (subset we use).
struct GHRepo: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let fullName: String
    let name: String
    let isPrivate: Bool
    let htmlUrl: String
    let permissions: Permissions?
    let owner: Owner

    struct Permissions: Codable, Equatable, Sendable {
        let admin: Bool?
    }
    struct Owner: Codable, Equatable, Sendable {
        let login: String
        let type: String
    }

    enum CodingKeys: String, CodingKey {
        case id, name, permissions, owner
        case fullName = "full_name"
        case isPrivate = "private"
        case htmlUrl = "html_url"
    }

    var isAdmin: Bool { permissions?.admin ?? false }
    var ownerLogin: String { owner.login }
}

/// Registration / removal token for configuring a runner.
struct GHRunnerToken: Codable, Equatable, Sendable {
    let token: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }

    var expiryDate: Date? {
        ISO8601DateFormatter().date(from: expiresAt)
    }
}

/// A GitHub release (used for runner update checks).
struct GHRelease: Codable, Equatable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let publishedAt: String?
    let assets: [Asset]

    struct Asset: Codable, Equatable, Sendable {
        let name: String
        let browserDownloadUrl: String
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadUrl = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, body, assets
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
    }

    /// Version without the leading `v` (e.g. "2.335.1").
    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    /// When the release was published, parsed from the ISO-8601 `published_at`.
    var publishedDate: Date? {
        guard let publishedAt else { return nil }
        return ISO8601DateFormatter().date(from: publishedAt)
    }
}

/// A self-hosted runner as reported by the GitHub API (when we have admin).
struct GHRunner: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let os: String
    let status: String     // "online" | "offline"
    let busy: Bool
    let labels: [Label]

    struct Label: Codable, Equatable, Sendable {
        let name: String
    }

    var labelNames: [String] { labels.map(\.name) }
}

/// A runner label with its editability (default labels are read-only).
struct RunnerLabel: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let type: String    // "read-only" (default) | "custom"

    var id: String { name }
    var isCustom: Bool { type == "custom" }
}

/// Response of the runner-labels endpoint.
struct RunnerLabelsResponse: Codable, Equatable, Sendable {
    let totalCount: Int
    let labels: [RunnerLabel]

    enum CodingKeys: String, CodingKey {
        case labels
        case totalCount = "total_count"
    }
}
