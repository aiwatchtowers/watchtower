import SwiftUI

/// Master-detail container for the Calendar screen's "Recordings" tab.
/// Owns the lightweight list (RecordingListItem — never the heavy rows) and
/// the selection; reloads when the recorder finishes a run.
struct RecordingsView: View {
    @Environment(AppState.self) private var appState
    @State private var items: [RecordingListItem] = []
    @State private var selectedID: Int64?

    var body: some View {
        HStack(spacing: 0) {
            RecordingsListView(items: items, selectedID: $selectedID)
                .frame(minWidth: 300, idealWidth: 350)

            if let selectedID {
                Divider()
                RecordingDetailView(
                    transcriptID: selectedID,
                    onDeleted: {
                        self.selectedID = nil
                        loadItems()
                    },
                    onChanged: loadItems
                )
                .id(selectedID)
                .frame(minWidth: 400, idealWidth: 500)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedID)
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
