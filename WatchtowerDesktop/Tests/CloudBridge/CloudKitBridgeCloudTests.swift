import CloudBridgeCore
import CloudKit
import XCTest

/// `CloudKitBridgeCloud` over a fake `BridgeDatabase`: preconditions and save policies, the signal and
/// empty-envelope guard, zone names and zone creation, batched delete checks, the change feed (order, no
/// asset download, a failed record failing the page) and the entitlement gate.
final class CloudKitBridgeCloudTests: XCTestCase {
    private let hub = "hub-acme"
    private var data: String { "DataZone-\(hub)" }
    private var relay: String { "RelayZone-\(hub)" }
    private let env = Data("WTE1-sealed".utf8)
    private var db: FakeDatabase!
    private var cloud: CloudKitBridgeCloud!

    override func setUp() {
        db = FakeDatabase()
        cloud = CloudKitBridgeCloud(hubID: hub, database: db) { true }
    }

    private func zoneID(_ name: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
    }

    private func envelope(_ result: CloudWriteResult) -> Data? {
        switch result {
        case .done(let item?), .conflict(let item?): return item.envelope
        default: return nil
        }
    }

    func testPreconditionsAndSavePolicies() async throws {
        db.put(name: "taken", zone: zoneID(relay), payload: Data("phone".utf8), tag: "t-1")
        let results = try await cloud.save(zone: relay, [
            CloudWrite(name: "plain", envelope: env),
            CloudWrite(name: "fresh", envelope: env, precondition: .absent),
            CloudWrite(name: "taken", envelope: env, precondition: .absent),
            CloudWrite(name: "taken", envelope: env, precondition: .unchanged(changeTag: "t-0", systemFields: Data()))
        ])
        guard case .done(let plain) = results[0], case .done(let fresh) = results[1] else { return XCTFail("\(results)") }
        XCTAssertEqual(plain?.envelope, env)
        XCTAssertEqual(fresh?.envelope, env)
        guard case .conflict(let existing) = results[2], case .conflict(let stale) = results[3] else { return XCTFail("\(results)") }
        XCTAssertEqual(existing?.envelope, Data("phone".utf8), "expect absent conflicts with the server copy")
        XCTAssertEqual(stale?.changeTag, "t-1", "an old tag conflicts with the current copy")
        XCTAssertEqual(db.policies, [.ifServerRecordUnchanged, .allKeys], "conditional saves compare tags, unconditional ones overwrite")

        let retried = try await cloud.save(zone: relay, [
            CloudWrite(name: "taken", envelope: env, precondition: .unchanged(changeTag: "t-1", systemFields: Data()))
        ])
        guard case .done(let saved?) = retried[0] else { return XCTFail("\(retried)") }
        XCTAssertNotEqual(saved.changeTag, "t-1")
        XCTAssertEqual(db.payload(name: "taken", zone: zoneID(relay)), env)
    }

    func testSignalsAreTheOnlyEmptyRecords() async throws {
        let results = try await cloud.save(zone: data, [
            CloudWrite(name: "sig-k1", envelope: Data()),
            CloudWrite(name: "k1", envelope: Data())
        ])
        guard case .done = results[0] else { return XCTFail("\(results)") }
        XCTAssertEqual(results[1], .refused("bad_request"))
        XCTAssertEqual(db.recordType(name: "sig-k1", zone: zoneID(data)), "WatchtowerSignal")
        XCTAssertNil(db.record(name: "sig-k1", zone: zoneID(data))?.encryptedValues["payload"] as? Data, "a signal carries no payload")
        XCTAssertNil(db.record(name: "k1", zone: zoneID(data)), "an empty envelope is never saved")
    }

    func testZoneNamesAndZoneCreation() async throws {
        do {
            _ = try await cloud.save(zone: "DataZone-other", [CloudWrite(name: "x", envelope: env)])
            XCTFail("another hub's zone was accepted")
        } catch let failure as BridgeCloudFailure {
            XCTAssertEqual(failure, .unsupportedZone)
        }
        db.zonesMissing = true
        _ = try await cloud.save(zone: data, [CloudWrite(name: "k2", envelope: env)])
        XCTAssertEqual(Set(db.createdZones.map(\.zoneName)), ["DataZone-\(hub)", "RelayZone-\(hub)"])
        XCTAssertNotNil(db.record(name: "k2", zone: zoneID(data)), "the save ran again once the zones existed")
    }

