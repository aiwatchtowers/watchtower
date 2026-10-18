import SwiftUI
import GRDB
import WatchtowerCore

/// Mini dialog that shows AI-proposed parent + secondary links, lets the user
/// deselect individual items, then applies the chosen set to the DB in a
/// single write transaction.
struct SuggestLinksSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let targetID: Int
    @State var suggestions: SuggestedLinksResult

    @State private var applyParent: Bool = true
    @State private var selectedLinks: Set<Int> = []
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(targetID: Int, suggestions: SuggestedLinksResult) {
        self.targetID = targetID
        self._suggestions = State(initialValue: suggestions)
        self._selectedLinks = State(initialValue: Set(suggestions.secondaryLinks.indices))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content.padding()
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 420)
        .interactiveDismissDisabled(isSaving)
    }

    private var header: some View {
        HStack {
            Text("Suggested links")
                .font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let parentID = suggestions.parentID {
                Toggle(isOn: $applyParent) {
                    Text("Set parent to target #\(parentID)")
                        .font(.callout)
                }
            }

            if !suggestions.secondaryLinks.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Secondary links")
                    .font(.subheadline)
                    .fontWeight(.medium)
                ForEach(Array(suggestions.secondaryLinks.enumerated()), id: \.offset) { idx, link in
                    linkRow(idx: idx, link: link)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func linkRow(idx: Int, link: ProposedLink) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selectedLinks.contains(idx) },
                set: { on in
                    if on {
                        selectedLinks.insert(idx)
                    } else {
                        selectedLinks.remove(idx)
                    }
                }
            ))
            .labelsHidden()
            Text(link.relation.replacingOccurrences(of: "_", with: " "))
                .font(.caption)
            if let tid = link.targetId {
                Text("→ target #\(tid)")
                    .font(.caption)
                    .fontWeight(.semibold)
            } else if !link.externalRef.isEmpty {
                Text("→ \(link.externalRef)")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Apply") { apply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasAnythingToApply || isSaving)
        }
        .padding()
    }

    private var hasAnythingToApply: Bool {
        (suggestions.parentID != nil && applyParent) || !selectedLinks.isEmpty
    }

    private func apply() {
        guard let db = appState.databaseManager else {
            errorMessage = "Database not available"
            return
        }
        let targetID = targetID
        let parentID = applyParent ? suggestions.parentID : nil
        let links = selectedLinks.sorted().map { suggestions.secondaryLinks[$0] }
        // Off the main thread: a busy database never freezes the sheet. Apply,
        // Cancel and Esc wait while the write is pending, so nothing is linked
        // twice and the sheet never closes on a write still in flight.
        Task {
            await ViewWrite.run(db.dbPool, pending: $isSaving, { dbConn in
                if let parentID {
                    try TargetQueries.updateParent(dbConn, id: targetID, parentID: parentID)
                }
                for link in links {
                    // target_links CHECK requires at least one of target_target_id / external_ref.
                    guard link.targetId != nil || !link.externalRef.isEmpty else { continue }
                    try TargetQueries.createLink(
                        dbConn, sourceID: targetID, targetID: link.targetId,
                        externalRef: link.externalRef, relation: link.relation, createdBy: "ai"
                    )
                }
            }, onSuccess: { dismiss() }, onFailure: { errorMessage = $0.localizedDescription })
        }
    }
}
