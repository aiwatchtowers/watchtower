import SwiftUI
import WatchtowerCore

/// ⌘K (spec §3.1): FTS over chat history with highlighted snippets.
struct ChatSearchView: View {
    let search: (String) -> [ChatSearchHit]
    let onOpen: (ChatSearchHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [ChatSearchHit] = []

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search chats", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit { if let first = hits.first { open(first) } }
                .onChange(of: query) { hits = search(query) }
            Divider()
            List(hits) { hit in
                Button { open(hit) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.title.isEmpty ? "New Chat" : hit.title).font(.headline)
                        if hit.messageID != nil {
                            Text(hit.attributedSnippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 560, height: 420)
        .onExitCommand { dismiss() }
    }

    private func open(_ hit: ChatSearchHit) {
        onOpen(hit)
        dismiss()
    }
}
