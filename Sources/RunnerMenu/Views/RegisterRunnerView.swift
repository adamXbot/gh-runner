import SwiftUI
import AppKit

/// Registers a runner: pick a GitHub target (from your admin repos), name it,
/// and either configure an existing folder or download + create a new one.
struct RegisterRunnerView: View {
    @Environment(RunnerStore.self) private var store
    var onDone: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case existing = "Existing folder"
        case new = "New runner"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .existing
    @State private var search = ""
    @State private var selectedRepo: GHRepo?
    @State private var manualTarget = ""
    @State private var showAdvanced = false
    @State private var runnerName = ""
    @State private var labels = ""
    @State private var existingDir: URL?
    @State private var reconfigure = false
    @State private var parentDir: URL?
    @State private var folderName = ""
    @State private var folderNameEdited = false
    @State private var addToGitignore = false
    @State private var isWorking = false
    @State private var downloadProgress: Double = 0
    // Advanced registration options (map to config.sh flags).
    @State private var showOptions = false
    @State private var runnerGroup = ""
    @State private var disableUpdate = false
    @State private var ephemeral = false
    @State private var noDefaultLabels = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !store.ghAuth.authenticated {
                    authWarning
                }

                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                repoSection
                Divider()
                nameSection
                optionsSection
                directorySection

                if isWorking && mode == .new {
                    ProgressView(value: downloadProgress) {
                        Text("Downloading runner package…").font(.caption)
                    }
                }

