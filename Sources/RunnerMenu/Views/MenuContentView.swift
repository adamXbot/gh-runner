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

            Divider()
            footer
        }
        .frame(width: 388)
        .animation(.easeInOut(duration: 0.15), value: store.banner)
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
            .buttonStyle(.borderless)
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
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh")
            } else {
                Button {
                    withAnimation { route = .home }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
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
            FindRunnersView { withAnimation { route = .home } }
        case .register:
            RegisterRunnerView { withAnimation { route = .home } }
        case .updates:
            if let runner = store.selectedRunner {
                UpdatesView(instance: runner)
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
            ScrollView {
                VStack(spacing: 8) {
                    if store.runners.count >= 2 {
                        batchBar
                    }
                    ForEach(store.runners) { instance in
                        RunnerRowView(
                            instance: instance,
                            isSelected: instance.id == store.selectedRunner?.id
                        )
                        .onTapGesture { store.selectedRunnerID = instance.id }
                    }

                    if let selected = store.selectedRunner {
                        Divider().padding(.vertical, 2)
                        RunnerDetailView(
                            instance: selected,
                            showLog: { withAnimation { route = .log } },
                            showUpdates: { withAnimation { route = .updates } },
                            showLabels: { withAnimation { route = .labels } }
                        )
                    }
                }
                .padding(12)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: HomeContentHeightKey.self, value: proxy.size.height)
                })
            }
            // A ScrollView reports a zero ideal height, which would collapse the
            // MenuBarExtra window to nothing. Measure the content and size the scroll
            // area to it (floored so it never collapses, capped so it can still scroll).
            .frame(height: min(max(homeContentHeight, 140), 460))
            .onPreferenceChange(HomeContentHeightKey.self) { homeContentHeight = $0 }
        }
    }

    /// Summary + batch actions shown when multiple runners are managed.
    private var batchBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                statPill(store.runners.count, "runners", .secondary)
                statPill(store.runningRunners.count, "running", .green)
                if store.busyCount > 0 { statPill(store.busyCount, "busy", .orange) }
                Spacer()
                if store.isInFlight("update-all") {
                    ProgressView().controlSize(.small)
                }
                batchMenu
            }
            if store.totalCPU > 0 || store.totalMemoryMB > 0 {
                HStack(spacing: 4) {
                    Text(String(format: "CPU %.0f%%  ·  %.0f MB total", store.totalCPU, store.totalMemoryMB))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private func statPill(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(value)").font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
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
                withAnimation { route = .find }
            } label: {
                Label("Find Runners on This Mac", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            Button {
                withAnimation { route = .register }
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
                Button { withAnimation { route = .find } } label: {
                    Label("Find Runners on This Mac…", systemImage: "magnifyingglass")
                }
                Button { withAnimation { route = .register } } label: {
                    Label("Register New Runner…", systemImage: "plus.circle")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Monitor an existing runner, or register a new one")

            Button {
                store.selectedRunnerID = store.selectedRunner?.id
                withAnimation { route = .updates }
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
        .buttonStyle(.borderless)
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
