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

    @State private var mode: Mode = .new
    @State private var search = ""
    @State private var selectedRepo: GHRepo?
    @State private var manualTarget = ""
    @State private var showAdvanced = false
    @State private var runnerName = ""
    @State private var runnerNameEdited = false
    @State private var labels = ""
    @State private var existingDir: URL?
    @State private var reconfigure = false
    @State private var parentDir: URL?
    @State private var folderName = ""
    @State private var folderNameEdited = false
    @State private var addToGitignore = false
    @State private var isWorking = false
    @State private var registrationPhase: RegistrationPhase?
    @State private var operationIssue: RegistrationIssue?
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
                } else if let account = store.ghAuth.account {
                    Label("Using GitHub CLI account \(account)", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                if isWorking, let registrationPhase {
                    if let fraction = registrationPhase.downloadFraction {
                        ProgressView(value: fraction) { Text(registrationPhase.label).font(.caption) }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(registrationPhase.label).font(.caption)
                        }
                    }
                }
                if let operationIssue {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(operationIssue.message, systemImage: "exclamationmark.octagon.fill")
                            .font(.callout.weight(.medium))
                        Text(operationIssue.recovery).font(.caption)
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }

                registerButton
            }
            .padding(14)
        }
        .frame(height: 520)
        .onAppear {
            if runnerName.isEmpty { runnerName = Self.defaultRunnerName(for: resolvedTarget) }
            if existingDir == nil { existingDir = store.selectedRunner?.directory }
            // Default to the configured Runners folder, else ~/actions-runners — which
            // avoids macOS's Documents/Desktop/Downloads privacy prompts.
            if parentDir == nil { parentDir = store.runnersBaseDirectory ?? Self.defaultRunnersFolder }
            if folderName.isEmpty { folderName = Self.uniqueFolderName(base: suggestedFolderName, in: parentDir) }
        }
        .task {
            await store.forceAuthRecheck()
            if store.ghAuth.authenticated { store.loadAdminRepos() }
        }
        // Keep the new-folder name in sync with the chosen repo unless the user typed one,
        // de-duplicating against folders that already exist in the parent.
        .onChange(of: targetKey) { _, _ in
            if !folderNameEdited { folderName = Self.uniqueFolderName(base: suggestedFolderName, in: parentDir) }
            if !runnerNameEdited { runnerName = Self.defaultRunnerName(for: resolvedTarget) }
            operationIssue = nil
        }
        // Re-evaluate the name and gitignore suggestion when the parent changes.
        .onChange(of: parentDir) { _, _ in
            if !folderNameEdited { folderName = Self.uniqueFolderName(base: suggestedFolderName, in: parentDir) }
            addToGitignore = parentIsGitRepo
        }
        .onChange(of: mode) { _, _ in operationIssue = nil }
    }

    // MARK: - Sections

    private var authWarning: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(store.ghAuth.message ?? "Sign in with gh auth login in Terminal to enable registration.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
            Button("Check GitHub sign-in again") {
                Task {
                    await store.forceAuthRecheck()
                    if store.ghAuth.authenticated { store.loadAdminRepos() }
                }
            }
            .controlSize(.small)
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var repoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Repository (admin access)")
            Text("This fleet registers runners to private repositories only. Use GitHub-hosted runners for public repositories.")
                .font(.caption2).foregroundStyle(.secondary)
            if store.isLoadingRepos {
                HStack { ProgressView().controlSize(.small); Text("Loading your repositories…").font(.caption).foregroundStyle(.secondary) }
            } else if let error = store.adminReposError {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Could not load repositories: \(error)")
                    Button("Try loading again") { store.loadAdminRepos() }.controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.red)
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

            DisclosureGroup("Enter a private repository manually", isExpanded: $showAdvanced) {
                TextField("e.g. octocat/hello-world", text: $manualTarget)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .padding(.top, 4)
                if let manualTargetError {
                    Text(manualTargetError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Text("Overrides the selection above. Runner Menu checks visibility and admin access before making changes.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
            if !showAdvanced && !manualTarget.isEmpty {
                Text(manualTargetError ?? "Manual target: \(manualTarget)")
                    .font(.caption2)
                    .foregroundStyle(manualTargetError == nil ? Color.secondary : Color.red)
            }
        }
    }

    private func repoRow(_ repo: GHRepo) -> some View {
        let isSel = selectedRepo?.id == repo.id && manualTarget.isEmpty
        return Button {
            selectedRepo = repo
            manualTarget = ""
        } label: {
            HStack(spacing: 6) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(repo.fullName).font(.callout).lineLimit(1)
                if !repo.isPrivate { Text("Public").font(.caption2).foregroundStyle(.orange) }
                Spacer()
                if isSel { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isSel ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!repo.isPrivate)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Runner")
            TextField("Runner name", text: Binding(
                get: { runnerName },
                set: { runnerName = $0; runnerNameEdited = true; operationIssue = nil }
            ))
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
                    set: { folderName = $0; folderNameEdited = true; operationIssue = nil }
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
        guard !manual.isEmpty else { return nil }
        guard let target = GHTarget.parseManual(manual) else {
            return "Enter owner/repo or a valid https://github.com/owner/repo URL."
        }
        if case .org = target { return "Organization-wide runners are outside this fleet's private-repository policy." }
        return nil
    }

    private var canRegister: Bool {
        guard store.ghAuth.authenticated, resolvedTarget != nil,
              !runnerName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if manualTargetError != nil || (manualTarget.isEmpty && selectedRepo?.isPrivate == false) { return false }
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
        registrationPhase = .checkingRepository
        operationIssue = nil
        defer { isWorking = false; registrationPhase = nil }
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
                                              reconfigure: reconfigure,
                                              onProgress: { phase in
                                                  Task { @MainActor in registrationPhase = phase }
                                              })
        case .new:
            guard let parent = parentDir else { return }
            ok = await store.createAndRegister(
                parent: parent, folderName: folderName.trimmingCharacters(in: .whitespaces),
                target: target, name: name, labels: labelList, options: options,
                addToGitignore: addToGitignore,
                onProgress: { phase in
                    Task { @MainActor in registrationPhase = phase }
                }
            )
        }
        if ok { onDone() }
        else { operationIssue = store.registrationIssue }
    }

    // MARK: - Helpers

    /// A sensible base folder outside macOS's privacy-protected directories.
    static var defaultRunnersFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("actions-runners")
    }

    static func defaultRunnerName(for target: GHTarget? = nil) -> String {
        let host = Host.current().localizedName ?? "mac"
        let cleaned = host.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        let suffix: String
        if case .repo(_, let repository) = target {
            suffix = sanitize(repository).lowercased()
        } else {
            suffix = "runner"
        }
        return "\(cleaned.lowercased())-\(suffix)"
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
