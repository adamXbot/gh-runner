import SwiftUI
import AppKit

/// Inline detail + stats + controls for the selected runner.
struct RunnerDetailView: View {
    @Environment(RunnerStore.self) private var store
    let instance: RunnerInstance
    var showLog: () -> Void
    var showUpdates: () -> Void
    var showLabels: () -> Void = {}
    /// The window provides Start/Stop and navigation in its toolbar, so those can be
    /// suppressed when this view is embedded there.
    var showsPrimaryControl: Bool = true
    var showsActionButtons: Bool = true

    private var status: RunnerLiveStatus { store.status(for: instance) }
    private var insight: RunnerLogInsights? { store.insight(for: instance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsPrimaryControl {
                primaryControl
            }

            if let job = status.currentJob, status.busy {
                currentJobBanner(job)
            }

            statsGrid
            serviceControl

            if let history = insight?.history, !history.isEmpty {
                recentJobs(history)
            }

            if showsActionButtons {
                actionButtons
            }
        }
    }

    // MARK: - Primary control

    @ViewBuilder
    private var primaryControl: some View {
        let starting = store.isInFlight("start-\(instance.id)")
        let stopping = store.isInFlight("stop-\(instance.id)")
        if status.state == .notConfigured {
            Text("This directory has no runner registration yet. Use “Add / Register Runner” to bind it to a repository.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if status.isRunning {
            Button {
                store.stop(instance)
            } label: {
                Label(stopping ? "Stopping…" : "Stop Runner", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
            .disabled(stopping)
            .keyboardShortcut(.return, modifiers: [])
        } else {
            Button {
                store.start(instance)
            } label: {
                Label(starting ? "Starting…" : "Start Runner", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(starting)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private func currentJobBanner(_ job: String) -> some View {
        let record = runningJobRecord
        return Button {
            if let record { openJob(record) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Running job").font(.caption2).foregroundStyle(.secondary)
                    Text(job).font(.caption.weight(.medium)).lineLimit(2)
                }
                Spacer()
                if record != nil {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.orange.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(record == nil)
        .help(record != nil ? "Open running job — \(store.jobClickAction.label)" : "")
        .contextMenu { if let record { jobContextMenu(record) } }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Stats

    private var statsGrid: some View {
        VStack(spacing: 4) {
            StatRow(label: "State", value: status.state.label, valueColor: status.tintColor)
            if let pid = status.pid {
                StatRow(label: "PID", value: "\(pid)", mono: true)
            }
            if status.state == .running {
                StatRow(label: "CPU", value: String(format: "%.1f%%", status.cpuPercent ?? 0), mono: true)
                StatRow(label: "Memory", value: String(format: "%.0f MB", status.memoryMB ?? 0), mono: true)
                if let uptime = status.uptime {
                    StatRow(label: "Uptime", value: uptime, mono: true)
                }
            }
            StatRow(label: "Version", value: instance.installedVersion.map { "v\($0)" } ?? "—", mono: true)
            if let scope = instance.scopeLabel {
                StatRow(label: "Scope", value: scope)
            }
            StatRow(label: "Folder", value: instance.directory.path, mono: true)
        }
    }

    // MARK: - Service control

    private var serviceBusy: Bool {
        ["svc-install", "svc-uninstall", "svc-start", "svc-stop"]
            .contains { store.isInFlight("\($0)-\(instance.id)") }
    }

    private var serviceControl: some View {
        HStack(spacing: 8) {
            Image(systemName: status.serviceInstalled ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(status.serviceInstalled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.serviceInstalled ? "launchd service installed" : "No launchd service")
                    .font(.caption.weight(.medium))
                Text(status.serviceInstalled ? "Runs at login (svc.sh / launchd)." : "Install to keep the runner alive after quitting this app.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if serviceBusy { ProgressView().controlSize(.small) }
            Menu {
                if status.serviceInstalled {
                    if status.isRunning {
                        Button { store.stopService(instance) } label: { Label("Stop Service", systemImage: "stop.fill") }
                    } else {
                        Button { store.startService(instance) } label: { Label("Start Service", systemImage: "play.fill") }
                    }
                    Button { revealServiceLogs() } label: { Label("Open Service Logs", systemImage: "doc.text.magnifyingglass") }
                    Button { Task { await store.showServiceStatus(instance) } } label: { Label("Show Status", systemImage: "info.circle") }
                    Divider()
                    Button(role: .destructive) { store.uninstallService(instance) } label: { Label("Uninstall Service", systemImage: "trash") }
                } else {
                    Button { store.installService(instance) } label: { Label("Install & Start", systemImage: "bolt.fill") }
                    Button { store.installServiceOnly(instance) } label: { Label("Install Only", systemImage: "square.and.arrow.down") }
                }
            } label: {
                Label("Service", systemImage: "gearshape.2")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!instance.isConfigured || serviceBusy)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func revealServiceLogs() {
        if let dir = store.serviceLogDirectory(instance) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            store.banner = BannerMessage(text: "No service log folder found for \(instance.displayName).", kind: .error)
        }
    }

    // MARK: - Recent jobs

    private func recentJobs(_ history: [JobRecord]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Recent jobs")
            ForEach(history.prefix(6)) { job in
                Button { openJob(job) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: job.result.symbolName)
                            .foregroundStyle(job.result.color)
                            .font(.caption)
                        Text(job.name)
                            .font(.caption)
                            .lineLimit(1)
                        if let duration = job.durationText {
                            Text(duration)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        Spacer(minLength: 4)
                        if let ts = job.timestamp {
                            // A formatted Date is otherwise just a snapshot. Drive the
                            // relative value from a timeline so it stays accurate while
                            // the menu is open, even when no runner state changes.
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(ts, format: .relative(presentation: .numeric))
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open job — \(store.jobClickAction.label)")
                .contextMenu { jobContextMenu(job) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(jobAccessibilityLabel(job))
                .accessibilityHint("Opens \(store.jobClickAction.label)")
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func jobContextMenu(_ job: JobRecord) -> some View {
        Button("Open on GitHub") { openJobOnGitHub(job) }
        Button("Reveal Local Log") { revealJobLog(job) }
    }

    private func jobAccessibilityLabel(_ job: JobRecord) -> String {
        var parts = ["\(job.name), \(job.result.label)"]
        if let duration = job.durationText { parts.append("ran for \(duration)") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Recent-job actions

    private func openJob(_ job: JobRecord) {
        switch store.jobClickAction {
        case .github: openJobOnGitHub(job)
        case .localLog: revealJobLog(job)
        }
    }

    private func openJobOnGitHub(_ job: JobRecord) {
        Task {
            if let url = await store.jobGitHubURL(job, in: instance) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func revealJobLog(_ job: JobRecord) {
        if let url = store.jobWorkerLog(job, in: instance) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([LogTailer.diagDirectory(for: instance.directory)])
        }
    }

    /// The still-running job's record, if any (used to make the current-job banner clickable).
    private var runningJobRecord: JobRecord? {
        insight?.history.first { $0.result == .running }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button { showLog() } label: {
                Label("Log", systemImage: "text.alignleft")
            }
            .controlSize(.small)

            Button { showUpdates() } label: {
                Label("Updates", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)

            if instance.isConfigured {
                Button { showLabels() } label: {
                    Label("Labels", systemImage: "tag")
                }
                .controlSize(.small)
            }

            if let url = instance.gitHubURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .padding(.top, 2)
    }
}
