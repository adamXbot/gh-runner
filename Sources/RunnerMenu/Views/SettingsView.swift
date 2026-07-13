import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(RunnerStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginStatus = LoginItem.statusDescription
    @State private var loginError: String?
    @State private var discoveryMessage: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section("General") {
                // Drive the login item from the binding's setter (not onChange) so
                // reverting `launchAtLogin` on failure can't re-enter setLoginItem.
                Toggle("Open Runner Menu at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLoginItem($0) }
                ))
                Text(loginStatus).font(.caption).foregroundStyle(.secondary)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }

                Picker("Start runners using", selection: $store.startMode) {
                    Text("Detached run.sh").tag(StartMode.supervised)
                    Text("launchd service").tag(StartMode.service)
                }
                Text(store.startMode == .service
                     ? "Installs a launchd LaunchAgent — the runner keeps going after you quit this app and starts at login."
                     : "Runs ./run.sh detached with nohup — survives quitting the app but isn't managed by launchd.")
                    .font(.caption).foregroundStyle(.secondary)
                    .opacity(store.executionMode == .currentAccount ? 1 : 0.55)


                Stepper(value: $store.pollInterval, in: 2...30, step: 1) {
                    Text("Refresh every \(Int(store.pollInterval))s")
                }

                Picker("Clicking a recent job", selection: $store.jobClickAction) {
                    ForEach(JobClickAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(store.jobClickAction == .github
                     ? "Opens the job's GitHub Actions run (or the repo's Actions page)."
                     : "Reveals the job's local Worker log in Finder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("GitHub CLI") {
                HStack {
                    TextField("gh executable", text: $store.ghPath)
                    Button("Re-check") { Task { await store.forceAuthRecheck() } }
                }
                GHAuthChip(auth: store.ghAuth)
                if let account = store.ghAuth.account {
                    Text("Signed in as \(account) · scopes: \(store.ghAuth.scopes.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let msg = store.ghAuth.message {
                    Text(msg).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Execution account") {
                LabeledContent(
                    "Runner jobs",
                    value: store.executionMode == .currentAccount
                        ? "This account (\(NSUserName()))"
                        : "Dedicated runner account · read-only"
                )
                Text(store.executionMode == .currentAccount
                     ? "Runner processes and workspaces are owned by the currently signed-in account."
                     : "The signed Runner Agent is used for health checks and discovery. Lifecycle controls remain disabled in this phase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.executionMode == .dedicatedAccount {
                    LabeledContent("Agent service", value: store.runnerAgentRegistrationState.label)
                    if let health = store.runnerAgentHealth {
                        LabeledContent("Connected as", value: "\(health.accountName) · UID \(health.effectiveUserID)")
                        LabeledContent("Protocol", value: "v\(health.protocolVersion)")
                    }
                    if let error = store.runnerAgentError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        if store.runnerAgentRegistrationState == .notRegistered
                            || store.runnerAgentRegistrationState == .notFound {
                            Button("Register Agent") { Task { await store.registerRunnerAgent() } }
                                .disabled(!store.runnerAccountExists || store.isWorkingWithRunnerAgent)
                        }
                        if store.runnerAgentRegistrationState == .requiresApproval {
                            Button("Open Login Items") { store.openRunnerAgentSystemSettings() }
                        }
                        if store.runnerAgentRegistrationState == .enabled {
                            Button("Unregister Agent", role: .destructive) {
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

            if store.executionMode == .currentAccount {
                Section("New runners") {
                LabeledContent("Runners folder") {
                    HStack {
                        Text(store.runnersBaseDirectoryPath.isEmpty ? "Not set" : store.runnersBaseDirectoryPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(store.runnersBaseDirectoryPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            if let url = chooseRunnerFolder(title: "Choose a folder to hold new runners", prompt: "Use") {
                                store.runnersBaseDirectoryPath = url.standardizedFileURL.path
                            }
                        }
                        if !store.runnersBaseDirectoryPath.isEmpty {
                            Button("Clear") { store.runnersBaseDirectoryPath = "" }
                        }
                    }
                }
                Text("New runners default into this folder, named `actions-runner-<repo>` so they're easy to identify. A location outside Documents / Desktop / Downloads avoids macOS privacy prompts.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section("Runner folders") {
                if store.runners.isEmpty {
                    Text("No folders added.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.runners) { instance in
                    HStack {
                        Image(systemName: instance.isConfigured ? "folder.fill.badge.gearshape" : "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(instance.displayName).font(.callout)
                            Text(instance.directory.path)
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.removeDirectory(instance)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove from list")
                    }
                }
                Button {
                    if let url = chooseRunnerFolder() { store.addDirectory(url) }
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                Button {
                    Task {
                        let existing = Set(store.runnerDirectoryPaths)
                        await store.discoverExistingRunners()
                        let newIDs = Set(store.discoveredRunners.map(\.id)).subtracting(existing)
                        store.addDiscoveredRunners(withIDs: newIDs)
                        discoveryMessage = newIDs.isEmpty
                            ? "No additional runner installations found."
                            : "Added \(newIDs.count) existing runner\(newIDs.count == 1 ? "" : "s")."
                    }
                } label: {
                    Label("Discover Existing Runners", systemImage: "magnifyingglass")
                }
                .disabled(store.isDiscoveringRunners)
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

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link("GitHub Actions Runner releases",
                     destination: URL(string: "https://github.com/actions/runner/releases")!)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 660)
        .navigationTitle("Runner Menu Settings")
        .task {
            await store.forceAuthRecheck()
            await store.refreshRunnerAgent()
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = LoginItem.isEnabled
        }
        loginStatus = LoginItem.statusDescription
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
