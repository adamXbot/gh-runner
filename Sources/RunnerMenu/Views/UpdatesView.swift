import SwiftUI
import AppKit

/// Checks for, verifies, and applies runner updates for one runner.
struct UpdatesView: View {
    @Environment(RunnerStore.self) private var store
    let instance: RunnerInstance
    /// Fixed height for the menu-bar panel; pass nil in a resizable window to fill.
    var fixedHeight: CGFloat? = 460

    @State private var info: UpdateInfo?
    @State private var checking = false
    @State private var applying = false
    @State private var progress: Double = 0
    @State private var allowUnverified = false
    @State private var confirmUpdate = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if checking && info == nil {
                    HStack { ProgressView().controlSize(.small); Text("Checking for updates…") }
                        .font(.callout).foregroundStyle(.secondary)
                } else if let info {
                    versionCard(info)
                    hashCard(info)
                    if let notes = info.latest.body, !notes.isEmpty {
                        releaseNotes(info)
                    }
                    actions(info)
                } else {
                    Text("Couldn't check for updates.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await check() } }
                }
            }
            .padding(14)
        }
        .frame(height: fixedHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: fixedHeight == nil ? .infinity : nil)
        .task { await check() }
        .confirmationDialog(
            "Update \(instance.displayName) to \(info?.latestVersion ?? "the latest version")?",
            isPresented: $confirmUpdate, titleVisibility: .visible
        ) {
            Button("Download & Update") { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The runner will be stopped, the package replaced, and (if it was running) restarted.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
            Text(instance.displayName).font(.headline)
            Spacer()
            Button {
                Task { await check() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(checking || applying)
            .help("Re-check")
        }
    }

    private func versionCard(_ info: UpdateInfo) -> some View {
        VStack(spacing: 4) {
            StatRow(label: "Installed", value: info.currentVersion.map { "v\($0)" } ?? "unknown", mono: true)
            StatRow(label: "Latest", value: "v\(info.latestVersion)", mono: true)
            if let released = info.latest.publishedDate {
                StatRow(label: "Released", value: released.formatted(.relative(presentation: .numeric)))
            }
            HStack {
                Spacer()
                if info.updateAvailable {
                    Label("Update available", systemImage: "arrow.up.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func hashCard(_ info: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: info.hasVerifiableHash ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(info.hasVerifiableHash ? .green : .orange)
                Text(info.hasVerifiableHash ? "SHA-256 will be verified" : "No published SHA-256 found")
                    .font(.caption.weight(.medium))
            }
            if let hash = info.expectedSHA256 {
                Text(hash).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            } else {
                Toggle("Allow update without verification (not recommended)", isOn: $allowUnverified)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }
            Text("\(info.asset.name) · \(Updater.humanByteSize(info.asset.size))")
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func releaseNotes(_ info: UpdateInfo) -> some View {
        DisclosureGroup {
            Text(String(info.latest.body?.prefix(1200) ?? ""))
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            HStack {
                Text("Release notes").font(.caption.weight(.semibold))
                Spacer()
                Link("Open on GitHub", destination: URL(string: info.latest.htmlUrl)!)
                    .font(.caption2)
            }
        }
    }

    private func actions(_ info: UpdateInfo) -> some View {
        VStack(spacing: 8) {
            if applying {
                ProgressView(value: progress) { Text("Updating…").font(.caption) }
            }
            Button {
                confirmUpdate = true
            } label: {
                Label(info.updateAvailable ? "Update to v\(info.latestVersion)" : "Reinstall v\(info.latestVersion)",
                      systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(applying || (!info.hasVerifiableHash && !allowUnverified))
        }
    }

    // MARK: - Logic

    private func check() async {
        checking = true
        defer { checking = false }
        info = await store.checkForUpdate(instance)
    }

    private func apply() async {
        guard let info else { return }
        applying = true
        progress = 0
        defer { applying = false }
        let ok = await store.applyUpdate(
            instance, info: info, allowUnverified: allowUnverified,
            progress: { frac in Task { @MainActor in progress = frac } }
        )
        if ok { await check() }
    }
}
