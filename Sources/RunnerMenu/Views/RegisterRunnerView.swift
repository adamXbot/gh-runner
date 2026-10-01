import SwiftUI
import AppKit

/// Registers a runner: pick a GitHub target (from your admin repos), name it,
/// and either configure an existing folder or download + create a new one.
struct RegisterRunnerView: View {
    @Environment(RunnerStore.self) private var store
    var onDone: () -> Void

    var body: some View {
        RegistrationForm(draft: store.registrationDraft, onDone: onDone)
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

}

private struct RegistrationForm: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(RunnerStore.self) private var store
    @Bindable var draft: RegistrationDraft
    var onDone: () -> Void
    typealias Mode = RegistrationDraft.Mode

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

                Picker("Mode", selection: $draft.mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(draft.isWorking)

                Group {
                    repoSection
                    Divider()
                    nameSection
                    optionsSection
                    directorySection
                }
                .disabled(draft.isWorking)

                if draft.isWorking, let phase = draft.registrationPhase {
                    if let fraction = phase.downloadFraction {
                        ProgressView(value: fraction) { Text(phase.label).font(.caption) }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(phase.label).font(.caption)
                        }
                    }
                }
                if let issue = draft.operationIssue {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(issue.message, systemImage: "exclamationmark.octagon.fill")
                            .font(.callout.weight(.medium))
                        Text(issue.recovery).font(.caption)
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }

