import SwiftUI

/// Edit a runner's custom labels on GitHub (default labels are read-only).
struct LabelEditorView: View {
    @Environment(RunnerStore.self) private var store
    let instance: RunnerInstance
    var fixedHeight: CGFloat? = nil

    @State private var loaded = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var readOnly: [String] = []
    @State private var custom: [String] = []
    @State private var original: [String] = []
    @State private var newLabel = ""

    var body: some View {
        let core = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add or remove **custom** labels for **\(instance.displayName)**. Default labels (self-hosted, macOS, arch) are fixed by GitHub. Changes apply without restarting the runner.")
                    .font(.caption).foregroundStyle(.secondary)

                if isLoading && !loaded {
                    HStack { ProgressView().controlSize(.small); Text("Loading labels…").font(.caption) }
                } else if loaded {
                    editor
                } else {
                    HStack {
                        Text("Couldn't load labels.").font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await load() } }.controlSize(.small)
                    }
                }
            }
            .padding(14)
        }
        .task { if !loaded { await load() } }

        if let fixedHeight {
            core.frame(height: fixedHeight)
        } else {
            core.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !readOnly.isEmpty {
                SectionLabel(text: "Default (fixed)")
                ForEach(readOnly, id: \.self) { label in
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            SectionLabel(text: "Custom labels")
            if custom.isEmpty {
                Text("No custom labels yet.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(custom, id: \.self) { label in
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill").font(.caption2).foregroundStyle(.tint)
                    Text(label).font(.caption)
                    Spacer()
                    Button { removeLabel(label) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Remove label \(label)")
                }
            }

            HStack {
                TextField("Add a label", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addLabel)
                Button("Add", action: addLabel).disabled(!canAdd)
            }
            if !newLabel.trimmingCharacters(in: .whitespaces).isEmpty && !canAdd {
                Text(addHint).font(.caption2).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save Changes") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || custom == original)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Logic

    private var trimmedNew: String { newLabel.trimmingCharacters(in: .whitespaces) }

    private var canAdd: Bool {
        let n = trimmedNew
        return !n.isEmpty
            && !n.contains(",") && n.count <= 256
            && !custom.contains { $0.caseInsensitiveCompare(n) == .orderedSame }
            && !readOnly.contains { $0.caseInsensitiveCompare(n) == .orderedSame }
    }

    private var addHint: String {
        let n = trimmedNew
        if n.contains(",") { return "Labels can't contain commas." }
        if n.count > 256 { return "Too long (max 256 characters)." }
        return "That label already exists."
    }

    private func addLabel() {
        guard canAdd else { return }
        custom.append(trimmedNew)
        newLabel = ""
    }

    private func removeLabel(_ label: String) {
        custom.removeAll { $0 == label }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let labels = await store.fetchRunnerLabels(instance) {
            apply(labels)
            loaded = true
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if let updated = await store.saveRunnerLabels(instance, custom: custom) {
            apply(updated)
        }
    }

    private func apply(_ labels: [RunnerLabel]) {
        readOnly = labels.filter { !$0.isCustom }.map(\.name)
        custom = labels.filter { $0.isCustom }.map(\.name)
        original = custom
    }
}