    func testConditionalDeletesReadOnceAndCompareTags() async throws {
        db.put(name: "same", zone: zoneID(relay), payload: env, tag: "t-5")
        db.put(name: "moved", zone: zoneID(relay), payload: Data("newer".utf8), tag: "t-9")
        let results = try await cloud.delete(zone: relay, [
            CloudDeletion(name: "same", precondition: .unchanged(changeTag: "t-5", systemFields: Data())),
            CloudDeletion(name: "moved", precondition: .unchanged(changeTag: "t-8", systemFields: Data())),
            CloudDeletion(name: "gone", precondition: .unchanged(changeTag: "t-1", systemFields: Data())),
            CloudDeletion(name: "whatever")
        ])
        XCTAssertEqual(db.fetches.count, 1, "one read for the whole batch")
        XCTAssertEqual(db.fetches.first?.count, 3)
        XCTAssertEqual(results[0], .done(nil))
        XCTAssertEqual(envelope(results[1]), Data("newer".utf8))
        XCTAssertEqual(results[2], .conflict(nil))
        XCTAssertEqual(results[3], .done(nil))
        XCTAssertNil(db.record(name: "same", zone: zoneID(relay)))
        XCTAssertNotNil(db.record(name: "moved", zone: zoneID(relay)), "a record rewritten since is kept")
    }

    func testChangesOrderNoAssetsAndAssetIDs() async throws {
        for name in ["c", "a", "b"] {
            db.put(name: name, zone: zoneID(relay), payload: env, tag: "t-\(name)")
        }
        db.page = FakeDatabase.Page(names: ["c", "a", "b"], failing: [], deletions: ["old"], token: Data([7]), more: true)
        let page = try await cloud.changes(zone: relay, since: nil)
        XCTAssertEqual(page.changed.map(\.name), ["a", "b", "c"], "same server time: name order")
        XCTAssertTrue(page.changed.allSatisfy(\.hasAsset), "relay records can be downloaded by name")
        XCTAssertEqual(page.deleted, ["old"])
        XCTAssertEqual(page.token, Data([7]))
        XCTAssertTrue(page.more)
        XCTAssertFalse(db.feedKeys.contains("asset"), "a change feed never downloads an asset")

        db.put(name: "s1", zone: zoneID(data), payload: env, tag: "t")
        db.page = FakeDatabase.Page(names: ["s1"], failing: [], deletions: [], token: Data([8]), more: false)
        let dataPage = try await cloud.changes(zone: data, since: Data([7]))
        XCTAssertFalse(dataPage.changed[0].hasAsset, "the hub's own data records are never downloaded")
    }

    func testAFailedRecordFailsThePage() async throws {
        db.put(name: "a", zone: zoneID(relay), payload: env, tag: "t")
        db.page = FakeDatabase.Page(names: ["a"], failing: ["b"], deletions: [], token: Data([1]), more: false)
        do {
            _ = try await cloud.changes(zone: relay, since: nil)
            XCTFail("the page passed a record that failed")
        } catch let failure as BridgeCloudFailure {
            XCTAssertEqual(failure.failureClass, "unavailable")
        }
    }

    func testDownloadFetchesTheAssetAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("audio.sealed")
        try Data("sealed-audio".utf8).write(to: source)
        db.put(name: "recupload-u1", zone: zoneID(relay), payload: env, tag: "t", asset: source)
        let dst = dir.appendingPathComponent("out.part")
        try await cloud.downloadAsset(zone: relay, name: "recupload-u1", to: dst)
        XCTAssertEqual(try Data(contentsOf: dst), Data("sealed-audio".utf8))
        XCTAssertEqual(db.fetchKeys.last, ["asset"])
        do {
            try await cloud.downloadAsset(zone: relay, name: "missing", to: dir.appendingPathComponent("x"))
            XCTFail("a record without an asset downloaded")
        } catch let failure as BridgeCloudFailure {
            XCTAssertEqual(failure, .badRequest)
        }
    }

    func testCreatorsComeFromCloudKitAsReported() async throws {
        db.put(name: "mine", zone: zoneID(relay), payload: env, tag: "t1", creator: CKCurrentUserDefaultName)
        db.put(name: "theirs", zone: zoneID(relay), payload: env, tag: "t2", creator: "_user-b")
        db.put(name: "unknown", zone: zoneID(relay), payload: env, tag: "t3", creator: nil)
        db.page = FakeDatabase.Page(names: ["mine", "theirs", "unknown"], failing: [], deletions: [], token: Data([1]), more: false)
        let page = try await cloud.changes(zone: relay, since: nil)
        let creators = Dictionary(uniqueKeysWithValues: page.changed.map { ($0.name, $0.creator) })
        XCTAssertEqual(creators["mine"], .some("__defaultOwner__"))
        XCTAssertEqual(creators["theirs"], .some("_user-b"))
        XCTAssertEqual(creators["unknown"], .some(nil))
        let conflict = try await cloud.save(zone: relay, [CloudWrite(name: "theirs", envelope: env, precondition: .absent)])
        guard case .conflict(let copy?) = conflict[0] else { return XCTFail("\(conflict)") }
        XCTAssertEqual(copy.creator, "_user-b", "a conflict's server copy carries its creator")
    }

    func testOwnerUserFromTheContainer() async throws {
        db.owner = "_owner-acme"
        let named = try await cloud.ownerUser()
        XCTAssertEqual(named, "_owner-acme")
        db.owner = nil
        let none = try await cloud.ownerUser()
        XCTAssertEqual(none, "", "no signed-in account: empty")
    }

    func testWithoutTheEntitlementNothingIsTouched() async {
        let unsigned = CloudKitBridgeCloud(hubID: hub, database: db) { false }
        do {
            _ = try await unsigned.changes(zone: relay, since: nil)
            XCTFail("an unsigned bridge reached CloudKit")
        } catch {
            XCTAssertEqual(error as? BridgeCloudFailure, .forbidden)
        }
        XCTAssertEqual(db.calls, 0)
    }

    func testFailureClasses() {
        XCTAssertEqual(bridgeFailureClass(CKError(.requestRateLimited)), "rate_limited")
        XCTAssertEqual(bridgeFailureClass(CKError(.changeTokenExpired)), "token_expired")
        XCTAssertEqual(bridgeFailureClass(CKError(.limitExceeded)), "record_too_large")
        XCTAssertEqual(bridgeFailureClass(CKError(.quotaExceeded)), "quota")
        XCTAssertEqual(bridgeFailureClass(CKError(.permissionFailure)), "forbidden")
        XCTAssertEqual(bridgeFailureClass(CKError(.networkFailure)), "unavailable")
    }
}

/// An in-memory private database: records with change tags, `.ifServerRecordUnchanged` against the save's
/// base tag, scripted change pages, and a log of every call.
final class FakeDatabase: BridgeDatabase, @unchecked Sendable {
    struct Page {
        var names: [String]
        var failing: [String]
        var deletions: [String]
        var token: Data
        var more: Bool
    }

    private let lock = NSLock()
    private var store: [CKRecord.ID: DatabaseRecord] = [:]
    private var tagCounter = 0
    private var _policies: [CKModifyRecordsOperation.RecordSavePolicy] = []
    private var _fetches: [[CKRecord.ID]] = []
    private var _fetchKeys: [[String]?] = []
    private var _feedKeys: [String] = []
    private var _createdZones: [CKRecordZone.ID] = []
    private var _calls = 0
    private var _zonesMissing = false
    private var _page: Page?

    var policies: [CKModifyRecordsOperation.RecordSavePolicy] { lock.withLock { _policies } }
    var fetches: [[CKRecord.ID]] { lock.withLock { _fetches } }
    var fetchKeys: [[String]?] { lock.withLock { _fetchKeys } }
    var feedKeys: [String] { lock.withLock { _feedKeys } }
    var createdZones: [CKRecordZone.ID] { lock.withLock { _createdZones } }
    var calls: Int { lock.withLock { _calls } }
    var zonesMissing: Bool {
        get { lock.withLock { _zonesMissing } }
        set { lock.withLock { _zonesMissing = newValue } }
    }
    var page: Page? {
        get { lock.withLock { _page } }
        set { lock.withLock { _page = newValue } }
    }

