import Foundation
import GRDB

/// Drives the target's "Watch" tab: the watches linked to the target, the
/// origin track it was promoted from (if any), and the merged activity feed
/// from all its watches. Applies a confirmed proposed action to THIS target.
@MainActor
@Observable
final class TargetWatchesViewModel {
    let target: Target
    private let dbPool: DatabasePool
    private let scanCenter: TrackScanCenter
    private let targetsViewModel: TargetsViewModel
    private let scanService: TrackScanService

    var watches: [Track] = []
    var originTrack: Track?
    var events: [TrackEvent] = []
    var errorMessage: String?

    private var watchesTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?

    init(target: Target,
         dbManager: DatabaseManager,
         scanService: TrackScanService,
         targetsViewModel: TargetsViewModel,
         scanCenter: TrackScanCenter) {
        self.target = target
        self.dbPool = dbManager.dbPool
        self.scanService = scanService
        self.targetsViewModel = targetsViewModel
        self.scanCenter = scanCenter
    }

    /// Human label for a feed event's source watch.
    func watchName(for trackID: Int) -> String {
        watches.first { $0.id == trackID }?.text ?? "Watch"
    }

    func start() {
        loadOriginTrack()
        let id = target.id
        let pool = dbPool
        watchesTask?.cancel()
        watchesTask = Task { [weak self] in
            let obs = ValueObservation.tracking { db in
                try TrackQueries.fetchByLinkedTarget(db, targetID: id)
            }
            do {
                for try await rows in obs.values(in: pool) {
                    guard let self else { return }
                    self.watches = rows
                }
            } catch { self?.errorMessage = error.localizedDescription }
        }
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let obs = ValueObservation.tracking { db in
                try TrackEventQueries.fetchForTarget(db, targetID: id)
            }
            do {
                for try await rows in obs.values(in: pool) {
                    guard let self else { return }
                    self.events = rows
                }
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func stop() {
        watchesTask?.cancel(); watchesTask = nil
        eventsTask?.cancel(); eventsTask = nil
    }

    private func loadOriginTrack() {
        guard target.sourceType == "track", let tid = Int(target.sourceID) else {
            originTrack = nil
            return
        }
        originTrack = try? dbPool.read { db in try TrackQueries.fetchByID(db, id: tid) }
    }
}
