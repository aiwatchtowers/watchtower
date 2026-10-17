import GRDB
import os
import SwiftUI
import WatchtowerCore

/// Automations → Tracks: the owner's custom tracks (what each watches, when it
/// last scanned, how many events it found). A click opens the track in the
/// Tracks tab; **New track** opens the same sheet that tab uses.
struct TracksSectionView: View {
    @Environment(AppState.self) private var appState
    private static let log = Logger(subsystem: Constants.bundleID, category: "automations-tracks")

    @State private var tracks: [Track] = []
    @State private var eventCounts: [Int: Int] = [:]
    @State private var creating = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom tracks").font(.headline)
                Spacer()
                Button("New track") { creating = true }
            }
            if let loadError {
                Text("Couldn't load tracks: \(loadError)")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if tracks.isEmpty {
                Text("A track watches Slack, mail and Jira for one thing you describe, and "
                    + "reports what it finds. You have none yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        Button { appState.navigateToTrack(track.id) } label: {
                            row(track)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $creating) { CustomTrackManagementSheet(linkedTargetID: nil) }
        .task(id: appState.databaseManager?.dbPool.path) { await observe() }
    }

    private func row(_ track: Track) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.text).lineLimit(1)
                Text(CustomTrackTimelineViewModel.lastScannedText(lastRunAt: track.lastRunAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !track.enabled {
                Text("Paused").font(.caption).foregroundStyle(.secondary)
            }
            let count = eventCounts[track.id] ?? 0
            Text(count == 1 ? "1 event" : "\(count) events")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Re-reads on every change to `tracks` or `track_events`, so a track
    /// created from the sheet shows up without leaving the tab.
    private func observe() async {
        guard let pool = appState.databaseManager?.dbPool else { return }
        let observation = ValueObservation.tracking { db in
            (try TrackQueries.fetchCustomTracks(db), try TrackEventQueries.countsByTrack(db))
        }
        do {
            for try await (found, counts) in observation.values(in: pool) {
                tracks = found
                eventCounts = counts
                loadError = nil
            }
        } catch {
            Self.log.error("custom tracks observation failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }
}
