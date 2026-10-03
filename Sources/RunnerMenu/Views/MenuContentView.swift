import SwiftUI
import AppKit

/// Reports the natural height of the home content so the scroll area can size to it.
private struct HomeContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The root panel shown from the menu bar item.
struct MenuContentView: View {
    @Environment(RunnerStore.self) private var store
    @Environment(AppUpdater.self) private var appUpdater
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Route: Equatable {
        case home
        case find
        case register
        case updates
        case log
        case labels
    }
    @State private var route: Route = .home
    @State private var homeContentHeight: CGFloat = 320
    @State private var homeScreenHeight: CGFloat = 900
    private enum HomeView: String, CaseIterable {
        case all = "All Runners"
        case selected = "Selected Runner"
    }
    @State private var homeView: HomeView = .all
    @State private var fleetFilter: RunnerFleetFilter?

    @ViewBuilder
    var body: some View {
        if store.onboardingCompleted {
            if store.executionMode == .dedicatedAccount {
                DedicatedRunnerAgentMenuView(
                    openWindow: openMainWindow,
                    openSettings: openSettingsWindow
                )
            } else {
                configuredContent
            }
        } else {
            onboardingPrompt
        }
    }

    private var configuredContent: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let banner = store.banner {
                BannerView(message: banner) { store.banner = nil }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .transition(.opacity)
            }

            content
                .frame(maxWidth: .infinity)
                .animation(RunnerMotion.content(reduceMotion: reduceMotion), value: route)

