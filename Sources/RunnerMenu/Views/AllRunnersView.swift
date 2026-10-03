import SwiftUI

/// Fleet totals lead to a filtered activity preview, without repeating the sidebar.
struct AllRunnersView: View {
    @Environment(RunnerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: RunnerFleetFilter?
    var compact = false
    var showRunner: (RunnerInstance) -> Void
    var showLog: (RunnerInstance) -> Void
    @FocusState private var focusedMetric: RunnerFleetFilter?
    @State private var lastMetric: RunnerFleetFilter?

    private var snapshot: RunnerFleetSnapshot {
        RunnerFleetSnapshot(runners: store.runners, statuses: store.statuses)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                ScrollView {
                    summary
                        .padding(compact ? 12 : 24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(selection != nil)
                .accessibilityHidden(selection != nil)

                if let selection {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { self.selection = nil }
                        .accessibilityHidden(true)

                    RunnerFleetActivityDrawer(
                        filter: selection,
                        entries: snapshot.entries(matching: selection),
                        close: { self.selection = nil },
                        showRunner: showRunner,
                        showLog: showLog
                    )
                    .frame(width: compact ? geometry.size.width : min(390, geometry.size.width))
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .leading) { Divider() }
                    .shadow(color: .black.opacity(0.12), radius: 12, x: -4)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(RunnerMotion.content(reduceMotion: reduceMotion), value: selection)
        .onAppear { lastMetric = selection }
        .onChange(of: selection) { _, filter in
            if let filter { lastMetric = filter }
            else { focusedMetric = lastMetric }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("All Runners").font(compact ? .headline : .title2.weight(.semibold))
                Text("Select a total to preview its runners and activity.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(RunnerFleetFilter.allCases) { filter in
                    metric(filter)
                }
            }

            HStack(spacing: 18) {
                Label(snapshot.totalCPU.map { String(format: "%.0f%% CPU", $0) } ?? "CPU —", systemImage: "cpu")
                Label(snapshot.totalMemoryMB.map { String(format: "%.0f MB", $0) } ?? "Memory —", systemImage: "memorychip")
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func metric(_ filter: RunnerFleetFilter) -> some View {
        Button {
            lastMetric = filter
            selection = filter
        } label: {
            VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                HStack {
                    Image(systemName: filter.symbol).foregroundStyle(tint(filter))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Text("\(snapshot.count(filter))")
                    .font(compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
                    .monospacedDigit()
                Text(filter.title).font(.callout.weight(.medium))
            }
            .padding(compact ? 10 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(RunnerButtonStyle(surface: .card, cornerRadius: 10))
        .focused($focusedMetric, equals: filter)
        .help("Preview \(filter.title.lowercased()): \(filter.explanation.lowercased())")
        .accessibilityLabel("\(snapshot.count(filter)) \(filter.title.lowercased())")
        .accessibilityHint("Opens the activity preview")
    }

    private func tint(_ filter: RunnerFleetFilter) -> Color {
        switch filter {
        case .all: return .accentColor
        case .active, .idle: return .green
        case .busy, .attention: return .orange
        case .stopped: return .secondary
        }
    }
}

private struct RunnerFleetActivityDrawer: View {
    @Environment(RunnerStore.self) private var store
    let filter: RunnerFleetFilter
    let entries: [RunnerFleetSnapshot.Entry]
    var close: () -> Void
    var showRunner: (RunnerInstance) -> Void
    var showLog: (RunnerInstance) -> Void
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(filter.title) · \(entries.count)").font(.headline)
                    Text(filter.explanation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(RunnerButtonStyle())
                    .help("Close activity preview (Esc)")
                    .accessibilityLabel("Close activity preview")
                    .keyboardShortcut(.cancelAction)
                    .focused($closeFocused)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        ContentUnavailableView(filter.emptyTitle, systemImage: filter.symbol,
                                               description: Text("This total updates as runner activity changes."))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(entries) { entry in
                            preview(entry)
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear { closeFocused = true }
    }

    private func preview(_ entry: RunnerFleetSnapshot.Entry) -> some View {
        let runner = entry.runner
        let status = entry.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.symbolName).foregroundStyle(status.tintColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(runner.displayName).font(.callout.weight(.semibold))
                    Text(runner.scopeLabel ?? "Not configured").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(status.state.label).font(.caption).foregroundStyle(status.tintColor)
            }
            if status.busy && status.isRunning {
                Label(status.currentJob ?? "Job in progress", systemImage: "bolt.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else if let latest = store.insight(for: runner)?.history.first {
                Label("\(latest.name) · \(latest.result.label)", systemImage: latest.result.symbolName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = status.lastError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let phase = store.updatePhases[runner.id] {
                Label(phase.label, systemImage: "shippingbox").font(.caption)
            }
            HStack {
                Button("Open Runner") { showRunner(runner) }
                Button("View Log") { showLog(runner) }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
