import SwiftUI
import RunnerAgentProtocol

/// Phase 2 dedicated-account surface. It intentionally exposes observation and
/// discovery only; lifecycle controls appear only after the XPC mutation API exists.
struct DedicatedRunnerAgentView: View {
    @Environment(RunnerStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    phaseNotice
                    agentStatus
                    discoveredRunners
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(28)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await store.refreshAll() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: store.runnerAgentReady ? "lock.shield.fill" : "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(store.runnerAgentReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dedicated Runner Agent").font(.title2.weight(.semibold))
                Text("The agent runs as ‘runner’; job launching remains disabled in this phase.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isWorkingWithRunnerAgent { ProgressView().controlSize(.small) }
            Text(store.runnerAgentRegistrationState.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.12), in: Capsule())
        }
        .padding(24)
    }

    private var phaseNotice: some View {
        Label {
            Text("Read-only agent phase: connection health and runner discovery are active. Start, stop, registration, updates, and log access remain disabled until lifecycle control moves into the agent.")
        } icon: {
            Image(systemName: "eye.fill")
        }
        .font(.callout)
        .foregroundStyle(.blue)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private var agentStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Agent status")
            VStack(spacing: 8) {
                StatRow(label: "Service", value: store.runnerAgentRegistrationState.label)
                StatRow(label: "Required account", value: store.runnerAccountExists ? "runner exists" : "runner account missing",
                        valueColor: store.runnerAccountExists ? .green : .orange)
                if let health = store.runnerAgentHealth {
                    StatRow(label: "Connected as", value: "\(health.accountName) · UID \(health.effectiveUserID)")
                    StatRow(label: "Home", value: health.homeDirectory, mono: true)
                    StatRow(label: "Protocol", value: "v\(health.protocolVersion)")
                    StatRow(label: "Signing", value: health.signingIdentity)
                }
                if let error = store.runnerAgentError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var discoveredRunners: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Runners owned by runner")
                Spacer()
                Text("\(store.agentDiscoveredRunners.count) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !store.runnerAgentReady {
                ContentUnavailableView(
                    "Runner Agent unavailable",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("Review setup or approve the service in System Settings.")
                )
                .frame(minHeight: 170)
            } else if store.agentDiscoveredRunners.isEmpty {
                ContentUnavailableView(
                    "No existing runners found",
                    systemImage: "shippingbox",
                    description: Text("The agent searched its home directory without changing anything.")
                )
                .frame(minHeight: 170)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.agentDiscoveredRunners) { runner in
                        agentRunnerRow(runner)
                        if runner.id != store.agentDiscoveredRunners.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func agentRunnerRow(_ runner: RunnerAgentRunnerRecord) -> some View {
        HStack(spacing: 11) {
            Image(systemName: runner.configured ? "folder.fill.badge.gearshape" : "folder.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(runner.displayName).font(.callout.weight(.medium))
                Text(runner.scopeLabel ?? "Installed but not configured")
                    .font(.caption).foregroundStyle(.secondary)
                Text(runner.directoryPath)
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text("UID \(runner.ownerUserID)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Review Setup…") { store.reviewOnboarding() }
            Button("Open Login Items Settings") { store.openRunnerAgentSystemSettings() }
            Spacer()
            Button {
                Task {
                    await store.refreshRunnerAgent()
                    await store.discoverDedicatedRunners()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isWorkingWithRunnerAgent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

struct DedicatedRunnerAgentMenuView: View {
    @Environment(RunnerStore.self) private var store
    var openWindow: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: store.runnerAgentReady ? "lock.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(store.runnerAgentReady ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dedicated Runner Agent").font(.headline)
                    Text(store.runnerAgentReady ? "Connected as runner · read-only" : store.runnerAgentRegistrationState.label)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isWorkingWithRunnerAgent { ProgressView().controlSize(.small) }
            }

            HStack {
                Label("\(store.agentDiscoveredRunners.count) runners discovered", systemImage: "shippingbox")
                    .font(.callout)
                Spacer()
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isWorkingWithRunnerAgent)
            }
            .padding(10)
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            Text("Lifecycle controls are disabled until the next agent phase.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            HStack {
                Button("Open Window", action: openWindow)
                Button("Settings", action: openSettings)
                Spacer()
                Button("Quit", role: .destructive) { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 388)
        .task { await store.refreshAll() }
    }
}
