import Foundation

/// The GitHub target a runner can be registered against.
enum GHTarget: Equatable, Sendable {
    case repo(owner: String, name: String)
    case org(String)

    var apiBase: String {
        switch self {
        case .repo(let owner, let name): return "repos/\(owner)/\(name)"
        case .org(let org): return "orgs/\(org)"
        }
    }
    var registrationTokenPath: String { "\(apiBase)/actions/runners/registration-token" }
    var removeTokenPath: String { "\(apiBase)/actions/runners/remove-token" }
    var runnersPath: String { "\(apiBase)/actions/runners" }
    func runnerLabelsPath(id: Int) -> String { "\(apiBase)/actions/runners/\(id)/labels" }

    var webURLString: String {
        switch self {
        case .repo(let owner, let name): return "https://github.com/\(owner)/\(name)"
        case .org(let org): return "https://github.com/\(org)"
        }
    }

    var displayString: String {
        switch self {
        case .repo(let owner, let name): return "\(owner)/\(name)"
        case .org(let org): return "\(org)"
        }
    }

    /// Build a target from a runner's configured scope, if it is repo/org.
    init?(scope: RunnerConfig.Scope) {
        switch scope {
        case .repo(let owner, let name): self = .repo(owner: owner, name: name)
        case .org(let org): self = .org(org)
        default: return nil
        }
    }

    /// Parse the target syntax accepted by the registration form.
    /// Supports `owner/repo`, an organization name, or an HTTPS github.com URL.
    static func parseManual(_ input: String) -> GHTarget? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.contains("://") {
            return GHTarget(scope: RunnerConfig.scope(from: value))
        }

        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy(isValidComponent) else { return nil }
        switch parts.count {
        case 1: return .org(parts[0])
        case 2: return .repo(owner: parts[0], name: parts[1])
        default: return nil
        }
    }

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && value.rangeOfCharacter(from: CharacterSet(charactersIn: "?#")) == nil
    }
}

/// Authentication summary for the `gh` CLI.
struct GHAuthStatus: Equatable, Sendable {
    var available: Bool
    var authenticated: Bool
    var account: String?
    var scopes: [String]
    var message: String?

    static let unknown = GHAuthStatus(available: false, authenticated: false, account: nil, scopes: [], message: nil)

    /// Whether the token has the scopes needed to create registration tokens.
    var canManageRunners: Bool { scopes.contains("repo") || scopes.contains("admin:org") }
}

/// Errors specific to GitHub operations, with friendlier messages.
enum GitHubError: LocalizedError {
    case notAuthenticated
    case forbidden(String)
    case notFound(String)
    case rateLimited
    case decodeFailed(String)
    case shell(ShellError)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "GitHub CLI is not authenticated. Run `gh auth login` in Terminal."
        case .forbidden(let ctx):
            return "You don't have admin access for \(ctx). Registering a runner needs admin rights on the repo or org."
        case .notFound(let ctx):
            return "\(ctx) was not found (or you lack access to it)."
        case .rateLimited:
            return "GitHub API rate limit reached. Wait a little and try again."
        case .decodeFailed(let what):
            return "Could not read the GitHub response for \(what)."
        case .shell(let e):
            return e.errorDescription
        }
    }

    /// Classify a failed `gh` invocation's stderr into a specific error.
    /// Rate-limiting also returns HTTP 403, so it must be checked BEFORE the admin case.
    static func classify(stderr: String, context: String) -> GitHubError? {
        let err = stderr.lowercased()
        if err.contains("rate limit") || err.contains("x-ratelimit-remaining: 0") {
            return .rateLimited
        }
        if err.contains("http 403") || err.contains("must have admin") || err.contains("forbidden") {
            return .forbidden(context)
        }
        if err.contains("http 404") || err.contains("not found") {
            return .notFound(context)
        }
        if err.contains("not logged") || err.contains("authentication") {
            return .notAuthenticated
        }
        return nil
    }
}

/// Thin wrapper over the `gh` CLI. Stateless; safe to create ad hoc.
struct GitHubClient: Sendable {
    /// Path or name of the `gh` executable.
    var ghPath: String = "gh"

    private func gh(_ args: [String]) async throws -> ShellResult {
        do {
            return try await Shell.run(ghPath, args)
        } catch let e as ShellError {
            throw GitHubError.shell(e)
        }
    }

    // MARK: - Auth

    func authStatus() async -> GHAuthStatus {
        // Availability: does the executable resolve?
        guard Shell.which(ghPath) != nil else {
            return GHAuthStatus(available: false, authenticated: false, account: nil, scopes: [],
                                message: "`gh` was not found. Install it with `brew install gh`.")
        }
        // `gh auth status` prints details to stderr in a human format.
        let result = (try? await gh(["auth", "status"])) ?? ShellResult(stdout: "", stderr: "", exitCode: 1)
        let text = result.stdout + "\n" + result.stderr
        let authenticated = result.succeeded && text.contains("Logged in")

        // gh 2.40+ can list several accounts for a host; only one is "Active account: true".
        // Parse per-block and commit the active account's name and scopes (falling back to
        // the first block if no active marker is present, e.g. older gh).
        var account: String?
        var scopes: [String] = []
        var blockAccount: String?
        var blockIsActive = false
        var haveActive = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.contains("Logged in to") {
                // "✓ Logged in to github.com account NAME (keyring)"
                if let range = line.range(of: "account ") {
                    blockAccount = line[range.upperBound...].split(separator: " ").first.map(String.init)
                } else {
                    blockAccount = nil
                }
                blockIsActive = false
                if account == nil { account = blockAccount }  // fallback: first account
            } else if line.contains("Active account: true") {
                blockIsActive = true
                haveActive = true
                account = blockAccount
            } else if line.contains("Token scopes:") {
                // "- Token scopes: 'gist', 'read:org', 'repo', 'workflow'"
                let parsed = line
                    .replacingOccurrences(of: "- Token scopes:", with: "")
                    .replacingOccurrences(of: "Token scopes:", with: "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
                    .filter { !$0.isEmpty }
                if blockIsActive || !haveActive { scopes = parsed }
            }
        }

        return GHAuthStatus(
            available: true,
            authenticated: authenticated,
            account: account,
            scopes: scopes,
            message: authenticated ? nil : "Not logged in. Run `gh auth login`."
        )
    }

