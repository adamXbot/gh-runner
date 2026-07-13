import Foundation
import SwiftUI

/// Live, observed state of a runner directory. Recomputed on each poll.
struct RunnerLiveStatus: Equatable, Sendable {

    enum State: Equatable, Sendable {
        case notConfigured
        case stopped
        case starting
        case running
        case stopping
        case unknown

        var label: String {
            switch self {
            case .notConfigured: return "Not configured"
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running: return "Running"
            case .stopping: return "Stopping…"
            case .unknown: return "Unknown"
            }
        }
    }

    var state: State = .unknown
    /// PID of the `Runner.Listener` process bound to this directory, if any.
    var pid: Int32?
    var cpuPercent: Double?
    var memoryMB: Double?
    /// Human-friendly elapsed time (from `ps etime`).
    var uptime: String?
    var busy: Bool = false
    /// Name of the job currently executing, parsed from worker logs.
    var currentJob: String?
    /// True when the launchd LaunchAgent for this runner is installed.
    var serviceInstalled: Bool = false
    /// True when this process was launched by the app in supervised mode.
    var managedByApp: Bool = false
    var lastError: String?

    static let unknown = RunnerLiveStatus()

    var isRunning: Bool { state == .running || state == .starting }

    var symbolName: String {
        switch state {
        case .running: return busy ? "bolt.fill" : "play.circle.fill"
        case .starting, .stopping: return "clock.arrow.circlepath"
        case .stopped: return "stop.circle.fill"
        case .notConfigured: return "questionmark.circle"
        case .unknown: return "circle.dashed"
        }
    }

    var tintColor: Color {
        switch state {
        case .running: return busy ? .orange : .green
        case .starting, .stopping: return .yellow
        case .stopped: return .secondary
        case .notConfigured: return .secondary
        case .unknown: return .secondary
        }
    }
}
