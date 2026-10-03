import Foundation
import Testing
@testable import RunnerMenu

struct RunnerFleetSnapshotTests {
    @Test func totalsAndDrawerMembershipUseTheSameObservedStatuses() {
        let runners = fixtures(6)
        let snapshot = RunnerFleetSnapshot(runners: runners, statuses: [
            runners[0].id: RunnerLiveStatus(state: .running, busy: true),
            runners[1].id: RunnerLiveStatus(state: .running),
            runners[2].id: RunnerLiveStatus(state: .starting),
            runners[3].id: RunnerLiveStatus(state: .stopped),
            runners[4].id: RunnerLiveStatus(state: .notConfigured),
            runners[5].id: RunnerLiveStatus(state: .running, lastError: "Connection failed"),
        ])
        #expect(snapshot.count(.all) == 6)
        #expect(snapshot.count(.active) == 4)
        #expect(snapshot.count(.busy) == 1)
        #expect(snapshot.count(.idle) == 2)
        #expect(snapshot.count(.stopped) == 1)
        #expect(snapshot.count(.attention) == 2)
        #expect(snapshot.entries(matching: .busy).map(\.id) == [runners[0].id])
        #expect(snapshot.entries(matching: .attention).map(\.id) == [runners[4].id, runners[5].id])
    }

    @Test func activeCountsIncludeMonitoredRunnersRegardlessOfControlEligibility() {
        let foreign = RunnerInstance(directory: URL(fileURLWithPath: "/usr"))
        let snapshot = RunnerFleetSnapshot(runners: [foreign], statuses: [
            foreign.id: RunnerLiveStatus(state: .running, busy: true, lastError: "Read-only account"),
        ])
        #expect(snapshot.count(.active) == 1)
        #expect(snapshot.count(.busy) == 1)
        #expect(snapshot.count(.attention) == 1)
    }

    @Test func removedRunnersAndStaleStatusesDoNotRemainInTotals() {
        let runners = fixtures(2)
        let snapshot = RunnerFleetSnapshot(runners: [runners[0]], statuses: [
            runners[0].id: RunnerLiveStatus(state: .stopped),
            runners[1].id: RunnerLiveStatus(state: .running, cpuPercent: 90, memoryMB: 300, busy: true),
        ])
        #expect(snapshot.count(.all) == 1)
        #expect(snapshot.count(.active) == 0)
        #expect(snapshot.totalCPU == nil)
        #expect(snapshot.totalMemoryMB == nil)
    }

    @Test func aBusyRunnerBecomingIdleMovesBetweenPreviewsWithoutChangingTotal() {
        let runner = fixtures(1)[0]
        let before = RunnerFleetSnapshot(runners: [runner], statuses: [runner.id: RunnerLiveStatus(state: .running, busy: true)])
        let after = RunnerFleetSnapshot(runners: [runner], statuses: [runner.id: RunnerLiveStatus(state: .running)])
        #expect(before.count(.busy) == 1)
        #expect(after.count(.busy) == 0)
        #expect(after.entries(matching: .busy).isEmpty)
        #expect(after.count(.idle) == 1)
        #expect(before.count(.all) == after.count(.all))
    }

    @Test func missingObservationIsUnknownAndEmptyFleetHasEmptyPreviews() {
        let snapshot = RunnerFleetSnapshot(runners: fixtures(1), statuses: [:])
        #expect(snapshot.count(.attention) == 1)
        #expect(snapshot.count(.active) == 0)
        let empty = RunnerFleetSnapshot(runners: [], statuses: [:])
        for filter in RunnerFleetFilter.allCases {
            #expect(empty.count(filter) == 0)
            #expect(empty.entries(matching: filter).isEmpty)
        }
    }

    @Test func telemetryDistinguishesMissingDataFromMeasuredZero() {
        let runners = fixtures(2)
        let missing = RunnerFleetSnapshot(runners: runners, statuses: [:])
        #expect(missing.totalCPU == nil)
        #expect(missing.totalMemoryMB == nil)
        let zero = RunnerFleetSnapshot(runners: runners, statuses: [runners[0].id: RunnerLiveStatus(cpuPercent: 0, memoryMB: 0)])
        #expect(zero.totalCPU == 0)
        #expect(zero.totalMemoryMB == 0)
        let measured = RunnerFleetSnapshot(runners: runners, statuses: [
            runners[0].id: RunnerLiveStatus(cpuPercent: 4.5, memoryMB: 20),
            runners[1].id: RunnerLiveStatus(cpuPercent: 3.5, memoryMB: 30),
        ])
        #expect(measured.totalCPU == 8)
        #expect(measured.totalMemoryMB == 50)
    }

    @Test func transitionsDoNotAppearIdleAndStaleBusyFlagsDoNotInventRunningJobs() {
        let runners = fixtures(3)
        let snapshot = RunnerFleetSnapshot(runners: runners, statuses: [
            runners[0].id: RunnerLiveStatus(state: .starting),
            runners[1].id: RunnerLiveStatus(state: .stopping),
            runners[2].id: RunnerLiveStatus(state: .stopped, busy: true),
        ])
        #expect(snapshot.count(.idle) == 0)
        #expect(snapshot.count(.busy) == 0)
        #expect(snapshot.count(.active) == 1)
    }

    private func fixtures(_ count: Int) -> [RunnerInstance] {
        (0..<count).map { RunnerInstance(directory: URL(fileURLWithPath: "/synthetic/runner-\($0)")) }
    }
}
