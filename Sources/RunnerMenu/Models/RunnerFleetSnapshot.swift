import Foundation

enum RunnerFleetFilter: String, CaseIterable, Identifiable {
    case all, active, busy, idle, stopped, attention

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Runners"
        case .active: return "Active"
        case .busy: return "Running jobs"
        case .idle: return "Idle"
        case .stopped: return "Stopped"
        case .attention: return "Needs attention"
        }
    }
    var explanation: String {
        switch self {
        case .all: return "All monitored runners"
        case .active: return "Running or starting"
        case .busy: return "Executing a job"
        case .idle: return "Ready for the next job"
        case .stopped: return "Not running"
        case .attention: return "Errors, unknown state, or setup needed"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "shippingbox"
        case .active: return "play.circle"
        case .busy: return "bolt"
        case .idle: return "pause.circle"
        case .stopped: return "stop.circle"
        case .attention: return "exclamationmark.triangle"
        }
    }
    var emptyTitle: String {
        switch self {
        case .all: return "No runners"
        case .active: return "No active runners"
        case .busy: return "No jobs running"
        case .idle: return "No idle runners"
        case .stopped: return "No stopped runners"
        case .attention: return "No runners need attention"
        }
    }
    func includes(_ status: RunnerLiveStatus) -> Bool {
        switch self {
        case .all: return true
        case .active: return status.isRunning
        case .busy: return status.busy && status.isRunning
        case .idle: return status.state == .running && !status.busy
        case .stopped: return status.state == .stopped
        case .attention:
            return status.state == .unknown || status.state == .notConfigured
                || status.lastError?.isEmpty == false
        }
    }
}

/// Counts describe observed runners, including runners this account cannot control.
/// Lifecycle eligibility (such as canStop) must not change the fleet totals.
struct RunnerFleetSnapshot {
    struct Entry: Identifiable {
        let runner: RunnerInstance
        let status: RunnerLiveStatus
        var id: String { runner.id }
    }
    let entries: [Entry]

    init(runners: [RunnerInstance], statuses: [String: RunnerLiveStatus]) {
        entries = runners.map { Entry(runner: $0, status: statuses[$0.id] ?? .unknown) }
    }

    func entries(matching filter: RunnerFleetFilter) -> [Entry] {
        entries.filter { filter.includes($0.status) }
    }

    func count(_ filter: RunnerFleetFilter) -> Int { entries(matching: filter).count }

    var totalCPU: Double? { total(\.cpuPercent) }
    var totalMemoryMB: Double? { total(\.memoryMB) }

    private func total(_ key: KeyPath<RunnerLiveStatus, Double?>) -> Double? {
        let values = entries.compactMap { $0.status[keyPath: key] }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}
