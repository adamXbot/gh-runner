import SwiftUI
import AppKit

/// A live tail of the runner's diagnostic logs.
struct LogConsoleView: View {
    @Environment(RunnerStore.self) private var store
    let instance: RunnerInstance
    /// Fixed height for the menu-bar panel; pass nil in a resizable window to fill.
    var fixedHeight: CGFloat? = 460

    enum Source: String, CaseIterable, Identifiable {
        case runner = "Runner"
        case worker = "Worker"
        case service = "Service"
        var id: String { rawValue }
        var prefix: String? { self == .runner ? "Runner_" : (self == .worker ? "Worker_" : nil) }
    }

    @State private var localSource: Source = .runner
    @State private var localAutoScroll = true
    private var sourceBinding: Binding<Source>?
    private var autoScrollBinding: Binding<Bool>?
    private var source: Source { sourceBinding?.wrappedValue ?? localSource }
    private var autoScroll: Bool { autoScrollBinding?.wrappedValue ?? localAutoScroll }

    init(instance: RunnerInstance, fixedHeight: CGFloat? = 460,
         source: Binding<Source>? = nil, autoScroll: Binding<Bool>? = nil) {
        self.instance = instance
        self.fixedHeight = fixedHeight
        sourceBinding = source
        autoScrollBinding = autoScroll
    }
    @State private var lines: [String] = []
    @State private var currentLogURL: URL?
    @State private var readIssue: String?
    @State private var loading = true

    /// The runner whose log is shown — follows the shared selection so the picker works.
    private var runner: RunnerInstance { store.selectedRunner ?? instance }
    private var taskKey: String { "\(runner.id)#\(source.rawValue)" }

    /// Only offer the Service tab when a launchd service is actually installed.
    private var availableSources: [Source] {
        store.serviceLogDirectory(runner) != nil ? Source.allCases : [.runner, .worker]
    }

    var body: some View {
        let core = VStack(spacing: 8) {
            controls
            logView
            footer
        }
        .padding(12)
        .task(id: taskKey) { await tailLoop() }
        .onChange(of: availableSources) { _, sources in
            if !sources.contains(source) { sourceSelection.wrappedValue = .runner }
        }

        if let fixedHeight {
            core.frame(height: fixedHeight)
        } else {
            core.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            if store.runners.count > 1 {
                Picker("Runner", selection: runnerSelection) {
                    ForEach(store.runners) { r in
                        Text(r.displayName).tag(r.id)
                    }
                }
                .labelsHidden()
                .help("Switch which runner's log you're viewing")
            }
            HStack {
                Picker("Source", selection: sourceSelection) {
                    ForEach(availableSources) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: availableSources.count > 2 ? 220 : 160)

                Spacer()

                Toggle(isOn: followSelection) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Follow newest lines")
                .accessibilityLabel("Follow newest lines")
                .accessibilityValue(autoScroll ? "On" : "Off")
            }
        }
    }

    private var sourceSelection: Binding<Source> { sourceBinding ?? $localSource }
    private var followSelection: Binding<Bool> { autoScrollBinding ?? $localAutoScroll }

    private var runnerSelection: Binding<String> {
        Binding(
            get: { runner.id },
            set: { store.selectedRunnerID = $0 }
        )
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if lines.isEmpty {
                        Text(readIssue ?? (loading ? "Reading logs…" : (currentLogURL == nil
                            ? "No \(source.rawValue.lowercased()) log file yet. Logs appear after this source runs."
                            : "This log file is empty. Waiting for output…")))
                            .font(.caption).foregroundStyle(readIssue == nil ? Color.secondary : Color.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
            .onChange(of: lines) { _, _ in
                if autoScroll { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let url = currentLogURL {
                Text(url.lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("No log file").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(RunnerButtonStyle()).help("Copy log")
            .disabled(lines.isEmpty)

            Button {
                if let url = currentLogURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([LogTailer.diagDirectory(for: runner.directory)])
                }
            } label: { Image(systemName: "folder") }
            .buttonStyle(RunnerButtonStyle()).help("Reveal in Finder")
        }
    }

    private func tailLoop() async {
        loading = true
        lines = []
        currentLogURL = nil
        readIssue = nil
        let dir = runner.directory
        let prefix = source.prefix
        // For the Service source the log is a fixed launchd file, not a _diag rotation.
        let serviceLog = source == .service
            ? store.serviceLogDirectory(runner)?.appendingPathComponent("stdout.log")
            : nil
        while !Task.isCancelled {
            // Read off the main actor — file reads must never block the UI.
            let result = await Task.detached(priority: .utility) {
                if let prefix { return LogTailer.readTail(in: dir, prefix: prefix) }
                if let serviceLog { return LogTailer.readTail(at: serviceLog) }
                return LogTailer.ReadResult(url: nil, lines: [], issue: nil)
            }.value
            guard !Task.isCancelled else { return }
            if currentLogURL != result.url { currentLogURL = result.url }
            if lines != result.lines { lines = result.lines }
            if readIssue != result.issue { readIssue = result.issue }
            loading = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
