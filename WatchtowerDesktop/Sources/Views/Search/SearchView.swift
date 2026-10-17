import SwiftUI
import WatchtowerCore

struct SearchView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: SearchViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                searchContent(vm)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Search")
        .onAppear {
            if let db = appState.databaseManager, viewModel == nil {
                viewModel = SearchViewModel(dbManager: db)
            }
        }
    }

    private func searchContent(_ vm: SearchViewModel) -> some View {
        @Bindable var vm = vm
        return VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                SearchField(text: $vm.query, placeholder: "Search Slack messages and help…")
                    .frame(height: 22)
                    .onChange(of: vm.query) { vm.search() }

                if vm.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if !vm.guideHits.isEmpty {
                helpSection(vm)
                Divider()
            }

            // Results
            if vm.results.isEmpty && !vm.query.isEmpty && !vm.isSearching {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    // Guide rows above already answered: only Slack came up empty.
                    Text(vm.guideHits.isEmpty ? "No results for \"\(vm.query)\"" : "No Slack messages for \"\(vm.query)\"")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Type to search across all Slack messages")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.results) { result in
                    SearchResultRow(
                        result: result,
                        slackChannelURL: vm.slackChannelURL(channelID: result.channelID)
                    )
                }

                if vm.results.count >= 100 {
                    Text("Showing first 100 results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
    }

    private func helpSection(_ vm: SearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Help").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(vm.guideHits, id: \.path) { hit in
                Button { NSWorkspace.shared.open(hit.url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "book").foregroundStyle(.secondary)
                        Text(hit.title).fontWeight(.medium)
                        if let heading = hit.heading {
                            Text(heading).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button("Ask in chat") { appState.openHelpChat(prefill: vm.query) }
                .buttonStyle(.link)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
