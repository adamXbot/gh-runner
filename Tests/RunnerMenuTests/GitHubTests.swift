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
}
