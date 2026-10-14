import CloudKit
import Foundation
import os

extension CloudKitTransport {
    // MARK: - Direct save

    /// Saves one record into `hubID`'s zone of `scope`'s database with one
    /// request, outside any engine and store: nothing is fetched first, and
    /// the save overwrites whatever the server holds (`.allKeys`, no change
    /// tag compared). The phone's unlink farewell kept after its hub's files
    /// went (#143) goes out this way. Throws the CloudKit error, the
    /// record's own included. The caller checks the entitlement first.
    public static func saveDirectly(
        _ record: CloudRecord,
        scope: CloudDatabaseScope,
        hubID: String,
        containerID: String = WatchtowerCloud.containerID
    ) async throws {
        let ck = directSaveRecord(record, scope: scope, hubID: hubID)
        let database = scope.database(in: CKContainer(identifier: containerID))
        let (saves, _) = try await database.modifyRecords(saving: [ck], deleting: [], savePolicy: .allKeys, atomically: false)
        try saves[ck.recordID]?.get()
    }

    /// The record a direct save sends: a fresh one (no system fields) in
    /// the hub's zone of the record's kind.
    static func directSaveRecord(_ record: CloudRecord, scope: CloudDatabaseScope, hubID: String) -> CKRecord {
        ckRecord(from: record, in: HubZones(scope: scope, hubID: hubID).zoneID(for: record.zone), systemFields: nil)
    }

    // MARK: - Mapping (pure, unit-tested)

    /// Builds the outgoing CKRecord, seeded from archived system fields when
    /// present so the save carries the server change tag (identity + metadata
    /// come from the archive). nil or undecodable blob → fresh record, the
    /// pre-system-fields behaviour. Payload/kind/modifiedAt always come from
    /// the CloudRecord — the archive never carries payload fields.
    static func ckRecord(from record: CloudRecord, in zoneID: CKRecordZone.ID, systemFields: Data?) -> CKRecord {
        let ck: CKRecord
        if let systemFields,
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: systemFields),
           let decoded = CKRecord(coder: unarchiver) {
            unarchiver.finishDecoding()
            ck = decoded
        } else {
            let id = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
            let type = record.kind == WireKind.signal ? Self.signalRecordType : Self.recordType
            ck = CKRecord(recordType: type, recordID: id)
        }
        // A signal carries no payload: it only names the record a subscription fires on.
        if record.kind != WireKind.signal {
            ck.encryptedValues["payload"] = record.payload
        }
        ck["kind"] = record.kind
        ck["modifiedAt"] = record.modifiedAt
        // The audio of a phone recording upload. A PLAIN field on purpose:
        // encryptedValues does not accept CKAsset, and CloudKit encrypts
        // asset content on its own. nil REMOVES the field — the desktop's
        // status write-back is what frees the iCloud storage.
        ck["asset"] = record.assetFileURL.map { CKAsset(fileURL: $0) }
        // nil REMOVES the field (isError discipline: absent, never null) —
        // an untagged save is byte-identical to a pre-Plan-6 one, and a
        // system-fields-seeded re-save cannot carry a stale tag.
        // Owner ruling (Task 3 review): encryptedValues, not a plain field —
        // "user has an urgent item right now" is content-adjacent under ADP,
        // no server query needs it, and the phone decrypts everything anyway.
        ck.encryptedValues["notifyLevel"] = record.notifyLevel
        return ck
    }

    /// Archives identity + server metadata (change tag) without payload fields.
    static func archivedSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// `zone` is the kind of the record's zone, resolved by the caller
    /// through `HubZones` (a zone name carries the hub id).
    static func cloudRecord(from ck: CKRecord, zone: CloudZoneID) -> CloudRecord? {
        let payload: Data
        switch ck.recordType {
        case Self.recordType:
            guard let sealed = ck.encryptedValues["payload"] as? Data else { return nil }
            payload = sealed
        case Self.signalRecordType:
            payload = Data()
        default:
            // The pre-E2E type (and anything unknown) after the hard cut: never read, logged once per type.
            let type = ck.recordType
            if ignoredTypesLogged.withLock({ $0.insert(type).inserted }) {
                mappingLogger.notice("ignoring records of type \(type, privacy: .public)")
            }
            return nil
        }
        return CloudRecord(
            recordName: ck.recordID.recordName,
            zone: zone,
            kind: (ck["kind"] as? String) ?? "",
            modifiedAt: (ck["modifiedAt"] as? Date) ?? Date(timeIntervalSince1970: 0),
            payload: payload,
            notifyLevel: ck.encryptedValues["notifyLevel"] as? String,
            // CloudKit's staged download location — temporary; the buffering
            // path stashes a durable copy before persisting the event.
            assetFileURL: (ck["asset"] as? CKAsset)?.fileURL,
            // The owner's own records read `CKCurrentUserDefaultName` here.
            creatorUserRecordName: ck.creatorUserRecordID?.recordName,
            serverModifiedAt: ck.modificationDate
        )
    }
}