    private var _owner: String?
    var owner: String? {
        get { lock.withLock { _owner } }
        set { lock.withLock { _owner = newValue } }
    }

    func ownerUserRecordName() async throws -> String? {
        lock.withLock {
            _calls += 1
            return _owner
        }
    }

    func put(name: String, zone: CKRecordZone.ID, payload: Data, tag: String, asset: URL? = nil, creator: String? = nil) {
        let ck = CKRecord(recordType: "WatchtowerEnvelope", recordID: CKRecord.ID(recordName: name, zoneID: zone))
        ck.encryptedValues["payload"] = payload
        ck["kind"] = "wt"
        if let asset { ck["asset"] = CKAsset(fileURL: asset) }
        lock.withLock { store[ck.recordID] = DatabaseRecord(record: ck, changeTag: tag, creator: creator) }
    }

    func record(name: String, zone: CKRecordZone.ID) -> CKRecord? {
        lock.withLock { store[CKRecord.ID(recordName: name, zoneID: zone)]?.record }
    }

    func recordType(name: String, zone: CKRecordZone.ID) -> String? { record(name: name, zone: zone)?.recordType }

    func payload(name: String, zone: CKRecordZone.ID) -> Data? {
        record(name: name, zone: zone)?.encryptedValues["payload"] as? Data
    }

    private func zoneGate() throws {
        if _zonesMissing { throw CKError(.zoneNotFound) }
    }

    func save(_ saves: [DatabaseSave], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> [CKRecord.ID: DatabaseSaveResult] {
        try lock.withLock {
            _calls += 1
            try zoneGate()
            _policies.append(policy)
            var out: [CKRecord.ID: DatabaseSaveResult] = [:]
            for save in saves {
                let id = save.record.recordID
                let current = store[id]
                if policy == .ifServerRecordUnchanged, save.baseTag != current?.changeTag {
                    out[id] = .changed(current)
                    continue
                }
                tagCounter += 1
                let stored = DatabaseRecord(record: save.record, changeTag: "s-\(tagCounter)")
                store[id] = stored
                out[id] = .saved(stored)
            }
            return out
        }
    }

    func delete(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<Void, any Error>] {
        lock.withLock {
            _calls += 1
            var out: [CKRecord.ID: Result<Void, any Error>] = [:]
            for id in ids {
                store[id] = nil
                out[id] = .success(())
            }
            return out
        }
    }

    func records(_ ids: [CKRecord.ID], desiredKeys: [String]?) async throws -> [CKRecord.ID: DatabaseRecord] {
        lock.withLock {
            _calls += 1
            _fetches.append(ids)
            _fetchKeys.append(desiredKeys)
            return store.filter { ids.contains($0.key) }
        }
    }

    func zoneChanges(_ zone: CKRecordZone.ID, since token: Data?, desiredKeys: [String], limit: Int) async throws -> DatabaseChanges {
        try lock.withLock {
            _calls += 1
            try zoneGate()
            _feedKeys = desiredKeys
            let page = _page ?? Page(names: [], failing: [], deletions: [], token: Data(), more: false)
            var mods: [(id: CKRecord.ID, result: Result<DatabaseRecord, any Error>)] = []
            for name in page.names {
                let id = CKRecord.ID(recordName: name, zoneID: zone)
                if let record = store[id] { mods.append((id, .success(record))) }
            }
            for name in page.failing {
                mods.append((CKRecord.ID(recordName: name, zoneID: zone), .failure(CKError(.networkFailure))))
            }
            return DatabaseChanges(modifications: mods, deletions: page.deletions, token: page.token, more: page.more)
        }
    }

    func saveZones(_ ids: [CKRecordZone.ID]) async throws {
        lock.withLock {
            _calls += 1
            _createdZones += ids
            _zonesMissing = false
        }
    }
}