            Divider()
            footer
        }
        .frame(width: 388)
        .animation(RunnerMotion.content(reduceMotion: reduceMotion), value: store.banner)
        .onAppear {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            homeScreenHeight = screen?.visibleFrame.height ?? 900
        }
        .task { await store.refreshAll() }
    }

    private var onboardingPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Finish setting up Runner Menu")
                .font(.headline)
            Text("Choose which macOS account should run jobs and discover any existing GitHub Actions runners.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                openMainWindow()
            } label: {
                Label("Open Setup", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            Divider()
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Runner Menu", systemImage: "power")
            }
            .buttonStyle(RunnerButtonStyle())
        }
        .padding(24)
        .frame(width: 388)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.2.fill")
                .foregroundStyle(.tint)
            Text(headerTitle)
                .font(.headline)
            Spacer()
            if route == .home {
                GHAuthChip(auth: store.ghAuth)
                if store.runners.count >= 2 {
                    batchMenu.labelStyle(.iconOnly)
                        .accessibilityLabel("All runner actions")
                }
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(RunnerButtonStyle())
                .help("Refresh (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh")
            } else {
                Button {
                    route = .home
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(RunnerButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Back to runners (Esc)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var headerTitle: String {
        switch route {
        case .home: return "Runner Menu"
        case .find: return "Runners on This Mac"
        case .register: return "Register New Runner"
        case .updates: return "Runner Updates"
        case .log: return "Live Log"
        case .labels: return "Edit Labels"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch route {
        case .home:
            homeContent
        case .find:
            FindRunnersView { route = .home }
        case .register:
            RegisterRunnerView { route = .home }
        case .updates:
            if let runner = store.selectedRunner {
                UpdatesView(instance: runner).id(runner.id)
            } else { missingRunner }
        case .log:
            if let runner = store.selectedRunner {
                LogConsoleView(instance: runner)
            } else { missingRunner }
        case .labels:
            if let runner = store.selectedRunner {
                LabelEditorView(instance: runner, fixedHeight: 420)
            } else { missingRunner }
        }
    }

    private var missingRunner: some View {
        ContentUnavailableView("No runner selected", systemImage: "questionmark.folder")
            .frame(height: 220)
    }

    @ViewBuilder
    private var homeContent: some View {
        if store.runners.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                Picker("Runner view", selection: $homeView) {
                    ForEach(HomeView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .help("Preview fleet totals, or focus on one runner's activity")

                if homeView == .all {
                    AllRunnersView(
                        selection: $fleetFilter,
                        compact: true,
                        showRunner: { runner in
                            store.selectedRunnerID = runner.id
                            homeView = .selected
                        },
                        showLog: { open(.log, for: $0) }
                    )
                    .frame(height: min(fleetFilter == nil ? 398 : 560, availableHomeHeight))
                } else {
                    Picker("Runner", selection: runnerSelection) {
                        ForEach(store.runners) { runner in
                            Text(runner.displayName).tag(Optional(runner.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .help("Choose the runner whose activity to show")

                    ScrollView {
                        if let selected = store.selectedRunner {
                            RunnerDetailView(
                                instance: selected,
                                showLog: { route = .log },
                                showUpdates: { route = .updates },
                                showLabels: { route = .labels },
                                historyLimit: nil
                            )
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: HomeContentHeightKey.self, value: proxy.size.height)
                            })
                        }
                    }
                    .id(store.selectedRunnerID)
                    // Use the screen's height instead of burying activity under a
                    // second runner list in a fixed 460-point viewport.
                    .frame(height: min(max(homeContentHeight, 220), availableHomeHeight))
                    .onPreferenceChange(HomeContentHeightKey.self) { homeContentHeight = $0 }
                }
            }
        }
    }

    private var runnerSelection: Binding<String?> {
        Binding(get: { store.selectedRunner?.id }, set: { store.selectedRunnerID = $0 })
    }

    private var availableHomeHeight: CGFloat {
        // Header, footer, selectors, and a possible banner remain outside the scroll area.
        return max(200, homeScreenHeight - 190 - (store.banner == nil ? 0 : 70))
    }

    private func open(_ destination: Route, for runner: RunnerInstance) {
        store.selectedRunnerID = runner.id
        route = destination
    }

    private var batchMenu: some View {
        Group {
            Menu {
                Button { store.startAll() } label: { Label("Start All", systemImage: "play.fill") }
                    .disabled(store.startableRunners.isEmpty)
                Button { store.stopAll() } label: { Label("Stop All", systemImage: "stop.fill") }
                    .disabled(store.runningRunners.isEmpty)
                Button { store.stopAll(force: true) } label: { Label("Force Stop All", systemImage: "xmark.octagon") }
                    .disabled(store.runningRunners.isEmpty)
                Divider()
                Button { Task { await store.updateAll() } } label: {
                    Label("Check & Update All", systemImage: "arrow.down.circle")
                }
                .disabled(store.isInFlight("update-all"))
            } label: {
                Label("All Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Start, stop, or update all runners at once")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No runners yet")
                .font(.headline)
            Text("If runners already exist on this Mac, find and monitor them. Registering is only for creating a new one against a repository.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                route = .find
            } label: {
                Label("Find Runners on This Mac", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            Button {
                route = .register
            } label: {
                Label("Register New Runner", systemImage: "plus")
            }
            .buttonStyle(.link)
            if !store.ghAuth.authenticated {
                Text(store.ghAuth.message ?? "Sign in with `gh auth login` to enable GitHub features.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Menu {
                Button { route = .find } label: {
                    Label("Find Runners on This Mac…", systemImage: "magnifyingglass")
                }
                Button { route = .register } label: {
                    Label("Register New Runner…", systemImage: "plus.circle")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Monitor an existing runner, or register a new one")

            Button {
                store.selectedRunnerID = store.selectedRunner?.id
                route = .updates
            } label: {
                Label("Updates", systemImage: "arrow.down.circle")
            }
            .help("Check for runner updates (⌘U)")
            .keyboardShortcut("u", modifiers: .command)
            .disabled(store.selectedRunner == nil)

            Button {
                openMainWindow()
            } label: {
                Label("Open Window", systemImage: "macwindow")
            }
            .help("Open the full window (⌘N)")
            .keyboardShortcut("n", modifiers: .command)

            Spacer()

            Button {
                appUpdater.checkForUpdates()
            } label: {
                Label("Check for App Updates", systemImage: "arrow.down.app")
            }
            // Distinct from the per-runner Updates screen, which updates the
            // GitHub Actions runner rather than this app.
            .help(appUpdater.canCheckForUpdates
                  ? "Check for Runner Menu updates"
                  : (appUpdater.unavailableReason ?? "Updates unavailable"))
            .disabled(!appUpdater.canCheckForUpdates)

            Button {
                openSettingsWindow()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
            .keyboardShortcut(",", modifiers: .command)

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit Runner Menu (⌘Q)")
            .keyboardShortcut("q", modifiers: .command)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(RunnerButtonStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Open the main window and force it to the front (accessory apps open it behind).
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: RunnerMenuApp.windowID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.windows.first { w in
                (w.identifier?.rawValue ?? "").contains(RunnerMenuApp.windowID) || w.title == "Runner Menu"
            }
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }

    /// Open Settings and force it to the front. A menu-bar (`.accessory`) app doesn't
    /// activate on its own, so `openSettings()` alone opens the window *behind* other
    /// apps — it looks like "nothing happened". We activate and order it front.
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            let settingsWindow = NSApp.windows.first { window in
                let id = window.identifier?.rawValue ?? ""
                return id.contains("Settings") || window.title == "Runner Menu Settings"
            }
            settingsWindow?.makeKeyAndOrderFront(nil)
            settingsWindow?.orderFrontRegardless()
        }
    }
}
