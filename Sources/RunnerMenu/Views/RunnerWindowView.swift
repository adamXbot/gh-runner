import SwiftUI
import AppKit

/// A full window: a Dashboard + per-runner detail in the sidebar, options on the right.
struct RunnerWindowView: View {
    @Environment(RunnerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: SidebarItem? = .dashboard
    @State private var detailTab: RunnerDetailTab = .overview
    @State private var logSource: LogConsoleView.Source = .runner
    @State private var followLogs = true
    @State private var showRegister = false
    @State private var showFind = false

    enum SidebarItem: Hashable {
        case dashboard
        case runner(String)
    }

    @ViewBuilder
    var body: some View {
        if store.onboardingCompleted {
            if store.executionMode == .dedicatedAccount {
                DedicatedRunnerAgentView()
            } else {
                runnerContent
            }
        } else {
            OnboardingView()
        }
    }

    private var runnerContent: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                        .tag(SidebarItem.dashboard)
                }
                Section("Runners") {
                    ForEach(store.runners) { runner in
                        RunnerSidebarRow(instance: runner)
                            .tag(SidebarItem.runner(runner.id))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .toolbar {
                ToolbarItemGroup {
                    // Two distinct jobs, so two named actions. "Add Runner"
                    // used to lead straight to registration, which asks for a
                    // repository — the wrong question entirely when the runner
                    // already exists and is already registered.
                    Menu {
                        Button { showFind = true } label: {
                            Label("Find Runners on This Mac…", systemImage: "magnifyingglass")
                        }
                        Button { showRegister = true } label: {
                            Label("Register New Runner…", systemImage: "plus.circle")
                        }
                    } label: {
                        Label("Add Runner", systemImage: "plus")
                    }
                    .help("Monitor an existing runner, or register a new one")
                    Button { Task { await store.refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh")
                        .keyboardShortcut("r", modifiers: .command)
                    batchMenu
                }
            }
        } detail: {
            detail
        }
        .navigationTitle("Runner Menu")
        .frame(minWidth: 820, minHeight: 520)
        .safeAreaInset(edge: .top) {
            if let banner = store.banner {
                BannerView(message: banner) { store.banner = nil }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .animation(RunnerMotion.content(reduceMotion: reduceMotion), value: store.banner)
        .task { await store.refreshAll() }
        .onChange(of: selection) { _, sel in
            if case let .runner(id) = sel { store.selectedRunnerID = id }
        }
        .onChange(of: store.selectedRunnerID) { _, id in
            if let id, store.runners.contains(where: { $0.id == id }) {
                selection = .runner(id)
            }
        }
        .sheet(isPresented: $showFind) {
            NavigationStack {
                FindRunnersView { showFind = false }
                    .frame(width: 520)
                    .navigationTitle("Runners on This Mac")
            }
        }
        .sheet(isPresented: $showRegister) {
            NavigationStack {
                RegisterRunnerView { showRegister = false }
                    .frame(width: 460)
                    .navigationTitle("Register New Runner")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showRegister = false } } }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .runner(let id):
            if let runner = store.runners.first(where: { $0.id == id }) {
                RunnerWindowDetail(instance: runner, tab: $detailTab, logSource: $logSource, followLogs: $followLogs).id(runner.id)
            } else {
                DashboardView()
            }
        default:
            DashboardView()
        }
    }

    private var batchMenu: some View {
        Menu {
            Button { store.startAll() } label: { Label("Start All", systemImage: "play.fill") }
                .disabled(store.startableRunners.isEmpty)
            Button { store.stopAll() } label: { Label("Stop All", systemImage: "stop.fill") }
                .disabled(store.runningRunners.isEmpty)
            Button { store.stopAll(force: true) } label: { Label("Force Stop All", systemImage: "xmark.octagon") }
                .disabled(store.runningRunners.isEmpty)
            Divider()
            Button { Task { await store.updateAll() } } label: { Label("Check & Update All", systemImage: "arrow.down.circle") }
                .disabled(store.isInFlight("update-all"))
        } label: {
            Label("All Actions", systemImage: "ellipsis.circle")
        }
        .help("Start, stop, or update every runner")
        .disabled(store.runners.count < 2)
    }
}

/// A compact sidebar row for one runner.
private struct RunnerSidebarRow: View {
    @Environment(RunnerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let instance: RunnerInstance

    private var status: RunnerLiveStatus { store.status(for: instance) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.tintColor)
                .symbolEffect(.pulse, options: .nonRepeating, isActive: status.busy && !reduceMotion)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(instance.displayName).lineLimit(1)
                Text(instance.scopeLabel ?? "Not configured")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if status.busy {
                Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if status.isRunning {
                Button("Stop Runner") { store.stop(instance) }
                    .disabled(!store.canStop(instance))
            } else if status.state != .notConfigured {
                Button("Start Runner") { store.start(instance) }
                    .disabled(!store.canStart(instance))
            }
            if let url = instance.gitHubURL {
                Divider()
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([instance.directory])
            }
            Divider()
            Button("Remove from List", role: .destructive) { store.removeDirectory(instance) }
        }
    }
}

enum RunnerDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview", logs = "Logs", updates = "Updates"
    var id: String { rawValue }
}

/// The detail pane for a single runner: Overview / Logs / Updates tabs + toolbar actions.
private struct RunnerWindowDetail: View {
    @Environment(RunnerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let instance: RunnerInstance

    @Binding var tab: RunnerDetailTab
    @Binding var logSource: LogConsoleView.Source
    @Binding var followLogs: Bool
    @State private var confirmUnregister = false
    @State private var showLabels = false

    private var status: RunnerLiveStatus { store.status(for: instance) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(RunnerMotion.content(reduceMotion: reduceMotion), value: tab)
            .navigationTitle(instance.displayName)
            .navigationSubtitle(instance.scopeLabel ?? "Not configured")
            .toolbar { toolbarContent }
            .confirmationDialog("Unregister \(instance.displayName)?",
                                isPresented: $confirmUnregister, titleVisibility: .visible) {
                Button("Unregister from GitHub", role: .destructive) { store.unregister(instance) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the runner registration from \(instance.scopeLabel ?? "GitHub") and clears its local config. The folder is kept.")
            }
            .sheet(isPresented: $showLabels) {
                NavigationStack {
                    LabelEditorView(instance: instance)
                        .frame(width: 420, height: 460)
                        .navigationTitle("Labels — \(instance.displayName)")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showLabels = false } } }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview:
            ScrollView {
                RunnerDetailView(
                    instance: instance,
                    showLog: { tab = .logs },
                    showUpdates: { tab = .updates },
                    showsPrimaryControl: false,
                    showsActionButtons: false
                )
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(20)
            }
        case .logs:
            LogConsoleView(instance: instance, fixedHeight: nil, source: $logSource, autoScroll: $followLogs)
        case .updates:
            UpdatesView(instance: instance, fixedHeight: nil).id(instance.id)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(RunnerDetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            primaryButton
            Menu {
                if let url = instance.gitHubURL {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([instance.directory])
                }
                if instance.isConfigured {
                    Divider()
                    Button("Edit Labels…") { showLabels = true }
                    Button("Unregister from GitHub…", role: .destructive) { confirmUnregister = true }
                        .disabled(store.mutationUnavailableReason(for: instance) != nil)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if status.state == .notConfigured {
            EmptyView()
        } else if status.isRunning {
            Button { store.stop(instance) } label: { Label(status.state == .starting ? "Starting…" : "Stop", systemImage: "stop.fill") }
                .disabled(!store.canStop(instance))
                .help(store.mutationUnavailableReason(for: instance) ?? "Stop runner")
        } else {
            Button { store.start(instance) } label: { Label(status.state == .stopping ? "Stopping…" : "Start", systemImage: "play.fill") }
                .disabled(!store.canStart(instance))
                .help(store.mutationUnavailableReason(for: instance) ?? "Start runner")
        }
    }
}
