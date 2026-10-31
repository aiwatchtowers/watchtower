import CloudKit
import Foundation
@testable import WatchtowerSync

/// A CloudKit database for conditional writes: it keeps records by ID, hands out a fresh change tag on every
/// save and enforces `.ifServerRecordUnchanged` the way the server does. Scripted failures replace the next
/// call (`callFailures`) or one record's result (`recordFailures`).
final class FakeConditionalDatabase: ConditionalDatabase, @unchecked Sendable {
    struct Call {
        let saves: [CKRecord]
        let deletes: [CKRecord.ID]
    }

    private let lock = NSLock()
    private var records: [CKRecord.ID: CKRecord] = [:]
    private var tagSerial = 0
    private var _calls: [Call] = []
    /// Thrown by the next calls, one per call, in order.
    var callFailures: [Error] = []
    /// The result of a record's next save or delete, whatever the server holds.
    var recordFailures: [String: CKError] = [:]
    /// Thrown while a call carries more than this many records (a request-level `limitExceeded`).
    var maxRecordsPerCall = Int.max

    var calls: [Call] { lock.withLock { _calls } }

    func record(named name: String) -> CKRecord? {
        lock.withLock { records.first { $0.key.recordName == name }?.value }
    }

    /// Puts a record on the server as another device's save would, and returns the stored (tagged) copy.
    @discardableResult
    func seed(_ record: CKRecord) -> CKRecord {
        lock.withLock { store(record) }
    }

    func modify(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> (
        saves: [CKRecord.ID: Result<CKRecord, Error>],
        deletes: [CKRecord.ID: Result<Void, Error>]
    ) {
        try lock.withLock {
            _calls.append(Call(saves: saving, deletes: deleting))
            if !callFailures.isEmpty { throw callFailures.removeFirst() }
            if saving.count + deleting.count > maxRecordsPerCall { throw CKError(.limitExceeded) }
            var saves: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            for record in saving {
                if let failure = recordFailures.removeValue(forKey: record.recordID.recordName) {
                    saves[record.recordID] = .failure(failure)
                    continue
                }
                // A fresh record over an existing one, or a tag that is not the server's: refused.
                if let server = records[record.recordID] {
                    if server.recordChangeTag != record.recordChangeTag {
                        saves[record.recordID] = .failure(
                            CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))
                    } else {
                        saves[record.recordID] = .success(store(record))
                    }
                } else if record.recordChangeTag != nil {
                    saves[record.recordID] = .failure(CKError(.unknownItem))
                } else {
                    saves[record.recordID] = .success(store(record))
                }
            }
            var deletes: [CKRecord.ID: Result<Void, Error>] = [:]
            for id in deleting {
                if let failure = recordFailures.removeValue(forKey: id.recordName) {
                    deletes[id] = .failure(failure)
                } else if records.removeValue(forKey: id) == nil {
                    deletes[id] = .failure(CKError(.unknownItem))
                } else {
                    deletes[id] = .success(())
                }
            }
            return (saves, deletes)
        }
    }

    private func store(_ record: CKRecord) -> CKRecord {
        tagSerial += 1
        let stored = Self.copy(record, changeTag: "tag-\(tagSerial)")
        records[record.recordID] = stored
        return stored
    }

    /// `record` with `changeTag` as its server change tag (CloudKit sets no tag on a client-built record; the
    /// archive of its system fields is the only way in), carrying the same fields.
    static func copy(_ record: CKRecord, changeTag: String) -> CKRecord {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        guard var plist = try? PropertyListSerialization.propertyList(from: archiver.encodedData, format: nil)
                as? [String: Any],
              var objects = plist["$objects"] as? [Any] else {
            preconditionFailure("unreadable system fields archive")
        }
        objects.append(changeTag)
        plist["$objects"] = objects
        guard let xmlData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              var xml = String(data: xmlData, encoding: .utf8),
              let slot = xml.range(
                of: #"<key>ETag</key>\s*<dict>\s*<key>CF\$UID</key>\s*<integer>\d+</integer>"#,
                options: .regularExpression) else {
            preconditionFailure("no change tag slot in the system fields archive")
        }
        xml.replaceSubrange(slot, with: "<key>ETag</key><dict><key>CF$UID</key><integer>\(objects.count - 1)</integer>")
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: Data(xml.utf8)),
              let tagged = CKRecord(coder: unarchiver) else {
            preconditionFailure("undecodable tagged archive")
        }
        unarchiver.finishDecoding()
        for key in record.allKeys() {
            tagged[key] = record[key]
        }
        for key in record.encryptedValues.allKeys() {
            tagged.encryptedValues[key] = record.encryptedValues[key]
        }
        return tagged
    }
}

extension CloudKitTransport {
    /// A transport whose conditional writes go to `database`; its engine never starts.
    static func conditionalTesting(
        store: TransportStore,
        database: FakeConditionalDatabase,
        scope: CloudDatabaseScope = .shared(ownerName: "_owner-acme"),
        role: TransportRole = .phone
    ) -> CloudKitTransport {
        CloudKitTransport(
            store: store,
            scope: scope,
            hubID: HubZones.testHubID,
            role: role,
            entitlementPresent: { true },
            zoneAdmin: FakeZoneAdmin(),
            engineFactory: { _, _ in FakeSyncEngine() },
            now: { Date() },
            sleep: { _ in },
            conditionalDatabase: database
        )
    }
}
