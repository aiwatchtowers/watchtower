import SwiftUI

struct BlockerMapView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: BlockerMapViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                blockerContent(vm)
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if viewModel == nil, let db = appState.databaseManager {
                let vm = BlockerMapViewModel(dbManager: db)
                viewModel = vm
                vm.startObserving()
            }
        }
        .onChange(of: appState.isDBAvailable) {
            if viewModel == nil, let db = appState.databaseManager {
                let vm = BlockerMapViewModel(dbManager: db)
                viewModel = vm
                vm.startObserving()
            }
        }
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
            } else if vm.blockers.isEmpty {
                emptyState
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

    private var emptyState: some View {
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
