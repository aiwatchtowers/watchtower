import Foundation

/// Test fake: an append-only event log per zone with CloudKit-like change
/// semantics (latest state per recordName since a token; deletes win).
public actor InMemoryCloudTransport: CloudSyncTransport {
    private struct Event {
        let seq: Int
        let zone: CloudZoneID
        let recordName: String
        /// nil means tombstone (deleted)
        let record: CloudRecord?
    }

    private var events: [Event] = []
    private var nextSeq = 1

    public init() {}

    public func save(_ records: [CloudRecord]) async throws {
        for record in records {
            events.append(Event(seq: nextSeq, zone: record.zone, recordName: record.recordName, record: record))
            nextSeq += 1
        }
    }

    public func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        for name in recordNames {
            events.append(Event(seq: nextSeq, zone: zone, recordName: name, record: nil))
            nextSeq += 1
        }
    }

    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        let floor = token?.value ?? 0
        let relevant = events.filter { $0.zone == zone && $0.seq > floor }

        // Latest event per recordName wins, in first-seen order.
        var latest: [String: Event] = [:]
        var order: [String] = []
        for event in relevant {
            if latest[event.recordName] == nil { order.append(event.recordName) }
            latest[event.recordName] = event
        }

        var changed: [CloudRecord] = []
        var deleted: [String] = []
        for name in order {
            if let record = latest[name]?.record {
                changed.append(record)
            } else {
                deleted.append(name)
            }
        }

        let zoneMax = relevant.map(\.seq).max() ?? floor
        return CloudChangeBatch(
            changed: changed,
            deletedRecordNames: deleted,
            newToken: CloudChangeToken(value: max(floor, zoneMax))
        )
    }
}
