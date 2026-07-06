import Observation
import SwiftUI
import WatchtowerKit
import GRDB

@MainActor
@Observable
final class TracksViewModel {
    private(set) var tracks: [Track] = []
    private var cancellable: AnyDatabaseCancellable?

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        cancellable = ReplicaObserver.observe(Track.self, kind: .track, in: store) { [weak self] items in
            self?.tracks = items
                .filter { $0.dismissedAt.isEmpty }
                .sorted { $0.priorityOrder < $1.priorityOrder }
        }
    }
}

struct TracksView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = TracksViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List(model.tracks) { track in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(track.isUnread ? Color.blue : Color.clear)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.text).font(.subheadline).lineLimit(2)
                            HStack(spacing: 6) {
                                Badge(text: track.categoryLabel, color: .gray)
                                Badge(text: track.ownershipLabel, color: .blue)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .overlay { if model.tracks.isEmpty { ContentUnavailableView("No tracks", systemImage: "list.bullet.rectangle") } }
                SyncStatusFooter()
            }
            .navigationTitle("Tracks")
        }
        .onAppear { model.start(store: env.store) }
    }
}
