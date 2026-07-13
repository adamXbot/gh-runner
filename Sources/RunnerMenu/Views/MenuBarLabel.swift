import SwiftUI

/// The status-item glyph. Reflects the aggregate state of all runners.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    var store: RunnerStore

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel(accessibilityText)
            .task {
                // Dev affordance: RUNNERMENU_OPENWINDOW=1 opens the main window at launch.
                if ProcessInfo.processInfo.environment["RUNNERMENU_OPENWINDOW"] == "1" {
                    openWindow(id: RunnerMenuApp.windowID)
                }
            }
    }

    private var aggregate: (running: Bool, busy: Bool, transitioning: Bool) {
        var running = false, busy = false, transitioning = false
        for runner in store.runners {
            let s = store.status(for: runner)
            if s.busy { busy = true }
            if s.state == .running { running = true }
            if s.state == .starting || s.state == .stopping { transitioning = true }
        }
        return (running, busy, transitioning)
    }

    private var symbolName: String {
        let a = aggregate
        if a.busy { return "bolt.horizontal.circle.fill" }
        if a.running { return "play.circle.fill" }
        if a.transitioning { return "clock.arrow.circlepath" }
        return "stop.circle"
    }

    private var accessibilityText: String {
        let a = aggregate
        if a.busy { return "Runner Menu — a job is running" }
        if a.running { return "Runner Menu — runner online" }
        if a.transitioning { return "Runner Menu — changing state" }
        return "Runner Menu — no runners online"
    }
}
