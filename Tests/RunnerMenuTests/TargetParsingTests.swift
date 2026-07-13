import Testing
@testable import RunnerMenu

struct TargetParsingTests {
    @Test func runnerConfigScopeParsesSupportedGitHubURLs() {
        #expect(RunnerConfig.scope(from: "https://github.com/octocat/hello-world")
                == .repo(owner: "octocat", name: "hello-world"))
        #expect(RunnerConfig.scope(from: "https://github.com/example-org") == .org("example-org"))
        #expect(RunnerConfig.scope(from: "https://github.com/enterprises/example") == .enterprise("example"))
    }

    @Test func runnerConfigScopeRejectsUnsupportedOrAmbiguousURLs() {
        #expect(RunnerConfig.scope(from: "https://notgithub.com/octocat/hello-world") == .unknown)
        #expect(RunnerConfig.scope(from: "http://github.com/octocat/hello-world") == .unknown)
        #expect(RunnerConfig.scope(from: "https://github.com/octocat/hello-world/issues") == .unknown)
        #expect(RunnerConfig.scope(from: "https://github.com/octocat/hello-world?tab=readme") == .unknown)
    }

    @Test func manualTargetParserAcceptsDocumentedFormats() {
        #expect(GHTarget.parseManual("octocat/hello-world") == .repo(owner: "octocat", name: "hello-world"))
        #expect(GHTarget.parseManual("example-org") == .org("example-org"))
        #expect(GHTarget.parseManual(" https://github.com/octocat/hello-world ")
                == .repo(owner: "octocat", name: "hello-world"))
    }

    @Test func manualTargetParserRejectsMalformedValues() {
        #expect(GHTarget.parseManual("https://notgithub.com/octocat/hello-world") == nil)
        #expect(GHTarget.parseManual("octocat/") == nil)
        #expect(GHTarget.parseManual("/hello-world") == nil)
        #expect(GHTarget.parseManual("octocat/hello-world/issues") == nil)
        #expect(GHTarget.parseManual("octocat /hello-world") == nil)
    }
}
