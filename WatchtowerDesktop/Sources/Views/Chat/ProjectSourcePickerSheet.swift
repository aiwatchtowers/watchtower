import ChatWire
import SwiftUI
import WatchtowerCore

/// Picks one entity to pin as a project source (spec §6.1): a Jira project, Slack channel, Confluence space, target,
/// track or person, searched by the engine (`entity_search` with the kind).
struct ProjectSourcePickerSheet: View {
    let client: any ChatClient
    let onPick: (ChatEntityHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "jira_project"
    @State private var query = ""
    @State private var hits: [ChatEntityHit] = []
    @State private var searchError: String?

    private static let kinds: [(String, String)] = [
        ("jira_project", "Jira project"), ("channel", "Slack channel"), ("confluence_space", "Confluence space"),
        ("target", "Target"), ("track", "Track"), ("person", "Person")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pin a source").font(.headline)
            Picker("Kind", selection: $kind) {
                ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            if let searchError {
                Text(searchError).font(.caption).foregroundStyle(Tone.error)
            }
            List(hits, id: \.self) { hit in
                Button {
                    onPick(hit)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(hit.label)
                        Text(hit.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)
            .overlay {
                if hits.isEmpty && searchError == nil {
                    Text("Nothing found").foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 600)
        .task(id: "\(kind)|\(query)") { await runSearch() }
    }

    private func runSearch() async {
        do {
            switch try await client.send(.entitySearch(query: query, kinds: [kind])) {
            case .applied(.entities(let found)):
                hits = found
                searchError = nil
            case let .refused(_, message):
                hits = []
                searchError = message.isEmpty ? "Couldn't search." : message
            case .applied:
                hits = []
            }
        } catch {
            hits = []
            searchError = "Couldn't reach Watchtower to search."
        }
    }
}
