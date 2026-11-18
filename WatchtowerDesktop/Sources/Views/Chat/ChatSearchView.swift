import ChatUI
import ChatWire
import SwiftUI
import WatchtowerCore

/// ⌘K (spec §3.1): full-text search over the chats, through the engine (`chat_search`), with the matched words
/// marked in the shared results view.
struct ChatSearchView: View {
    let list: ChatListModel
    let onOpen: (ChatSearch.Hit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search chats", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit { if let first = list.searchResult?.hits.first { open(first) } }
            Divider()
            ScrollView {
                if let result = list.searchResult, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ChatSearchResultsView(search: result, onOpen: open)
                        .padding(Spacing.cozy)
                }
            }
        }
        .frame(width: 560, height: 420)
        .task(id: query) { await list.search(query) }
        .onExitCommand { dismiss() }
    }

    private func open(_ hit: ChatSearch.Hit) {
        onOpen(hit)
        dismiss()
    }
}
