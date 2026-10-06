import SwiftUI
import AppKit

// The Settings window is the shared `SurfaceSettings` scaffold (see
// RunnerMenuApp): toolbar tabs, General first, Updates last. Each pane here is
// a set of grouped-form sections. Explanations live behind ⓘ buttons; a caption
// under a row is reserved for live status and warnings.

/// General: startup, refreshing, recent jobs and the menu bar icon.
struct GeneralSettingsPane: View {
    @Environment(RunnerStore.self) private var store
    let app: SurfaceApp
    @ObservedObject var menuBar: SurfaceMenuBarPreference

    var body: some View {
        @Bindable var store = store
        Section("Startup") {
            SurfaceLaunchAtLoginRow(app: app)
        }
        Section("Refreshing") {
            Stepper(value: $store.pollInterval, in: 2...30, step: 1) {
                Text("Refresh every \(Int(store.pollInterval)) seconds")
            }
        }
        Section("Recent jobs") {
            Picker(selection: $store.jobClickAction) {
                ForEach(JobClickAction.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                SurfaceInfoLabel(
                    "Clicking a recent job",
                    info: "Open on GitHub opens the job's Actions run, or the repository's Actions page when the run cannot be found. View local logs reveals the job's Worker log in Finder. The job's context menu offers both."
                )
            }
            .pickerStyle(.segmented)
        }
        SurfaceMenuBarSection(app: app, preference: menuBar, icons: MenuBarGlyph.icons) {
            EmptyView()
        }
    }
}

/// Runners: how they start, where new ones go, and the folders being watched.
struct RunnerSettingsPane: View {
    @Environment(RunnerStore.self) private var store
    @State private var discoveryMessage: String?

