import Testing
@testable import RunnerMenu

struct UpdaterAndFormattingTests {
    @Test func sha256ParsingAssociatesHashWithAsset() {
        let asset = "actions-runner-osx-arm64-2.335.1.tar.gz"
        let hash = String(repeating: "ab", count: 32)
        let body = """
        ## Downloads
        `\(asset)`
        SHA-256: `\(hash)`
        """

        #expect(Updater.parseSHA256(for: asset, in: body) == hash)
        #expect(Updater.parseSHA256(for: "another-asset.tar.gz", in: body) == nil)
    }

    @Test func humanByteSizeFormatting() {
        #expect(Updater.humanByteSize(0) == "0 B")
        #expect(Updater.humanByteSize(512) == "512 B")
        #expect(Updater.humanByteSize(1536) == "1.5 KB")
        #expect(Updater.humanByteSize(65 * 1024 * 1024) == "65.0 MB")
    }

    @Test func versionComparison() {
        #expect(Updater.isNewer("2.336.0", than: "2.335.1"))
        #expect(Updater.isNewer("2.335.1", than: nil))
        #expect(!Updater.isNewer("2.335.1", than: "2.335.1"))
        #expect(!Updater.isNewer("2.334.0", than: "2.335.1"))
    }

    @Test @MainActor func humanUptimeFormatting() {
        #expect(RunnerStore.humanUptime("15:28") == "15m")
        #expect(RunnerStore.humanUptime("01:02:03") == "1h 2m")
        #expect(RunnerStore.humanUptime("1-02:03:04") == "1d 2h")
        #expect(RunnerStore.humanUptime("00:12") == "just now")
    }
}
