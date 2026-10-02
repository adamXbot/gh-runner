import Foundation
import Testing
@testable import RunnerMenu

struct ProcessMonitorTests {
    @Test func snapshotParsesExecutablePathsWithSpacesAndBusyWorkers() {
        let directory = URL(fileURLWithPath: "/tmp/runner folder/with résumé")
        let scan = ProcessMonitor.parseSnapshot("""
          123 12.5 2048 01:02:03 /tmp/runner folder/with résumé/bin/Runner.Listener
        124\t0.0\t1024\t00:45\t/tmp/runner folder/with résumé/bin/Runner.Worker
          125 0.1 999 00:30 /Applications/Unrelated.app/Contents/MacOS/App
        """)
        #expect(scan.listener(for: directory) == ProcInfo(pid: 123, cpuPercent: 12.5, memoryMB: 2, etime: "01:02:03"))
        #expect(scan.isBusy(directory))
        #expect(scan.runnerDirectories.count == 1)
    }

    @Test func snapshotRejectsMalformedRowsAndExecutableLookalikes() {
        let scan = ProcessMonitor.parseSnapshot("""
        not-a-pid 0 10 00:01 /tmp/a/bin/Runner.Listener
        -1 0 10 00:01 /tmp/b/bin/Runner.Listener
        2 0 10 /tmp/c/bin/Runner.Listener
        3 0 10 00:01 /tmp/d/bin/Runner.Listener.backup
        4 0 10 00:01 /tmp/e/bin/Runner.Worker.extra
        5 0 10 00:01 /tmp/f/bin/Runner.Listener run
        """)
        #expect(scan.listeners.isEmpty)
        #expect(scan.busyDirectories.isEmpty)
    }

    @Test func largeUnrelatedSnapshotKeepsOnlyRunnerProcesses() {
        let unrelated = (0..<10_000).map { "\($0 + 100) 0.0 1000 00:01 /Applications/Unrelated\($0).app/App" }.joined(separator: "\n")
        let scan = ProcessMonitor.parseSnapshot(unrelated + "\n1 0.5 1024 01:00 /tmp/actual/bin/Runner.Listener\n")
        #expect(scan.listeners.count == 1)
        #expect(scan.listener(for: URL(fileURLWithPath: "/tmp/actual"))?.pid == 1)
    }

    @Test func snapshotMatchesSymlinkedRunnerDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("actual")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let scan = ProcessMonitor.parseSnapshot("123 0 1024 00:01 \(link.path)/bin/Runner.Listener")
        #expect(scan.listener(for: target)?.pid == 123)
    }
}