    var body: some View {
        @Bindable var store = store
        Section("Starting runners") {
            Picker(selection: $store.startMode) {
                Text("Detached run.sh").tag(StartMode.supervised)
                Text("launchd service").tag(StartMode.service)
            } label: {
                SurfaceInfoLabel(
                    "Start runners using",
                    info: "Detached run.sh runs ./run.sh with nohup: the runner survives quitting Runner Menu, but launchd does not manage it. launchd service installs a LaunchAgent with svc.sh: the runner keeps going after you quit and starts when you log in."
                )
            }
            .pickerStyle(.segmented)
            if store.executionMode == .dedicatedAccount {
                Text("Runners are only monitored in dedicated-account mode; they are not started from here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if store.executionMode == .currentAccount {
            Section("New runners") {
                LabeledContent {
                    HStack {
                        Text(store.runnersBaseDirectoryPath.isEmpty ? "Not set" : store.runnersBaseDirectoryPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(store.runnersBaseDirectoryPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            if let url = chooseRunnerFolder(title: "Choose a folder to hold new runners", prompt: "Use") {
                                store.runnersBaseDirectoryPath = url.standardizedFileURL.path
                            }
                        }
                        if !store.runnersBaseDirectoryPath.isEmpty {
                            Button("Clear") { store.runnersBaseDirectoryPath = "" }
                        }
                    }
                } label: {
                    SurfaceInfoLabel(
                        "Runners folder",
                        info: "New runners are created inside this folder, named actions-runner-<repo> so they are easy to tell apart. When it is not set, ~/actions-runners is used. A location outside Documents, Desktop and Downloads avoids macOS privacy prompts."
                    )
                }
            }

            Section("Runner folders") {
                if store.runners.isEmpty {
                    Text("No folders added.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.runners) { instance in
                    LabeledContent {
                        SurfaceDestructiveButton(
                            "Remove…",
                            gate: .confirm,
                            question: "Remove \(instance.displayName) from the list?",
                            consequence: "Runner Menu stops watching this folder. The runner, its registration and its files are not changed.",
                            confirmTitle: "Remove"
                        ) {
                            store.removeDirectory(instance)
                        }
                        .controlSize(.small)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(instance.displayName)
                                Text(instance.directory.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: instance.isConfigured ? "folder.fill.badge.gearshape" : "folder")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Add Folder…") {
                        if let url = chooseRunnerFolder() { store.addDirectory(url) }
                    }
                    Button("Discover Existing Runners") {
                        Task {
                            let existing = Set(store.runnerDirectoryPaths)
                            await store.discoverExistingRunners()
                            let newIDs = Set(store.discoveredRunners.map(\.id)).subtracting(existing)
                            store.addDiscoveredRunners(withIDs: newIDs)
                            discoveryMessage = newIDs.isEmpty
                                ? "No additional runner installations found."
                                : "Added \(newIDs.count) existing runner\(newIDs.count == 1 ? "" : "s")."
                        }
                    }
                    .disabled(store.isDiscoveringRunners)
                }
                if store.isDiscoveringRunners {
                    ProgressView("Looking for runner installations…")
                        .controlSize(.small)
                } else if let discoveryMessage {
                    Text(discoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseRunnerFolder(title: String = "Select a runner folder",
                                    prompt: String = "Add") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = title
        panel.prompt = prompt
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Accounts: the GitHub CLI login the app works through, and the macOS account
/// that runs jobs.
struct AccountSettingsPane: View {
    @Environment(RunnerStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        Section("GitHub CLI") {
            LabeledContent {
                HStack {
                    TextField("gh executable", text: $store.ghPath)
                        .labelsHidden()
                    Button("Re-check") { Task { await store.forceAuthRecheck() } }
                }
            } label: {
                SurfaceInfoLabel(
                    "gh executable",
                    info: "The GitHub CLI Runner Menu runs for every GitHub call: sign-in status, repositories, registration tokens, runner lists and releases. A bare name is looked up on the PATH; give a full path when gh lives somewhere unusual."
                )
            }
            LabeledContent("Status") {
                GHAuthChip(auth: store.ghAuth)
            }
            if let account = store.ghAuth.account {
                Text("Signed in as \(account) · scopes: \(store.ghAuth.scopes.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let message = store.ghAuth.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        Section("Execution account") {
            LabeledContent {
                Text(store.executionMode == .currentAccount
                     ? "This account (\(NSUserName()))"
                     : "Dedicated runner account · read-only")
            } label: {
                SurfaceInfoLabel(
                    "Runner jobs",
                    info: "This account: runner processes and workspaces belong to the account you are signed in to, with full control. Dedicated runner account: the signed Runner Agent, running as the standard account named runner, answers health checks and discovers its runners; lifecycle controls stay disabled in this phase. Change the choice with Review Setup…."
                )
            }
            if store.executionMode == .dedicatedAccount {
                LabeledContent("Agent service", value: store.runnerAgentRegistrationState.label)
                if let health = store.runnerAgentHealth {
                    LabeledContent("Connected as", value: "\(health.accountName) · UID \(health.effectiveUserID)")
                    LabeledContent("Protocol", value: "v\(health.protocolVersion)")
                }
                if let error = store.runnerAgentError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    if store.runnerAgentRegistrationState == .notRegistered
                        || store.runnerAgentRegistrationState == .notFound {
                        Button("Register Agent") { Task { await store.registerRunnerAgent() } }
                            .disabled(!store.runnerAccountStatus.isReady || store.isWorkingWithRunnerAgent)
                    }
                    if store.runnerAgentRegistrationState == .requiresApproval {
                        Button("Open Login Items") { store.openRunnerAgentSystemSettings() }
                    }
                    if store.runnerAgentRegistrationState == .enabled {
                        SurfaceDestructiveButton(
                            "Unregister Agent…",
                            gate: .confirm,
                            question: "Unregister the Runner Agent?",
                            consequence: "Runner Menu stops monitoring the dedicated account's runners until the agent is registered and approved again. Runner folders and registrations are not changed.",
                            confirmTitle: "Unregister"
                        ) {
                            Task { await store.unregisterRunnerAgent() }
                        }
                        .disabled(store.isWorkingWithRunnerAgent)
                    }
                    Button("Refresh") { Task { await store.refreshRunnerAgent() } }
                        .disabled(store.isWorkingWithRunnerAgent)
                }
            }
            Button("Review Setup…") {
                store.reviewOnboarding()
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: RunnerMenuApp.windowID)
            }
        }
        .task {
            await store.forceAuthRecheck()
            await store.refreshRunnerAgent()
        }
    }
}