    // MARK: - Repositories

    /// All repositories the user can administer (owner + org member with admin).
    func adminRepos() async throws -> [GHRepo] {
        let result = try await gh([
            "api", "--paginate",
            "-H", "Accept: application/vnd.github+json",
            "user/repos?per_page=100&sort=full_name",
            "--jq", ".[]"
        ])
        guard result.succeeded else {
            throw GitHubError.shell(.nonZeroExit(command: "gh api user/repos", code: result.exitCode, stderr: result.stderr))
        }
        let decoder = JSONDecoder()
        var repos: [GHRepo] = []
        // `--jq '.[]'` yields one JSON object per line (JSON Lines).
        for line in result.stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8) else { continue }
            if let repo = try? decoder.decode(GHRepo.self, from: data) {
                repos.append(repo)
            }
        }
        return repos
            .filter { $0.isAdmin }
            .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    // MARK: - Tokens

    func createRegistrationToken(for target: GHTarget) async throws -> GHRunnerToken {
        try await postToken(path: target.registrationTokenPath, context: target.displayString)
    }

    func createRemoveToken(for target: GHTarget) async throws -> GHRunnerToken {
        try await postToken(path: target.removeTokenPath, context: target.displayString)
    }

    private func postToken(path: String, context: String) async throws -> GHRunnerToken {
        let result = try await gh(["api", "-X", "POST", "-H", "Accept: application/vnd.github+json", path])
        try mapCommonErrors(result, context: context)
        guard let data = result.stdout.data(using: .utf8),
              let token = try? JSONDecoder().decode(GHRunnerToken.self, from: data) else {
            throw GitHubError.decodeFailed("registration token")
        }
        return token
    }

    // MARK: - Runners (requires admin)

    func listRunners(for target: GHTarget) async throws -> [GHRunner] {
        let result = try await gh([
            "api", "--paginate",
            "-H", "Accept: application/vnd.github+json",
            "\(target.runnersPath)?per_page=100",
            "--jq", ".runners[]"
        ])
        try mapCommonErrors(result, context: target.displayString)
        let decoder = JSONDecoder()
        var runners: [GHRunner] = []
        for line in result.stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8) else { continue }
            if let runner = try? decoder.decode(GHRunner.self, from: data) {
                runners.append(runner)
            }
        }
        return runners
    }

    // MARK: - Runner labels (requires admin)

    /// All labels for a runner, both default (read-only) and custom.
    func runnerLabels(for target: GHTarget, runnerID: Int) async throws -> [RunnerLabel] {
        let result = try await gh([
            "api", "-H", "Accept: application/vnd.github+json",
            target.runnerLabelsPath(id: runnerID)
        ])
        try mapCommonErrors(result, context: target.displayString)
        guard let data = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(RunnerLabelsResponse.self, from: data) else {
            throw GitHubError.decodeFailed("runner labels")
        }
        return response.labels
    }

    /// Replace the runner's CUSTOM labels (default labels are preserved by GitHub).
    /// Returns the resulting full label set.
    func setCustomLabels(for target: GHTarget, runnerID: Int, labels: [String]) async throws -> [RunnerLabel] {
        let body = try JSONEncoder().encode(["labels": labels])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("runnermenu-labels-\(UUID().uuidString).json")
        try body.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await gh([
            "api", "-X", "PUT", "-H", "Accept: application/vnd.github+json",
            target.runnerLabelsPath(id: runnerID), "--input", tmp.path
        ])
        try mapCommonErrors(result, context: target.displayString)
        guard let data = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(RunnerLabelsResponse.self, from: data) else {
            throw GitHubError.decodeFailed("runner labels")
        }
        return response.labels
    }

    // MARK: - Releases

    func latestRunnerRelease() async throws -> GHRelease {
        let result = try await gh([
            "api", "-H", "Accept: application/vnd.github+json",
            "repos/actions/runner/releases/latest"
        ])
        try mapCommonErrors(result, context: "actions/runner releases")
        guard let data = result.stdout.data(using: .utf8),
              let release = try? JSONDecoder().decode(GHRelease.self, from: data) else {
            throw GitHubError.decodeFailed("latest release")
        }
        return release
    }

    // MARK: - Helpers

    private func mapCommonErrors(_ result: ShellResult, context: String) throws {
        guard !result.succeeded else { return }
        if let classified = GitHubError.classify(stderr: result.stderr, context: context) {
            throw classified
        }
        throw GitHubError.shell(.nonZeroExit(command: "gh api", code: result.exitCode, stderr: result.stderr))
    }
}
