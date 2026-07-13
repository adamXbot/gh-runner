import SwiftUI
import AppKit
import RunnerAgentProtocol

/// First-launch setup. It makes the job-owning account an explicit decision and
/// imports or discovers existing installations before normal controls appear.
struct OnboardingView: View {
    @Environment(RunnerStore.self) private var store

    private enum Step: Int, Hashable {
        case account
        case discovery
    }

    @State private var step: Step = .account
    @State private var selectedRunnerIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .account: accountStep
                case .discovery: discoveryStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 540)
        .task(id: step) {
            guard step == .discovery else { return }
            await scanAndSelectNewRunners()
        }
        .task { await store.refreshRunnerAgent() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Set up Runner Menu").font(.title2.weight(.semibold))
                Text(step == .account
                     ? "Choose which macOS account will own jobs and workspaces."
                     : "Discover existing GitHub Actions runners without changing them.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Step \(step.rawValue + 1) of 2")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private var accountStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Where should runner jobs execute?")
                    .font(.title3.weight(.semibold))

                executionCard(
                    mode: .currentAccount,
                    icon: "person.crop.circle",
                    title: "This account",
                    badge: "Full control available",
                    detail: "Run jobs as \(NSFullUserName()) (\(NSUserName())). Existing local start, stop, registration, service, and update controls remain available."
                )

                executionCard(
                    mode: .dedicatedAccount,
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Dedicated runner account",
                    badge: "Read-only agent phase",
                    detail: "Prepare a signed Runner Agent under the standard account named runner. This phase observes and discovers only; it does not launch jobs yet."
                )

                if store.executionMode == .dedicatedAccount { runnerAgentSetupPanel }
            }
            .padding(28)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
    }

    private func executionCard(
        mode: RunnerExecutionMode,
        icon: String,
        title: String,
        badge: String,
        detail: String
    ) -> some View {
        let selected = store.executionMode == mode
        return Button {
            store.executionMode = mode
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 25))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(title).font(.headline)
                        Text(badge)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(mode == .currentAccount ? Color.green : Color.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.1), in: Capsule())
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
            }
            .padding(16)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var runnerAgentSetupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Runner Agent", systemImage: store.runnerAgentReady ? "lock.shield.fill" : "lock.shield")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(store.runnerAgentReady ? Color.green : Color.orange)
                Spacer()
                if store.isWorkingWithRunnerAgent { ProgressView().controlSize(.small) }
                Text(store.runnerAgentRegistrationState.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if !store.runnerAccountExists {
                Text("Create a standard macOS account with the short name ‘runner’ in System Settings › Users & Groups first.")
                    .font(.caption).foregroundStyle(.orange)
            } else if store.runnerAgentReady, let health = store.runnerAgentHealth {
                Text("Connected as \(health.accountName) (UID \(health.effectiveUserID)) using protocol v\(health.protocolVersion).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Register the bundled LaunchDaemon, approve it in Login Items, then verify the signed XPC connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !store.runnerAgentHasProductionSigningIdentity {
                Text("This ad-hoc development build verifies packaging only. macOS requires a Developer ID-signed and notarized app before approving a bundled LaunchDaemon.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let error = store.runnerAgentError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }

            HStack {
                switch store.runnerAgentRegistrationState {
                case .notRegistered, .notFound:
                    Button("Register Runner Agent") {
                        Task { await store.registerRunnerAgent() }
                    }
                    .disabled(!store.runnerAccountExists || store.isWorkingWithRunnerAgent)
                case .requiresApproval:
                    Button("Open Login Items Settings") { store.openRunnerAgentSystemSettings() }
                case .enabled, .unknown:
                    EmptyView()
                }
                Button("Refresh Status") { Task { await store.refreshRunnerAgent() } }
                    .disabled(store.isWorkingWithRunnerAgent)
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var discoveryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Existing runners").font(.title3.weight(.semibold))
                    Text(discoveryDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await scanAndSelectNewRunners() }
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .disabled(discoveryInProgress)
            }

            Group {
                if store.executionMode == .dedicatedAccount {
                    dedicatedDiscoveryContent
                } else {
                    currentAccountDiscoveryContent
                }
            }
            .frame(minHeight: 250)
            .background(.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

            if store.executionMode == .currentAccount {
                Button {
                    chooseRunnerFolder()
                } label: {
                    Label("Choose Runner Folder…", systemImage: "folder.badge.plus")
                }
            } else {
                Label(
                    "Discovery is active through the runner account. Lifecycle controls remain disabled in this read-only phase.",
                    systemImage: "eye"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: 840)
    }

    private var discoveryDescription: String {
        if store.executionMode == .dedicatedAccount {
            return "The agent searches only its own home and returns runner-owned installations over authenticated XPC."
        }
        return "Scans this account, /Users/Shared, saved folders, and visible processes. Nothing is imported until you finish setup."
    }

    private var discoveryInProgress: Bool {
        store.executionMode == .dedicatedAccount
            ? store.isWorkingWithRunnerAgent
            : store.isDiscoveringRunners
    }

    @ViewBuilder
    private var currentAccountDiscoveryContent: some View {
        if store.isDiscoveringRunners && store.discoveredRunners.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking for runner installations…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.discoveredRunners.isEmpty {
            ContentUnavailableView(
                "No existing runners found",
                systemImage: "magnifyingglass",
                description: Text("Finish setup and create a runner later, or choose a folder manually.")
            )
        } else {
            List(store.discoveredRunners) { runner in discoveredRunnerRow(runner) }
                .listStyle(.inset)
                .overlay(alignment: .topTrailing) {
                    if store.isDiscoveringRunners {
                        ProgressView().controlSize(.small).padding(10)
                    }
                }
        }
    }

    @ViewBuilder
    private var dedicatedDiscoveryContent: some View {
        if store.isWorkingWithRunnerAgent && store.agentDiscoveredRunners.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Asking Runner Agent to discover installations…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !store.runnerAgentReady {
            ContentUnavailableView(
                "Runner Agent unavailable",
                systemImage: "exclamationmark.shield",
                description: Text(store.runnerAgentError ?? "Return to the previous step and complete approval.")
            )
        } else if store.agentDiscoveredRunners.isEmpty {
            ContentUnavailableView(
                "No existing runners found",
                systemImage: "magnifyingglass",
                description: Text("The agent searched its home directory without changing anything.")
            )
        } else {
            List(store.agentDiscoveredRunners) { runner in agentRunnerRow(runner) }
                .listStyle(.inset)
        }
    }

    private func discoveredRunnerRow(_ runner: RunnerInstance) -> some View {
        let managed = store.isManagedRunner(runner)
        return Toggle(isOn: Binding(
            get: { managed || selectedRunnerIDs.contains(runner.id) },
            set: { selected in
                if selected { selectedRunnerIDs.insert(runner.id) }
                else { selectedRunnerIDs.remove(runner.id) }
            }
        )) {
            HStack(spacing: 10) {
                Image(systemName: runner.isConfigured ? "folder.fill.badge.gearshape" : "folder.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(runner.displayName).font(.callout.weight(.medium))
                        if managed {
                            Text("Already added").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    Text(runner.scopeLabel ?? "Runner software is installed but not configured")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(runner.directory.path)
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.vertical, 4)
        }
        .toggleStyle(.checkbox)
        .disabled(managed)
    }

    private func agentRunnerRow(_ runner: RunnerAgentRunnerRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: runner.configured ? "folder.fill.badge.gearshape" : "folder.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(runner.displayName).font(.callout.weight(.medium))
                Text(runner.scopeLabel ?? "Runner software is installed but not configured")
                    .font(.caption).foregroundStyle(.secondary)
                Text(runner.directoryPath)
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text("UID \(runner.ownerUserID)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            if step == .discovery { Button("Back") { step = .account } }
            Spacer()
            if step == .account {
                Button("Continue") { step = .discovery }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.executionMode == .dedicatedAccount && !store.runnerAgentReady)
            } else {
                Button(store.executionMode == .dedicatedAccount ? "Finish Read-Only Setup" : "Finish Setup") {
                    _ = store.completeOnboarding(selectedRunnerIDs: selectedRunnerIDs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(discoveryInProgress || (store.executionMode == .dedicatedAccount && !store.runnerAgentReady))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func scanAndSelectNewRunners() async {
        if store.executionMode == .dedicatedAccount {
            await store.refreshRunnerAgent()
            await store.discoverDedicatedRunners()
            return
        }
        await store.discoverExistingRunners()
        selectedRunnerIDs.formUnion(
            store.discoveredRunners.filter { !store.isManagedRunner($0) }.map(\.id)
        )
    }

    private func chooseRunnerFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose an existing GitHub Actions runner folder"
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if store.addDiscoveryCandidate(url) {
            selectedRunnerIDs.insert(url.standardizedFileURL.path)
        }
    }
}
