import Foundation
import Testing
@testable import RunnerMenu

struct ShellTests {
    @Test func drainsLargeStdoutAndStderrWithoutPipeDeadlock() async throws {
        let result = try await Shell.run("/usr/bin/awk", ["BEGIN { for (i=0; i<4000; i++) { print \"0123456789012345678901234567890123456789012345678901234567890123456789\"; print \"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnop\" > \"/dev/stderr\" } }"])
        #expect(result.succeeded)
        #expect(result.stdout.utf8.count > 64 * 1024)
        #expect(result.stderr.utf8.count > 64 * 1024)
        #expect(result.stdout.split(separator: "\n").count == 4000)
        #expect(result.stderr.split(separator: "\n").count == 4000)
    }

    @Test func nonzeroExitPreservesBothOutputStreams() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "printf 'output'; printf 'failure' >&2; exit 7"])
        #expect(result.stdout == "output")
        #expect(result.stderr == "failure")
        #expect(result.exitCode == 7)
    }
}
