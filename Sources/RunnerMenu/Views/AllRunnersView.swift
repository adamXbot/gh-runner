import SwiftUI

/// One expandable card per runner. Expansion belongs to the parent so navigating
/// to a log or update screen doesn't lose the user's overview.
struct AllRunnersView: View {
    @Environment(RunnerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var expandedRunnerIDs: Set<String>
    var showLog: (RunnerInstance) -> Void
    var showUpdates: (RunnerInstance) -> Void
    var showLabels: (RunnerInstance) -> Void

    private var runnerIDs: Set<String> { Set(store.runners.map(\.id)) }
    private var allExpanded: Bool { !runnerIDs.isEmpty && runnerIDs.isSubset(of: expandedRunnerIDs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("All Runners").font(.headline)
                Spacer()
                Button {
                    expandedRunnerIDs = allExpanded ? [] : runnerIDs
                } label: {
                    Label(allExpanded ? "Collapse All" : "Expand All",
                          systemImage: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .buttonStyle(RunnerButtonStyle())
                .font(.caption)
                .help(allExpanded ? "Hide details for every runner" : "Show details for every runner")
                .disabled(runnerIDs.isEmpty)
            }

            ForEach(store.runners) { runner in
                VStack(alignment: .leading, spacing: 0) {
                    RunnerRowView(instance: runner, isSelected: false, expansion: expansion(for: runner))

                    if expandedRunnerIDs.contains(runner.id) {
                        RunnerDetailView(
                            instance: runner,
                            showLog: { showLog(runner) },
                            showUpdates: { showUpdates(runner) },
                            showLabels: { showLabels(runner) },
                            showsPrimaryControl: false
                        )
                        .padding(12)
                        .transition(.opacity)
                    }
                }
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.15))
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(RunnerMotion.content(reduceMotion: reduceMotion), value: expandedRunnerIDs)
        .onAppear { expandedRunnerIDs.formIntersection(runnerIDs) }
        .onChange(of: runnerIDs) { _, ids in expandedRunnerIDs.formIntersection(ids) }
    }

    private func expansion(for runner: RunnerInstance) -> Binding<Bool> {
        Binding(
            get: { expandedRunnerIDs.contains(runner.id) },
            set: { expanded in
                if expanded { expandedRunnerIDs.insert(runner.id) }
                else { expandedRunnerIDs.remove(runner.id) }
            }
        )
    }
}
