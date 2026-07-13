import SwiftUI
import AppKit

/// One runner shown as a selectable card.
struct RunnerRowView: View {
    @Environment(RunnerStore.self) private var store
    let instance: RunnerInstance
    let isSelected: Bool
    @State private var confirmUnregister = false

    private var status: RunnerLiveStatus { store.status(for: instance) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbolName)
                .font(.title3)
                .foregroundStyle(status.tintColor)
                .symbolEffect(.pulse, isActive: status.busy)
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
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            statusTrailing
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : .clear)
        )
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(instance.displayName), \(status.state.label)\(status.busy ? ", busy" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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

    @ViewBuilder
    private var statusTrailing: some View {
        if status.state == .notConfigured {
            Text("Configure").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                if status.busy {
                    Text("job").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                primaryButton
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        let starting = store.isInFlight("start-\(instance.id)")
        let stopping = store.isInFlight("stop-\(instance.id)")
        if status.isRunning {
            Button {
                store.stop(instance)
            } label: {
                if stopping { ProgressView().controlSize(.small) }
                else { Image(systemName: "stop.fill") }
            }
            .buttonStyle(.borderless)
            .help("Stop runner")
            .disabled(stopping)
            .accessibilityLabel("Stop \(instance.displayName)")
        } else {
            Button {
                store.start(instance)
            } label: {
                if starting { ProgressView().controlSize(.small) }
                else { Image(systemName: "play.fill") }
            }
            .buttonStyle(.borderless)
            .help("Start runner")
            .disabled(starting)
            .accessibilityLabel("Start \(instance.displayName)")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if status.isRunning {
            Button("Stop Runner") { store.stop(instance) }
            Button("Force Stop") { store.stop(instance, force: true) }
        } else if status.state != .notConfigured {
            Button("Start Runner") { store.start(instance) }
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
        }
        Button("Remove from List", role: .destructive) { store.removeDirectory(instance) }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
