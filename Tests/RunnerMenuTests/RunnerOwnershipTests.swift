import Foundation
import Testing
@testable import RunnerMenu

/// Ownership drives whether the UI offers lifecycle controls at all, so it is
/// worth pinning down. Discovery finds runners through the process table, which
/// spans every account on the machine — so a row can easily describe a runner
/// this app can observe but not operate.
struct RunnerOwnershipTests {
    @Test func directoryOwnedByCurrentUserIsOperable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RM-own-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let instance = RunnerInstance(directory: directory)

        #expect(instance.isOwnedByCurrentUser)
        #expect(instance.ownerUserID == getuid())
    }

    @Test func ownerAccountNameResolvesForCurrentUser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RM-own-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let instance = RunnerInstance(directory: directory)

        #expect(instance.ownerAccountName == NSUserName())
    }

    @Test func systemOwnedDirectoryIsNotOperable() throws {
        // /usr is owned by root, which stands in for "some other account" without
        // needing a second user account to exist on the test machine.
        let instance = RunnerInstance(directory: URL(fileURLWithPath: "/usr", isDirectory: true))

        #expect(instance.ownerUserID == 0)
        #expect(instance.ownerAccountName == "root")
        #expect(!instance.isOwnedByCurrentUser)
    }

    @Test func missingDirectoryFallsBackToOperable() {
        // An unreadable or absent path yields no owner. Treat that as operable
        // rather than silently disabling the controls: the failure the user then
        // sees comes from the runner scripts, which explain themselves, instead
        // of a greyed-out button with no cause.
        let instance = RunnerInstance(
            directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        )

        #expect(instance.ownerUserID == nil)
        #expect(instance.ownerAccountName == nil)
        #expect(instance.isOwnedByCurrentUser)
    }
}
