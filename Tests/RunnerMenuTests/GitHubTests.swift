import Foundation
import Testing
@testable import RunnerMenu

struct GitHubTests {
    private func tag(_ e: GitHubError?) -> String {
        switch e {
        case .rateLimited: return "rate"
        case .forbidden: return "forbidden"
        case .notFound: return "notfound"
        case .notAuthenticated: return "auth"
        case .shell: return "shell"
        case .decodeFailed: return "decode"
        case .workflowCancellationDenied: return "cancel-permission"
        case .registrationRequiresPrivateRepository: return "public-repo"
        case .registrationRequiresRepository: return "org-repo"
        case .runnerNameInUse: return "name-in-use"
        case nil: return "nil"
        }
    }

    @Test func classifyDistinguishesRateLimitFromMissingAdmin() {
        // Both are HTTP 403; rate-limiting must win.
        #expect(tag(GitHubError.classify(stderr: "gh: HTTP 403: API rate limit exceeded for user", context: "x")) == "rate")
        #expect(tag(GitHubError.classify(stderr: "x-ratelimit-remaining: 0\nHTTP 403", context: "x")) == "rate")
        #expect(tag(GitHubError.classify(stderr: "gh: Must have admin rights to Repo (HTTP 403)", context: "x")) == "forbidden")
        #expect(tag(GitHubError.classify(stderr: "gh: Not Found (HTTP 404)", context: "x")) == "notfound")
        #expect(tag(GitHubError.classify(stderr: "some unrelated failure", context: "x")) == "nil")
    }

    @Test func runnerLabelsDecodeAndPath() throws {
        let json = """
        {"total_count":4,"labels":[
          {"id":1,"name":"self-hosted","type":"read-only"},
          {"id":2,"name":"macOS","type":"read-only"},
          {"id":5,"name":"gpu","type":"custom"}
        ]}
        """
        let resp = try JSONDecoder().decode(RunnerLabelsResponse.self, from: Data(json.utf8))
        #expect(resp.totalCount == 4)
        #expect(resp.labels.filter(\.isCustom).map(\.name) == ["gpu"])
        #expect(resp.labels.filter { !$0.isCustom }.map(\.name) == ["self-hosted", "macOS"])

        #expect(GHTarget.repo(owner: "adamXbot", name: "BananaBlitz").runnerLabelsPath(id: 21)
                == "repos/adamXbot/BananaBlitz/actions/runners/21/labels")
        #expect(GHTarget.org("acme").runnerLabelsPath(id: 7) == "orgs/acme/actions/runners/7/labels")
    }

    @Test func releasePublishedDateParsesISO8601() {
        let dated = GHRelease(tagName: "v2.335.1", name: nil, body: nil,
                              htmlUrl: "https://github.com/actions/runner/releases/tag/v2.335.1",
                              publishedAt: "2026-06-09T01:32:05Z", assets: [])
        #expect(dated.publishedDate != nil)

        let absent = GHRelease(tagName: "v1", name: nil, body: nil, htmlUrl: "https://x", publishedAt: nil, assets: [])
        #expect(absent.publishedDate == nil)

        let garbage = GHRelease(tagName: "v1", name: nil, body: nil, htmlUrl: "https://x", publishedAt: "not-a-date", assets: [])
        #expect(garbage.publishedDate == nil)
    }

    @Test func workflowCancellationUsesExplicitRepository() {
        let reference = WorkflowRunReference(
            repository: "octo-org/octo-repo",
            runID: "29227574780"
        )
        #expect(GitHubClient.cancelWorkflowRunArguments(reference) == [
            "run", "cancel", "29227574780", "--repo", "octo-org/octo-repo"
        ])
        #expect(GitHubError.workflowCancellationDenied(reference.repository)
            .errorDescription?.contains("Actions write permission") == true)
    }

    @Test func registrationVisibilityPreflightRejectsPublicAndAllowsPrivate() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh-visibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: script) }
        func setVisibility(_ value: String) throws {
            try "#!/bin/sh\nprintf '%s\\n' '\(value)'\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }

        let client = GitHubClient(ghPath: script.path)
        let target = GHTarget.repo(owner: "owner", name: "project")
        try setVisibility("false")
        do {
            try await client.assertPrivateRepository(target)
            Issue.record("Public repository was accepted")
        } catch GitHubError.registrationRequiresPrivateRepository(let repository) {
            #expect(repository == "owner/project")
        }

        try setVisibility("true")
        try await client.assertPrivateRepository(target)
    }

    @Test func registrationVisibilityPreflightRejectsOrganizationScope() async {
        do {
            try await GitHubClient(ghPath: "/no-such-gh").assertPrivateRepository(.org("example"))
            Issue.record("Organization-wide target was accepted")
        } catch GitHubError.registrationRequiresRepository {
            // Rejected before invoking gh.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
