import SwiftUI
import AppKit

/// Adds runners that already exist on this Mac to the monitored list.
///
/// Deliberately separate from `RegisterRunnerView`. That view *registers* — it
/// asks GitHub for your admin repositories, takes a name and labels, and runs
/// `config.sh`. Its "Existing folder" mode means "register this folder with
/// GitHub", which reads as the same thing but is not: a runner already bound to
/// a repository and already taking jobs needs none of it, and being asked to
/// pick a repository for one is alarming rather than merely confusing.
///
/// This view touches GitHub not at all. It scans, lists what it found, and adds
/// the ones you tick to the list the app watches.
struct FindRunnersView: View {
    @Environment(RunnerStore.self) private var store
    var onDone: () -> Void

    @State private var selected: Set<String> = []
    @State private var didScan = false

    private var candidates: [RunnerInstance] { store.discoveredRunners }
    private var unmanaged: [RunnerInstance] {
        candidates.filter { !store.isManagedRunner($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if store.isDiscoveringRunners && candidates.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if candidates.isEmpty && didScan {
                ContentUnavailableView(
                    "No runners found",
                    systemImage: "magnifyingglass",
                    description: Text("Nothing running, and nothing in the usual folders. If a runner lives somewhere unusual, add its folder directly.")
                )
                .frame(minHeight: 140)
            } else {
                List {
                    ForEach(candidates) { runner in row(runner) }
                }
                .listStyle(.inset)
                .frame(minHeight: 200, maxHeight: 320)
            }

            footer
        }
        .padding(16)
        .task {
            await store.discoverExistingRunners()
            // Pre-tick everything not already monitored: the reason you opened
            // this is almost always "add what's here".
            selected.formUnion(unmanaged.map(\.id))
            didScan = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Runners on this Mac")
                .font(.title3.weight(.semibold))
            Text("Found by looking at running processes and the usual install folders — including runners owned by other macOS accounts. Nothing here contacts GitHub or changes a registration.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ runner: RunnerInstance) -> some View {
        let managed = store.isManagedRunner(runner)
        return Toggle(isOn: Binding(
            get: { managed || selected.contains(runner.id) },
            set: { on in
                if on { selected.insert(runner.id) } else { selected.remove(runner.id) }
            }
        )) {
            HStack(spacing: 10) {
                Image(systemName: runner.isConfigured ? "folder.fill.badge.gearshape" : "folder.fill")
                    .foregroundStyle(runner.isConfigured ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(runner.displayName).font(.callout.weight(.medium))
                        if !runner.isOwnedByCurrentUser, let account = runner.ownerAccountName {
                            Text(account)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        if managed {
                            Text("already added")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(runner.scopeLabel ?? "Not registered to a repository")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(runner.directory.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(managed)
    }

    private var footer: some View {
        HStack {
            Button("Choose Folder…") { chooseFolder() }
                .help("For a runner in a location the scan does not cover")
            Spacer()
            Button("Cancel", role: .cancel) { onDone() }
            Button(addTitle) {
                store.addDiscoveredRunners(withIDs: selected)
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var addTitle: String {
        switch selected.count {
        case 0: return "Add"
        case 1: return "Add 1 Runner"
        default: return "Add \(selected.count) Runners"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.title = "Choose a runner folder"
        panel.prompt = "Add"
        // Start where runners actually are, not wherever the last unrelated
        // panel happened to leave the user.
        panel.directoryURL = suggestedStartDirectory()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where store.addDiscoveryCandidate(url) {
            selected.insert(url.standardizedFileURL.path)
        }
    }

    /// Prefer the parent of a runner we already know about — on a fleet host
    /// they sit together — then the conventional locations.
    private func suggestedStartDirectory() -> URL? {
        if let known = candidates.first?.directory.deletingLastPathComponent(),
           FileManager.default.fileExists(atPath: known.path) {
            return known
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for candidate in [home.appendingPathComponent("runners"),
                          home.appendingPathComponent("actions-runner"),
                          URL(fileURLWithPath: "/Users", isDirectory: true)]
        where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return home
    }
}
