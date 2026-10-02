import SwiftUI
import AppKit

/// One runner shown as a selectable card.
struct RunnerRowView: View {
    @Environment(RunnerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let instance: RunnerInstance
    let isSelected: Bool
    /// In the all-runners overview, the row reveals details in place instead of
    /// changing the selected runner. Start/Stop remains a separate button.
    var expansion: Binding<Bool>? = nil
    @State private var confirmUnregister = false

    private var status: RunnerLiveStatus { store.status(for: instance) }
    private var accessibilitySummary: String {
        var parts = [instance.displayName, status.state.label]
        if status.busy { parts.append("Busy") }
        if expansion != nil {
            if status.busy { parts.append(status.currentJob ?? "Job in progress") }
            if let phase = store.updatePhases[instance.id] { parts.append(phase.label) }
            if let error = status.lastError { parts.append(error) }
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if let expansion { expansion.wrappedValue.toggle() }
                else { store.selectedRunnerID = instance.id }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    selectionLabel
                    if expansion != nil { activitySummary }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(RunnerButtonStyle(surface: .card, cornerRadius: 10))
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityValue(expansion.map { $0.wrappedValue ? "Expanded" : "Collapsed" } ?? "")
            .help("\(expansion?.wrappedValue == true ? "Hide" : "Show") details for \(instance.displayName)")

            if status.state != .notConfigured {
                primaryButton
                    .padding(.trailing, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : .clear)
                .allowsHitTesting(false)
        )
        .animation(RunnerMotion.content(reduceMotion: reduceMotion), value: isSelected)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            "Unregister \(instance.displayName)?",
            isPresented: $confirmUnregister,
            titleVisibility: .visible
        ) {
            Button("Unregister from GitHub", role: .destructive) {
                store.unregister(instance)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the runner registration from \(instance.scopeLabel ?? "GitHub") and clears its local configuration. The runner folder and its files will be kept.")
        }
    }

    private var selectionLabel: some View {
        HStack(spacing: 10) {
            if let expansion {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expansion.wrappedValue ? 90 : 0))
                    .accessibilityHidden(true)
            }
            Image(systemName: status.symbolName)
                .font(.title3)
                .foregroundStyle(status.tintColor)
                // A busy transition needs one pulse; repeating it keeps redrawing the window.
                .symbolEffect(.pulse, options: .nonRepeating, isActive: status.busy && !reduceMotion)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(instance.scopeLabel ?? "Not configured")
                        .lineLimit(1)
                    if let v = instance.installedVersion {
                        Text("· v\(v)").foregroundStyle(.tertiary)
                    }
                    if !instance.isOwnedByCurrentUser, let account = instance.ownerAccountName {
                        // The account a runner executes as is the security
                        // boundary, so name it rather than leaving the row
                        // looking like every other one.
                        Label(account, systemImage: "person.crop.circle")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.15))
                            )
                            .help("Runs as the macOS account “\(account)”. This app cannot start or stop it — see the detail pane.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            statusTrailing
        }
    }

    private var activitySummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(status.state == .running ? (status.busy ? "Running job" : "Idle") : status.state.label)
                    .foregroundStyle(status.tintColor)
                if let phase = store.updatePhases[instance.id] {
                    Text("· \(phase.label)").foregroundStyle(.secondary)
                } else if store.runnerOperations.contains(instance.id) {
                    Text("· Working…").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if status.busy {
                Text(status.currentJob ?? "Job in progress")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(status.currentJob ?? "Job in progress")
            }
            if let error = status.lastError {
                Text(error).foregroundStyle(.red).lineLimit(2).help(error)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var statusTrailing: some View {
        if status.state == .notConfigured {
            Text("Configure").font(.caption).foregroundStyle(.secondary)
        } else if status.busy {
            Text("job").font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        let starting = store.isInFlight("start-\(instance.id)")
        let stopping = store.isInFlight("stop-\(instance.id)")
        // A runner owned by another account is observable but not operable:
        // svc.sh loads a LaunchAgent into the owner's GUI launchd domain, which
        // this process cannot address. Offering a button that always fails with
        // "Load failed: 5: Input/output error" is worse than offering none.
        let foreign = !instance.isOwnedByCurrentUser
        if status.isRunning {
            Button {
                store.stop(instance)
            } label: {
                if stopping { ProgressView().controlSize(.small) }
                else { Image(systemName: "stop.fill") }
            }
            .buttonStyle(RunnerButtonStyle())
            .frame(width: 28, height: 28)
            .help(foreign ? foreignControlExplanation : (store.mutationUnavailableReason(for: instance) ?? "Stop \(instance.displayName)"))
            .disabled(!store.canStop(instance))
            .accessibilityLabel("Stop \(instance.displayName)")
        } else {
            Button {
                store.start(instance)
            } label: {
                if starting { ProgressView().controlSize(.small) }
                else { Image(systemName: "play.fill") }
            }
            .buttonStyle(RunnerButtonStyle())
            .frame(width: 28, height: 28)
            .help(foreign ? foreignControlExplanation : (store.mutationUnavailableReason(for: instance) ?? "Start \(instance.displayName)"))
            .disabled(!store.canStart(instance))
            .accessibilityLabel("Start \(instance.displayName)")
        }
    }

    private var foreignControlExplanation: String {
        let account = instance.ownerAccountName ?? "another account"
        return """
        Runs as “\(account)”, so this app cannot start or stop it. \
        Its service belongs to that account's login session — sign in as \
        \(account) and use svc.sh there.
        """
    }

    @ViewBuilder
    private var contextMenu: some View {
        if !instance.isOwnedByCurrentUser {
            Text(foreignControlExplanation)
        } else if status.isRunning {
            Button("Stop Runner") { store.stop(instance) }.disabled(!store.canStop(instance))
            Button("Force Stop") { store.stop(instance, force: true) }.disabled(!store.canStop(instance))
        } else if status.state != .notConfigured {
            Button("Start Runner") { store.start(instance) }.disabled(!store.canStart(instance))
        }
        Divider()
        if let url = instance.gitHubURL {
            Button("Open on GitHub") { NSWorkspace.shared.open(url) }
            Button("Copy Repository URL") { copy(url.absoluteString) }
        }
        Button("Copy Runner Name") { copy(instance.displayName) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([instance.directory])
        }
        Divider()
        if instance.isConfigured {
            Button("Unregister from GitHub…", role: .destructive) {
                confirmUnregister = true
            }
            .disabled(store.mutationUnavailableReason(for: instance) != nil)
        }
        Button("Remove from List", role: .destructive) { store.removeDirectory(instance) }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
