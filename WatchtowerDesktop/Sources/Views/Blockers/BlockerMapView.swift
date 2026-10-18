import SwiftUI

struct BlockerMapView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: BlockerMapViewModel?

    /// With Jira data, no blockers is good news, in the tab's own words;
    /// before any Jira data, the shared empty state.
    static func emptyState(context: EmptyStateContext) -> some View {
        ContentAwareEmptyState(.blockers, context: context) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No blockers")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("No blocked or stale issues found in Jira")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                blockerContent(vm)
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { startViewModel() }
        .onDisappear { viewModel?.stopObserving() }
        .onChange(of: appState.isDBAvailable) { startViewModel() }
    }

    /// Builds the VM once and (re)starts its observation: onDisappear stops it.
    private func startViewModel() {
        if viewModel == nil, let db = appState.databaseManager {
            viewModel = BlockerMapViewModel(dbManager: db)
        }
        viewModel?.startObserving()
    }

    @ViewBuilder
    private func blockerContent(_ vm: BlockerMapViewModel) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Blockers")
                    .font(.title2)
                    .fontWeight(.bold)

                if !vm.blockers.isEmpty {
                    Text("\(vm.blockers.count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.red, in: Capsule())
                }

                Spacer()
            }
            .padding()

            Divider()

            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage {
                ErrorView(title: "Error", message: error, actionTitle: "Retry") { vm.load() }
            } else if vm.blockers.isEmpty {
                Self.emptyState(context: appState.emptyStateContext)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !vm.urgentBlockers.isEmpty {
                            sectionHeader(
                                "Urgent",
                                count: vm.urgentBlockers.count,
                                color: .red
                            )
                            ForEach(vm.urgentBlockers) { entry in
                                BlockerCardView(entry: entry)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            }
                        }

                        if !vm.watchBlockers.isEmpty {
                            sectionHeader(
                                "Watch",
                                count: vm.watchBlockers.count,
                                color: .secondary
                            )
                            ForEach(vm.watchBlockers) { entry in
                                BlockerCardView(entry: entry)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func sectionHeader(
        _ title: String, count: Int, color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}
