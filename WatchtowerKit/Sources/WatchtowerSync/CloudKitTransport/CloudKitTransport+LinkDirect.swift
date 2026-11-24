import CloudKit
import Foundation

/// Why a direct call (`serverRecord`, `saveDirectly(_:)`) made no request, or read nothing usable.
public enum DirectCallRefusal: Error, Equatable, Sendable {
    /// CloudKit asked this transport to wait (`throttledUntil`): no request went out.
    case throttled
    /// The hub's zones are gone (`isUnlinked`): no request went out.
    case unlinked
    /// The server holds the record, but not as one this build reads (another record type, no payload).
    case unreadableRecord
}

/// The phone's link flow outside `CKSyncEngine` (#2189): its keybox read by name and its hello saved at once, so
/// neither waits behind the full download of the Mac's zones a fresh replica starts with. Both honour the throttle
/// and the unlink as `pull()` does, and a CloudKit failure throttles or unlinks as a fetch's does. Nothing is
/// buffered or stored here: the engine fetches the saved record, and the one read, later like any other change.
/// Each request is counted (`fetchLink` for a read, `sendBatch` for a save, as the engine's sends are) only once it
/// goes out.
extension CloudKitTransport {
    /// The server's current copy of one record by its wire name: one `record(for:)`. nil only when the server has no
    /// such record (also a `partialFailure` whose entry for it is `unknownItem`); one it holds that does not map throws
    /// `DirectCallRefusal.unreadableRecord` (as `serverCopy`'s `unreadableRecord`), never nil. Throws
    /// `DirectCallRefusal.throttled`/`.unlinked` without a request, and what CloudKit threw.
    public func serverRecord(named recordName: String, in zone: CloudZoneID) async throws -> CloudRecord? {
        try checkDirectCallAllowed()
        let throttleAtStart = throttledUntil
        let id = CKRecord.ID(recordName: recordName, zoneID: zones.zoneID(for: zone))
        energy?.record(.fetchLink)
        let server: CKRecord?
        do {
            server = try await conditionalDatabase().fetchRecord(id)
        } catch let error as CKError
            where error.code == .partialFailure && (error.partialErrorsByItemID?[id] as? CKError)?.code == .unknownItem {
            server = nil
        } catch let error as CKError {
            applyDirectCallFailure(error, recordID: id)
            throw error
        }
        clearThrottle(ifStill: throttleAtStart)
        guard let server else { return nil }
        guard let record = Self.cloudRecord(from: server, zone: zone) else { throw DirectCallRefusal.unreadableRecord }
        return record
    }

    /// Saves one already sealed record now, outside the engine's queue, as the kept farewell's direct save does (a
    /// fresh record, then once over the server copy it collided with; that second try is checked against the throttle
    /// and the unlink again). Throws `DirectCallRefusal.throttled`/`.unlinked` without a request, and what CloudKit
    /// threw.
    public func saveDirectly(_ record: CloudRecord) async throws {
        try checkDirectCallAllowed()
        let throttleAtStart = throttledUntil
        let database = conditionalDatabase()
        var tries = 0
        do {
            try await Self.saveDirectly(record, scope: scope, hubID: zones.hubID) { ck in
                tries += 1
                if tries > 1 { try self.checkDirectCallAllowed() }
                self.energy?.record(.sendBatch)
                do {
                    let (saves, _) = try await database.modify(saving: [ck], deleting: [])
                    _ = try saves[ck.recordID]?.get()
                } catch let error as CKError where error.code == .partialFailure {
                    // The record's own error, so a wrapped `serverRecordChanged` still takes the retry over the copy.
                    throw (error.partialErrorsByItemID?[ck.recordID] as? CKError) ?? error
                }
            }
        } catch let error as CKError {
            applyDirectCallFailure(error, recordID: CKRecord.ID(recordName: record.recordName, zoneID: zones.zoneID(for: record.zone)))
            throw error
        }
        clearThrottle(ifStill: throttleAtStart)
    }

    /// CloudKit asked this transport to wait (`throttledUntil` not reached yet): a pull or a direct call now sends
    /// nothing.
    public var isThrottled: Bool {
        guard let throttledUntil else { return false }
        return now() < throttledUntil
    }

    private func checkDirectCallAllowed() throws {
        if isUnlinked { throw DirectCallRefusal.unlinked }
        if let throttledUntil, now() < throttledUntil { throw DirectCallRefusal.throttled }
    }
}
