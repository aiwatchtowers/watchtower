import GRDB
import SwiftUI
import WatchtowerCore

/// Picks one entity to pin as a project source (spec §6.1): a Jira project,
/// Slack channel, target, track or person, from the local DB.
struct ProjectSourcePickerSheet: View {
    let dbPool: DatabasePool
    let onPick: (ChatEntityHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ChatEntityKind = .jiraProject
    @State private var query = ""
    @State private var hits: [ChatEntityHit] = []
    @State private var searchError: String?

    private static let kinds: [(ChatEntityKind, String)] = [
        (.jiraProject, "Jira project"), (.channel, "Slack channel"),
        (.target, "Target"), (.track, "Track"), (.person, "Person")
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
                Text(searchError).font(.caption).foregroundStyle(.red)
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
        .frame(width: 460)
        .onAppear(perform: runSearch)
        .onChange(of: kind) { runSearch() }
        .onChange(of: query) { runSearch() }
    }

    private func runSearch() {
        do {
            hits = try dbPool.read { try ChatEntitySearch.search($0, kind: kind, query: query, limit: 30) }
            searchError = nil
        } catch {
            hits = []
            searchError = error.localizedDescription
        }
    }
}