                registerButton
            }
            .padding(14)
        }
        .frame(height: 520)
        .onAppear {
            if runnerName.isEmpty { runnerName = Self.defaultRunnerName() }
            if existingDir == nil { existingDir = store.selectedRunner?.directory }
            // Default to the configured Runners folder, else ~/actions-runners — which
            // avoids macOS's Documents/Desktop/Downloads privacy prompts.
            if parentDir == nil { parentDir = store.runnersBaseDirectory ?? Self.defaultRunnersFolder }
            if folderName.isEmpty { folderName = Self.uniqueFolderName(base: suggestedFolderName, in: parentDir) }
            store.loadAdminRepos()
        }
        // Keep the new-folder name in sync with the chosen repo unless the user typed one,
        // de-duplicating against folders that already exist in the parent.
        .onChange(of: targetKey) { _, _ in
            if !folderNameEdited { folderName = Self.uniqueFolderName(base: suggestedFolderName, in: parentDir) }
        }
        // Re-evaluate the name and gitignore suggestion when the parent changes.
        .onChange(of: parentDir) { _, _ in
            if !folderNameEdited { folderName = Self.uniqueFolderName(base: suggestedFolderName, in: parentDir) }
            addToGitignore = parentIsGitRepo
        }
    }

    // MARK: - Sections

    private var authWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(store.ghAuth.message ?? "Sign in with `gh auth login` in Terminal to enable registration.")
                .font(.caption)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var repoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Repository (admin access)")
            if store.isLoadingRepos {
                HStack { ProgressView().controlSize(.small); Text("Loading your repositories…").font(.caption).foregroundStyle(.secondary) }
            } else if store.adminRepos.isEmpty {
                HStack {
                    Text("No admin repositories found.").font(.caption).foregroundStyle(.secondary)
                    Button("Reload") { store.loadAdminRepos() }.controlSize(.small)
                }
            } else {
                TextField("Filter repositories…", text: $search)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredRepos) { repo in
                            repoRow(repo)
                        }
                    }
                }
                .frame(height: 150)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            DisclosureGroup("Advanced: enter owner/repo, org, or URL", isExpanded: $showAdvanced) {
                TextField("e.g. octocat/hello-world or my-org", text: $manualTarget)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .padding(.top, 4)
                if let manualTargetError {
                    Text(manualTargetError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Text("Overrides the selection above. Use for orgs or repos you don't own.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func repoRow(_ repo: GHRepo) -> some View {
        let isSel = selectedRepo?.id == repo.id && manualTarget.isEmpty
        return HStack(spacing: 6) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(repo.fullName).font(.callout).lineLimit(1)
            Spacer()
            if isSel { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(isSel ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRepo = repo
            manualTarget = ""
            if runnerName.isEmpty { runnerName = Self.defaultRunnerName() }
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Runner")
            TextField("Runner name", text: $runnerName)
                .textFieldStyle(.roundedBorder)
            TextField("Labels (comma-separated, optional)", text: $labels)
                .textFieldStyle(.roundedBorder)
            Text(noDefaultLabels
                 ? "Default labels are disabled — custom labels are required."
                 : "Default labels (self-hosted, OSX, Arm64) are always added by GitHub.")
                .font(.caption2).foregroundStyle(noDefaultLabels && labelList.isEmpty ? .orange : .secondary)
        }
    }

    private var optionsSection: some View {
        DisclosureGroup("Advanced options", isExpanded: $showOptions) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Disable the runner's automatic self-update", isOn: $disableUpdate)
                Text("The runner auto-updates itself by default. Disable it to make this app the sole updater.")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Ephemeral (take one job, then unconfigure)", isOn: $ephemeral)
                Toggle("Skip default labels", isOn: $noDefaultLabels)
                TextField("Runner group (optional)", text: $runnerGroup)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.top, 4)
            .font(.caption)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: mode == .existing ? "Runner folder" : "Create in")
            switch mode {
            case .existing:
                HStack {
                    Text(existingDir?.path ?? "Choose a folder containing config.sh")
                        .font(.caption.monospaced())
                        .foregroundStyle(existingDir == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        if let url = chooseDirectory(title: "Select runner folder", canCreate: false) {
                            existingDir = url
                            reconfigure = false
                        }
                    }
                    .controlSize(.small)
                }
                if let cfg = existingConfig {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("This folder already runs a runner for **\(cfg.scope.displayString)**. A folder serves only one repo. To add a runner for another repo while keeping this one, use **New runner** above.")
                                .font(.caption)
                        }
                        Toggle(isOn: $reconfigure) {
                            Text("Reconfigure — remove it from \(cfg.scope.displayString) and register to the selected repo")
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            case .new:
                HStack {
                    Text(parentDir?.path ?? "Choose a parent folder")
                        .font(.caption.monospaced())
                        .foregroundStyle(parentDir == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(store.runnersBaseDirectory == nil ? "Choose…" : "Change…") {
                        if let url = chooseDirectory(title: "Select parent folder", canCreate: true) {
                            parentDir = url
                        }
                    }
                    .controlSize(.small)
                }
                if parentDir != nil, parentDir == store.runnersBaseDirectory {
                    Text("Using your Runners folder (set in Settings).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                TextField("New folder name", text: Binding(
                    get: { folderName },
                    set: { folderName = $0; folderNameEdited = true }
                ))
                .textFieldStyle(.roundedBorder)
                if !folderName.isEmpty && !Self.isValidFolderName(folderName) {
                    Text("Use a single folder name — no “/”, “.”, or “..”.")
                        .font(.caption2).foregroundStyle(.red)
                } else if let parentDir, !folderName.isEmpty {
                    Text("→ \(parentDir.appendingPathComponent(folderName).path)")
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if folderNameWasDeduped {
                    Text("“\(suggestedFolderName)” already exists here — using “\(folderName)”.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Toggle("Add to .gitignore in the parent folder", isOn: $addToGitignore)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if parentIsGitRepo {
                    Text("Parent looks like a git repo — ignoring keeps the runner out of commits.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Downloads and verifies the latest runner release, then registers it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var registerButton: some View {
        Button {
            Task { await register() }
        } label: {
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Text(isWorking ? "Working…" : "Register Runner")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canRegister || isWorking)
    }

    // MARK: - Logic

    private var filteredRepos: [GHRepo] {
        guard !search.isEmpty else { return store.adminRepos }
        return store.adminRepos.filter { $0.fullName.localizedCaseInsensitiveContains(search) }
    }

    /// Convention: name new folders `actions-runner-<repo|org>` so they're easy to identify.
    private var suggestedFolderName: String {
        guard let target = resolvedTarget else { return "actions-runner" }
        switch target {
        case .repo(_, let name): return "actions-runner-\(Self.sanitize(name))"
        case .org(let org): return "actions-runner-\(Self.sanitize(org))"
        }
    }

    /// A stable string that changes whenever the selected target changes (for onChange).
    private var targetKey: String {
        (selectedRepo?.fullName ?? "") + "|" + manualTarget.trimmingCharacters(in: .whitespaces)
    }

    private var parentIsGitRepo: Bool {
        guard let parentDir else { return false }
        return FileManager.default.fileExists(atPath: parentDir.appendingPathComponent(".git").path)
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        let mapped = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
    }

    /// A folder name must be a single, non-escaping path component — reject empty,
    /// `.`/`..`, and anything containing a path separator or null.
    static func isValidFolderName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n != "." && n != ".." && !n.contains("/") && !n.contains("\0")
    }

    /// Return `base`, or `base-2`, `base-3`, … — the first that doesn't already exist in `parent`.
    /// Lets you run more than one runner per repo without a manual suffix.
    static func uniqueFolderName(base: String, in parent: URL?) -> String {
        guard let parent else { return base }
        let fm = FileManager.default
        if !fm.fileExists(atPath: parent.appendingPathComponent(base).path) { return base }
        var n = 2
        while n < 1000, fm.fileExists(atPath: parent.appendingPathComponent("\(base)-\(n)").path) {
            n += 1
        }
        return "\(base)-\(n)"
    }

    /// True when the auto-suggested name got a numeric suffix because the base already exists.
    private var folderNameWasDeduped: Bool {
        guard !folderNameEdited, let parentDir, !folderName.isEmpty else { return false }
        return folderName != suggestedFolderName
            && FileManager.default.fileExists(atPath: parentDir.appendingPathComponent(suggestedFolderName).path)
    }

    private var labelList: [String] {
        labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The existing registration of the chosen folder, if it is already configured.
    private var existingConfig: RunnerConfig? {
        guard let dir = existingDir else { return nil }
        return RunnerConfig.load(from: dir)
    }

    private var resolvedTarget: GHTarget? {
        let manual = manualTarget.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty {
            return GHTarget.parseManual(manual)
        }
        if let repo = selectedRepo {
            return .repo(owner: repo.ownerLogin, name: repo.name)
        }
        return nil
    }

    private var manualTargetError: String? {
        let manual = manualTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !manual.isEmpty, GHTarget.parseManual(manual) == nil else { return nil }
        return "Enter owner/repo, an organization, or a valid https://github.com URL."
    }

    private var canRegister: Bool {
        guard store.ghAuth.authenticated, resolvedTarget != nil,
              !runnerName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // --no-default-labels requires at least one custom label.
        if noDefaultLabels && labelList.isEmpty { return false }
        switch mode {
        case .existing:
            guard existingDir != nil else { return false }
            // An already-configured folder must be explicitly reconfigured.
            return existingConfig == nil || reconfigure
        case .new: return parentDir != nil && Self.isValidFolderName(folderName)
        }
    }

    private func register() async {
        guard let target = resolvedTarget else { return }
        isWorking = true
        defer { isWorking = false }
        let name = runnerName.trimmingCharacters(in: .whitespaces)
        let group = runnerGroup.trimmingCharacters(in: .whitespaces)
        let options = RegisterOptions(
            runnerGroup: group.isEmpty ? nil : group,
            disableUpdate: disableUpdate,
            ephemeral: ephemeral,
            noDefaultLabels: noDefaultLabels
        )
        let ok: Bool
        switch mode {
        case .existing:
            guard let dir = existingDir else { return }
            ok = await store.registerExisting(directory: dir, target: target, name: name,
                                              labels: labelList, options: options,
                                              reconfigure: reconfigure)
        case .new:
            guard let parent = parentDir else { return }
            ok = await store.createAndRegister(
                parent: parent, folderName: folderName.trimmingCharacters(in: .whitespaces),
                target: target, name: name, labels: labelList, options: options,
                addToGitignore: addToGitignore,
                progress: { frac in Task { @MainActor in downloadProgress = frac } }
            )
        }
        if ok { onDone() }
    }

    // MARK: - Helpers

    /// A sensible base folder outside macOS's privacy-protected directories.
    static var defaultRunnersFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("actions-runners")
    }

    static func defaultRunnerName() -> String {
        let host = Host.current().localizedName ?? "mac"
        let cleaned = host.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        return "\(cleaned.lowercased())-runner"
    }

    private func chooseDirectory(title: String, canCreate: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreate
        panel.title = title
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
