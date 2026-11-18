import ChatWire
import SwiftUI
import WatchtowerDesign

/// Search hits over the chats (`chat_search`): the chat's title and the snippet with the matched words marked.
public struct ChatSearchResultsView: View {
    public static let emptyLine = "No chats match."

    let search: ChatSearch
    let onOpen: (ChatSearch.Hit) -> Void

    public init(search: ChatSearch, onOpen: @escaping (ChatSearch.Hit) -> Void) {
        self.search = search
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if search.hits.isEmpty {
                Text(Self.emptyLine).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(search.hits.enumerated()), id: \.offset) { _, hit in
                Button { onOpen(hit) } label: {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(hit.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(Self.snippet(hit.snippet)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.small)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("chat.searchResults")
    }

    /// The snippet with its `ChatSearch.markStart`…`markEnd` spans in bold.
    static func snippet(_ raw: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            out += piece
            run = ""
        }
        for character in raw {
            if String(character) == ChatSearch.markStart {
                flush()
                bold = true
            } else if String(character) == ChatSearch.markEnd {
                flush()
                bold = false
            } else {
                run.append(character)
            }
        }
        flush()
        return out
    }
}
