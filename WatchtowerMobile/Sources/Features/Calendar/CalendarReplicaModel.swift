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

    /// The slice kinds this snapshot decodes.
    static let kinds: [SliceKind] = [.calendarEvent, .meetingTranscript]

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation fetch. A kind whose change stamp is unchanged comes
    /// from `cache` undecoded; the default fresh cache decodes everything.
    static func read(from db: Database, store: ReplicaStore, cache: ReplicaDecodeCache = ReplicaDecodeCache()) throws -> Self {
        let versions = try store.kindVersions(kinds, from: db)
        var snapshot = Self()
        snapshot.events = try snapshot.decodeAll(
            CalendarEvent.self, kind: .calendarEvent, store: store, from: db, cache: cache, versions: versions
        )
        snapshot.transcripts = try snapshot.decodeAll(
            MeetingTranscript.self, kind: .meetingTranscript, store: store, from: db, cache: cache, versions: versions
        )
        return snapshot
    }

    /// One kind's decoded records and how many did not decode.
    private struct Decoded<T> {
        let records: [T]
        let skipped: Int
    }

    /// The calendar mirrors are plain Codable (RelayCoder JSON), not
    /// `SliceMirror`s, so the kind is named here.
    private mutating func decodeAll<T: Decodable>(
        _ type: T.Type,
        kind: SliceKind,
        store: ReplicaStore,
        from db: Database,
        cache: ReplicaDecodeCache,
        versions: [SliceKind: Int64]
    ) throws -> [T] {
        let decoded = try cache.value(kind.rawValue, version: versions[kind] ?? 0) {
            let decoder = RelayCoder.makeDecoder()
            var skipped = 0
            let records = try store.payloads(of: kind, from: db).compactMap { payload -> T? in
                do {
                    return try decoder.decode(T.self, from: payload)
                } catch {
                    skipped += 1
                    return nil
                }
            }
            return Decoded(records: records, skipped: skipped)
        }
        if decoded.skipped > 0 {
            skippedRecords[kind] = decoded.skipped
        }
        return decoded.records
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

/// Live calendar replica state: one observation for the app's lifetime
/// over its kinds' change stamps; only a calendar write decodes again.
@MainActor
@Observable
final class CalendarReplicaModel {
    private(set) var snapshot = CalendarReplicaSnapshot()
    /// The decoded kinds between reads (and the tests' decode counter).
    @ObservationIgnored let decodeCache = ReplicaDecodeCache()
    @ObservationIgnored private var cancellable: ResilientObservation?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "CalendarReplicaModel")

    func start(store: ReplicaStore, gate: ReplicaObservationGate? = nil) {
        guard cancellable == nil else { return }
        let cache = decodeCache
        cancellable = ResilientObservation(
            name: "calendar",
            reader: store.reader,
            gate: gate,
            observation: {
                ValueObservation.tracking(regions: [ReplicaStore.kindVersionsRegion]) { db in
                    try CalendarReplicaSnapshot.read(from: db, store: store, cache: cache)
                }
                .removeDuplicates()
            },
            onChange: { [weak self] value in self?.receive(value) }
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
