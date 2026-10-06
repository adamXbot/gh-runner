import SwiftUI

/// The status-item glyph. Reflects the aggregate state of all runners, in the
/// glyph family chosen in Settings.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    var store: RunnerStore
    @ObservedObject var menuBar: SurfaceMenuBarPreference

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel(accessibilityText)
            .help(accessibilityText)
            .task {
                // Dev affordance: RUNNERMENU_OPENWINDOW=1 opens the main window at launch.
                if ProcessInfo.processInfo.environment["RUNNERMENU_OPENWINDOW"] == "1" {
                    openWindow(id: RunnerMenuApp.windowID)
                }
            }
    }

    private var glyph: MenuBarGlyph {
        MenuBarGlyph(rawValue: menuBar.icon) ?? .default
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
        if store.executionMode == .dedicatedAccount {
            return store.runnerAgentReady ? "lock.shield.fill" : "exclamationmark.shield"
        }
        let a = aggregate
        if a.busy { return glyph.symbol(for: .busy) }
        if a.running { return glyph.symbol(for: .running) }
        if a.transitioning { return glyph.symbol(for: .transitioning) }
        return glyph.symbol(for: .stopped)
    }

    private var accessibilityText: String {
        if store.executionMode == .dedicatedAccount {
            return store.runnerAgentReady
                ? "Runner Menu — dedicated Runner Agent connected in read-only mode"
                : "Runner Menu — dedicated Runner Agent needs attention"
        }
        let a = aggregate
        if a.busy { return "Runner Menu — a job is running" }
        if a.running { return "Runner Menu — runner online" }
        if a.transitioning { return "Runner Menu — changing state" }
        return "Runner Menu — no runners online"
    }
}
