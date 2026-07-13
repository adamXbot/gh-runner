import SwiftUI
import AppKit

/// Combined view of every runner: aggregate stats, a per-runner table, and one merged log.
struct DashboardView: View {
    @Environment(RunnerStore.self) private var store
    @State private var mergedLines: [LogTailer.MergedLogLine] = []
    /// Live mode streams new log lines and auto-scrolls; pausing freezes the view.
    @State private var live = true

    private let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red]

    var body: some View {
        Group {
            if store.runners.isEmpty {
                ContentUnavailableView {
                    Label("No runners", systemImage: "shippingbox")
                } description: {
                    Text("Add a runner with the + button in the sidebar to see combined stats and logs here.")
                }
            } else {
                dashboard
            }
        }
        .navigationTitle("Dashboard")
        .navigationSubtitle("\(store.runners.count) runner\(store.runners.count == 1 ? "" : "s")")
        // Keyed on `live` too, so toggling pause/resume restarts the loop with the
        // current value — no reliance on @State-capture semantics inside the task.
        .task(id: "\(runnerKey)#\(live)") { await tailLoop() }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryTiles
            statsSection
            Divider()
            combinedLogSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Aggregate summary

    private var running: Int { store.runningRunners.count }
    private var busy: Int { store.runners.filter { store.status(for: $0).busy }.count }
    private var totalCPU: Double { store.runners.compactMap { store.status(for: $0).cpuPercent }.reduce(0, +) }
    private var totalMem: Double { store.runners.compactMap { store.status(for: $0).memoryMB }.reduce(0, +) }

    private var summaryTiles: some View {
        HStack(spacing: 10) {
            DashTile(title: "Runners", value: "\(store.runners.count)", systemImage: "shippingbox", color: .accentColor)
            DashTile(title: "Running", value: "\(running)", systemImage: "play.circle.fill", color: .green)
            DashTile(title: "Busy", value: "\(busy)", systemImage: "bolt.fill", color: .orange)
            DashTile(title: "CPU", value: String(format: "%.0f%%", totalCPU), systemImage: "cpu", color: .blue)
            DashTile(title: "Memory", value: String(format: "%.0f MB", totalMem), systemImage: "memorychip", color: .purple)
        }
    }

    // MARK: - Per-runner table

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Per-runner")
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Runner"); Text("State"); Text("PID"); Text("CPU"); Text("Memory"); Text("Uptime"); Text("Job")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(store.runners) { runner in
                        let s = store.status(for: runner)
                        GridRow {
                            HStack(spacing: 5) {
                                Image(systemName: s.symbolName).foregroundStyle(s.tintColor).font(.caption2)
                                Text(runner.displayName).lineLimit(1)
                            }
                            Text(s.state.label).foregroundStyle(s.tintColor)
                            Text(s.pid.map(String.init) ?? "—")
                            Text(s.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                            Text(s.memoryMB.map { String(format: "%.0f MB", $0) } ?? "—")
                            Text(s.uptime ?? "—")
                            Text(s.currentJob ?? "—").lineLimit(1).foregroundStyle(s.busy ? .orange : .secondary)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
            }
            .frame(maxHeight: 170)
        }
    }

    // MARK: - Combined log

    private var combinedLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionLabel(text: "Combined log — all runners")
                liveBadge
                Spacer()
                Button { live.toggle() } label: {
                    Label(live ? "Pause" : "Live", systemImage: live ? "pause.fill" : "play.fill")
                        .font(.caption)
                }
                .controlSize(.small)
                .help(live ? "Pause the live log to read it" : "Resume live streaming")
                Button { copyLog() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy combined log").disabled(mergedLines.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if mergedLines.isEmpty {
                            Text("No log output yet.")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        } else {
                            ForEach(mergedLines) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(line.runner)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(color(for: line.runner))
                                        .frame(width: 96, alignment: .leading).lineLimit(1)
                                    Text(line.text)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(line.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                .onChange(of: mergedLines) { _, _ in
                    if live { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var liveBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(live ? .green : .secondary)
                .symbolEffect(.pulse, isActive: live)
            Text(live ? "LIVE" : "PAUSED")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(live ? .green : .secondary)
        }
        .accessibilityLabel(live ? "Live" : "Paused")
    }

    // MARK: - Logic

    // Include configured-ness so the tail task re-snapshots when a runner is (re)configured
    // — the id set alone doesn't change when an already-listed runner flips to configured.
    private var runnerKey: String {
        store.runners.map { "\($0.id):\($0.isConfigured)" }.joined(separator: "|")
    }

    private func color(for name: String) -> Color {
        if let idx = store.runners.firstIndex(where: { $0.displayName == name }) {
            return palette[idx % palette.count]
        }
        return .secondary
    }

    private func copyLog() {
        let text = mergedLines.map { "[\($0.runner)] \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func tailLoop() async {
        let runners = store.runners
            .filter { $0.isConfigured }
            .map { (name: $0.displayName, directory: $0.directory) }
        while !Task.isCancelled {
            // In live mode, stream updates (1s). When paused, keep the frozen snapshot
            // but keep looping so resuming takes effect promptly.
            if live {
                let lines = await Task.detached(priority: .utility) {
                    LogTailer.mergedTail(runners: runners, perRunner: 80, limit: 500)
                }.value
                mergedLines = lines
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

/// A small aggregate stat card for the dashboard.
private struct DashTile: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
