import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// The calendar slices as the Calendar and Now tabs draw them, decoded from
/// the replica in one database snapshot: `calendar_event` and
/// `meeting_transcript`. An undecodable record is skipped and counted in
/// `skippedRecords`, never dropped silently.
struct CalendarReplicaSnapshot: Equatable {
    var events: [CalendarEvent] = []
    var transcripts: [MeetingTranscript] = []
    /// Undecodable records per kind in this read; kinds without any are
    /// absent.
    var skippedRecords: [SliceKind: Int] = [:]

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation tracking closure.
    static func read(from db: Database, store: ReplicaStore) throws -> Self {
        var snapshot = Self()
        snapshot.events = try snapshot.decodeAll(CalendarEvent.self, kind: .calendarEvent, store: store, from: db)
        snapshot.transcripts = try snapshot.decodeAll(MeetingTranscript.self, kind: .meetingTranscript, store: store, from: db)
        return snapshot
    }

    /// The calendar mirrors are plain Codable (RelayCoder JSON), not
    /// `SliceMirror`s, so the kind is named here.
    private mutating func decodeAll<T: Decodable>(
        _ type: T.Type,
        kind: SliceKind,
        store: ReplicaStore,
        from db: Database
    ) throws -> [T] {
        let decoder = RelayCoder.makeDecoder()
        var skipped = 0
        let decoded = try store.payloads(of: kind, from: db).compactMap { payload -> T? in
            do {
                return try decoder.decode(T.self, from: payload)
            } catch {
                skipped += 1
                return nil
            }
        }
        if skipped > 0 {
            skippedRecords[kind] = skipped
        }
        return decoded
    }

    func event(_ id: String) -> CalendarEvent? {
        events.first { $0.id == id }
    }

    /// The event's newest transcript (by `created_at`), if any.
    func transcript(forEvent id: String) -> MeetingTranscript? {
        transcripts
            .filter { $0.eventID == id }
            .max { lhs, rhs in lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id < rhs.id }
    }
}

/// Live calendar replica state: one observation for the app's lifetime,
/// re-read on every replica write.
@MainActor
@Observable
final class CalendarReplicaModel {
    private(set) var snapshot = CalendarReplicaSnapshot()
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "CalendarReplicaModel")

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        let observation = ValueObservation.tracking { db in
            try CalendarReplicaSnapshot.read(from: db, store: store)
        }
        .removeDuplicates()
        cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("calendar observation failed: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] value in
                MainActor.assumeIsolated { self?.receive(value) }
            }
        )
    }

    /// Logs the skipped records only when their count changes.
    private func receive(_ value: CalendarReplicaSnapshot) {
        if value.skippedRecords != snapshot.skippedRecords {
            for (kind, count) in value.skippedRecords.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                Self.logger.warning("\(count) undecodable \(kind.rawValue, privacy: .public) records skipped")
            }
        }
        snapshot = value
    }
}