                registerButton
                HStack {
                    Text(draft.isWorking ? "Registration continues if you close this panel." : "Your draft is kept when you close this panel.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard Draft", role: .destructive) { store.discardRegistrationDraft() }
                        .controlSize(.small)
                        .disabled(draft.isWorking)
                }
            }
            .padding(14)
        }
        .frame(height: 520)
        .onAppear {
            if !draft.isWorking, draft.runnerName.isEmpty { draft.runnerName = RegisterRunnerView.defaultRunnerName(for: resolvedTarget) }
            if !draft.isWorking, draft.existingDir == nil { draft.existingDir = store.selectedRunner?.directory }
            // Default to the configured Runners folder, else ~/actions-runners — which
            // avoids macOS's Documents/Desktop/Downloads privacy prompts.
            if !draft.isWorking, draft.parentDir == nil { draft.parentDir = store.runnersBaseDirectory ?? RegisterRunnerView.defaultRunnersFolder }
            if !draft.isWorking, draft.folderName.isEmpty { draft.folderName = RegisterRunnerView.uniqueFolderName(base: suggestedFolderName, in: draft.parentDir) }
        }
        .task {
            await store.forceAuthRecheck()
            if store.ghAuth.authenticated { store.loadAdminRepos() }
        }
        // Keep the new-folder name in sync with the chosen repo unless the user typed one,
        // de-duplicating against folders that already exist in the parent.
        .onChange(of: targetKey) { _, _ in
            if !draft.folderNameEdited { draft.folderName = RegisterRunnerView.uniqueFolderName(base: suggestedFolderName, in: draft.parentDir) }
            if !draft.runnerNameEdited { draft.runnerName = RegisterRunnerView.defaultRunnerName(for: resolvedTarget) }
            draft.operationIssue = nil
        }
        // Re-evaluate the name and gitignore suggestion when the parent changes.
        .onChange(of: draft.parentDir) { _, _ in
            if !draft.folderNameEdited { draft.folderName = RegisterRunnerView.uniqueFolderName(base: suggestedFolderName, in: draft.parentDir) }
            draft.addToGitignore = parentIsGitRepo
        }
        .onChange(of: draft.mode) { _, _ in draft.operationIssue = nil }
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
                TextField("Filter repositories…", text: $draft.search)
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

            DisclosureGroup("Enter a private repository manually", isExpanded: $draft.showAdvanced) {
                TextField("e.g. octocat/hello-world", text: $draft.manualTarget)
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
            if !draft.showAdvanced && !draft.manualTarget.isEmpty {
                Text(manualTargetError ?? "Manual target: \(draft.manualTarget)")
                    .font(.caption2)
                    .foregroundStyle(manualTargetError == nil ? Color.secondary : Color.red)
            }
        }
    }

    private func repoRow(_ repo: GHRepo) -> some View {
        let isSel = draft.selectedRepo?.id == repo.id && draft.manualTarget.isEmpty
        return Button {
            draft.selectedRepo = repo
            draft.manualTarget = ""
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
        .buttonStyle(RunnerButtonStyle(surface: .row))
        .animation(RunnerMotion.content(reduceMotion: reduceMotion), value: isSel)
        .accessibilityAddTraits(isSel ? [.isSelected] : [])
        .disabled(!repo.isPrivate)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Runner")
            TextField("Runner name", text: Binding(
                get: { draft.runnerName },
                set: { draft.runnerName = $0; draft.runnerNameEdited = true; draft.operationIssue = nil }
            ))
                .textFieldStyle(.roundedBorder)
            TextField("Labels (comma-separated, optional)", text: $draft.labels)
                .textFieldStyle(.roundedBorder)
            Text(draft.noDefaultLabels
                 ? "Default labels are disabled — custom labels are required."
                 : "Default labels (self-hosted, OSX, Arm64) are always added by GitHub.")
                .font(.caption2).foregroundStyle(draft.noDefaultLabels && labelList.isEmpty ? .orange : .secondary)
        }
    }

    private var optionsSection: some View {
        DisclosureGroup("Advanced options", isExpanded: $draft.showOptions) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Disable the runner's automatic self-update", isOn: $draft.disableUpdate)
                Text("The runner auto-updates itself by default. Disable it to make this app the sole updater.")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Ephemeral (take one job, then unconfigure)", isOn: $draft.ephemeral)
                Toggle("Skip default labels", isOn: $draft.noDefaultLabels)
                TextField("Runner group (optional)", text: $draft.runnerGroup)
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
            SectionLabel(text: draft.mode == .existing ? "Runner folder" : "Create in")
            switch draft.mode {
            case .existing:
                HStack {
                    Text(draft.existingDir?.path ?? "Choose a folder containing config.sh")
                        .font(.caption.monospaced())
                        .foregroundStyle(draft.existingDir == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        if let url = chooseDirectory(title: "Select runner folder", canCreate: false) {
                            draft.existingDir = url
                            draft.reconfigure = false
                        }
                    }
                    .controlSize(.small)
                }
                if let directory = draft.existingDir,
                   let reason = store.mutationUnavailableReason(for: RunnerInstance(directory: directory)) {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
                if let cfg = existingConfig {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("This folder already runs a runner for **\(cfg.scope.displayString)**. A folder serves only one repo. To add a runner for another repo while keeping this one, use **New runner** above.")
                                .font(.caption)
                        }
                        Toggle(isOn: $draft.reconfigure) {
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
                    Text(draft.parentDir?.path ?? "Choose a parent folder")
                        .font(.caption.monospaced())
                        .foregroundStyle(draft.parentDir == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(store.runnersBaseDirectory == nil ? "Choose…" : "Change…") {
                        if let url = chooseDirectory(title: "Select parent folder", canCreate: true) {
                            draft.parentDir = url
                        }
                    }
                    .controlSize(.small)
                }
                if draft.parentDir != nil, draft.parentDir == store.runnersBaseDirectory {
                    Text("Using your Runners folder (set in Settings).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                TextField("New folder name", text: Binding(
                    get: { draft.folderName },
                    set: { draft.folderName = $0; draft.folderNameEdited = true; draft.operationIssue = nil }
                ))
                .textFieldStyle(.roundedBorder)
                if !draft.folderName.isEmpty && !RegisterRunnerView.isValidFolderName(draft.folderName) {
                    Text("Use a single folder name — no “/”, “.”, or “..”.")
                        .font(.caption2).foregroundStyle(.red)
                } else if let parentDir = draft.parentDir, !draft.folderName.isEmpty {
                    Text("→ \(parentDir.appendingPathComponent(draft.folderName).path)")
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if folderNameWasDeduped {
                    Text("“\(suggestedFolderName)” already exists here — using “\(draft.folderName)”.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Toggle("Add to .gitignore in the parent folder", isOn: $draft.addToGitignore)
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
                if draft.isWorking { ProgressView().controlSize(.small) }
                Text(draft.isWorking ? "Working…" : "Register Runner")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canRegister || draft.isWorking)
    }

    // MARK: - Logic

    private var filteredRepos: [GHRepo] {
        guard !draft.search.isEmpty else { return store.adminRepos }
        return store.adminRepos.filter { $0.fullName.localizedCaseInsensitiveContains(draft.search) }
    }

    /// Convention: name new folders `actions-runner-<repo|org>` so they're easy to identify.
    private var suggestedFolderName: String {
        guard let target = resolvedTarget else { return "actions-runner" }
        switch target {
        case .repo(_, let name): return "actions-runner-\(RegisterRunnerView.sanitize(name))"
        case .org(let org): return "actions-runner-\(RegisterRunnerView.sanitize(org))"
        }
    }

    /// A stable string that changes whenever the selected target changes (for onChange).
    private var targetKey: String {
        (draft.selectedRepo?.fullName ?? "") + "|" + draft.manualTarget.trimmingCharacters(in: .whitespaces)
    }

    private var parentIsGitRepo: Bool {
        guard let parentDir = draft.parentDir else { return false }
        return FileManager.default.fileExists(atPath: parentDir.appendingPathComponent(".git").path)
    }

    /// True when the auto-suggested name got a numeric suffix because the base already exists.
    private var folderNameWasDeduped: Bool {
        guard !draft.folderNameEdited, let parentDir = draft.parentDir, !draft.folderName.isEmpty else { return false }
        return draft.folderName != suggestedFolderName
            && FileManager.default.fileExists(atPath: parentDir.appendingPathComponent(suggestedFolderName).path)
    }

    private var labelList: [String] {
        draft.labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The existing registration of the chosen folder, if it is already configured.
    private var existingConfig: RunnerConfig? {
        guard let dir = draft.existingDir else { return nil }
        return RunnerConfig.load(from: dir)
    }

    private var resolvedTarget: GHTarget? {
        let manual = draft.manualTarget.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty {
            return GHTarget.parseManual(manual)
        }
        if let repo = draft.selectedRepo {
            return .repo(owner: repo.ownerLogin, name: repo.name)
        }
        return nil
    }

    private var manualTargetError: String? {
        let manual = draft.manualTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !manual.isEmpty else { return nil }
        guard let target = GHTarget.parseManual(manual) else {
            return "Enter owner/repo or a valid https://github.com/owner/repo URL."
        }
        if case .org = target { return "Organization-wide runners are outside this fleet's private-repository policy." }
        return nil
    }

    private var canRegister: Bool {
        guard store.ghAuth.authenticated, resolvedTarget != nil,
              !draft.runnerName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if manualTargetError != nil || (draft.manualTarget.isEmpty && draft.selectedRepo?.isPrivate == false) { return false }
        // --no-default-labels requires at least one custom label.
        if draft.noDefaultLabels && labelList.isEmpty { return false }
        switch draft.mode {
        case .existing:
            guard let directory = draft.existingDir,
                  store.mutationUnavailableReason(for: RunnerInstance(directory: directory)) == nil else { return false }
            // An already-configured folder must be explicitly reconfigured.
            return existingConfig == nil || draft.reconfigure
        case .new: return draft.parentDir != nil && RegisterRunnerView.isValidFolderName(draft.folderName)
        }
    }

    private func register() async {
        guard canRegister, !draft.isWorking, let target = resolvedTarget else { return }
        draft.isWorking = true
        draft.registrationPhase = .checkingRepository
        draft.operationIssue = nil
        defer { draft.isWorking = false; draft.registrationPhase = nil }
        let name = draft.runnerName.trimmingCharacters(in: .whitespaces)
        let group = draft.runnerGroup.trimmingCharacters(in: .whitespaces)
        let options = RegisterOptions(
            runnerGroup: group.isEmpty ? nil : group,
            disableUpdate: draft.disableUpdate,
            ephemeral: draft.ephemeral,
            noDefaultLabels: draft.noDefaultLabels
        )
        let ok: Bool
        switch draft.mode {
        case .existing:
            guard let dir = draft.existingDir else { return }
            ok = await store.registerExisting(directory: dir, target: target, name: name,
                                              labels: labelList, options: options,
                                              reconfigure: draft.reconfigure,
                                              onProgress: { phase in
                                                  Task { @MainActor in draft.registrationPhase = phase }
                                              })
        case .new:
            guard let parent = draft.parentDir else { return }
            ok = await store.createAndRegister(
                parent: parent, folderName: draft.folderName.trimmingCharacters(in: .whitespaces),
                target: target, name: name, labels: labelList, options: options,
                addToGitignore: draft.addToGitignore,
                onProgress: { phase in
                    Task { @MainActor in draft.registrationPhase = phase }
                }
            )
        }
        if ok { store.discardRegistrationDraft(afterSuccess: true); onDone() }
        else { draft.operationIssue = store.registrationIssue }
    }

    // MARK: - Helpers

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
