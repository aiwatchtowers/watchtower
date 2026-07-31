import SwiftUI

/// Master-detail container for the Calendar screen's "Recordings" tab.
/// Owns the lightweight list (RecordingListItem — never the heavy rows) and
/// the selection; reloads when the recorder finishes a run.
struct RecordingsView: View {
    /// Optional external selection binding — the Calendar screen passes its
    /// own state so the Events tab can deep-link into a specific recording;
    /// when nil the view owns selection locally.
    var externalSelection: Binding<Int64?>?
    /// Navigate to the Events tab with this event expanded (the recording
    /// header's "Linked to:" tap); nil hides the navigation affordance.
    var onOpenEvent: ((String) -> Void)?

    @Environment(AppState.self) private var appState
    @State private var items: [RecordingListItem] = []
    @State private var localSelectedID: Int64?

    private var selectedID: Binding<Int64?> {
        externalSelection ?? $localSelectedID
    }

    var body: some View {
        HStack(spacing: 0) {
            RecordingsListView(items: items, selectedID: selectedID)
                .frame(minWidth: 300, idealWidth: 350)

            if let selected = selectedID.wrappedValue {
                Divider()
                RecordingDetailView(
                    transcriptID: selected,
                    onDeleted: {
                        selectedID.wrappedValue = nil
                        loadItems()
                    },
                    onChanged: loadItems,
                    onOpenEvent: onOpenEvent
                )
                .id(selected)
                .frame(minWidth: 400, idealWidth: 500)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedID.wrappedValue)
        .onAppear(perform: loadItems)
        .onChange(of: appState.meetingRecorderCenter.phase) { _, phase in
            if case .idle = phase { loadItems() }
        }
    }

    private func loadItems() {
        guard let db = appState.databaseManager else { return }
        do {
            items = try db.dbPool.read { conn in
                try MeetingTranscriptQueries.fetchRecordingList(conn)
            }
        } catch {
            // Silent: table may not exist yet on older DB schema versions.
        }
    }
}
