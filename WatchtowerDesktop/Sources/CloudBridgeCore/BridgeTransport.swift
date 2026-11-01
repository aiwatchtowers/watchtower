import CloudKit
import Foundation
import os
import WatchtowerSync

// The seam between the bridge's request handling and CloudKit. The bridge needs what the Kit's CKSyncEngine
// transport cannot give a request/response protocol: a conditional save answered at once with the server copy,
// a change feed with each record's change tag, and per-record results. So it talks to the private database
// directly (`CloudKitBridgeCloud`), over the Kit's record mapping, zones and errors, writing the same
// `WatchtowerEnvelope` / `WatchtowerSignal` records the Swift hub writes (Go hub plan phase 3, Known limits: the
// bridge moves onto the Kit's ConditionalTransport once that lands). Zones are named by their CloudKit names,
// one of the hub's two (the caller checked it).

/// A whole request failed; `failureClass` is the protocol's class word.
public struct BridgeCloudFailure: Error, Equatable, Sendable {
    public let failureClass: String

    public init(_ failureClass: String) {
        self.failureClass = failureClass
    }

    public static let unavailable = Self("unavailable")
    public static let tokenExpired = Self("token_expired")
    public static let forbidden = Self("forbidden")
    public static let badRequest = Self("bad_request")
    public static let unsupportedZone = Self("unsupported_zone")
}

/// A record as the bridge sees it: its sealed envelope (empty for a signal) and CloudKit's metadata.
public struct CloudItem: Equatable, Sendable {
    public var name: String
    public var envelope: Data
    /// CloudKit's change tag; never crosses the socket.
    public var changeTag: String
    /// The record's archived system fields (id, change tag, server dates — no payload field).
    public var systemFields: Data
    public var serverAt: Date?
    /// The record may carry an asset `Download` can fetch (the bridge's answer carries its name as `asset_id`).
    public var hasAsset: Bool
    /// Who created the record (`creatorUserRecordID.recordName`), for the hub's creator checks once the
    /// protocol carries it.
    public var creator: String?

    public init(
        name: String,
        envelope: Data,
        changeTag: String,
        systemFields: Data = Data(),
        serverAt: Date? = nil,
        hasAsset: Bool = false,
        creator: String? = nil
    ) {
        self.name = name
        self.envelope = envelope
        self.changeTag = changeTag
        self.systemFields = systemFields
        self.serverAt = serverAt
        self.hasAsset = hasAsset
        self.creator = creator
    }
}

public enum CloudPrecondition: Equatable, Sendable {
    /// Unconditional.
    case none
    /// Only when no record of that name exists.
    case absent
    /// Only when the record still has this change tag (its system fields carry it to CloudKit).
    case unchanged(changeTag: String, systemFields: Data)
}

public struct CloudWrite: Equatable, Sendable {
    public var name: String
    public var envelope: Data
    public var assetURL: URL?
    public var precondition: CloudPrecondition

    public init(name: String, envelope: Data, assetURL: URL? = nil, precondition: CloudPrecondition = .none) {
        self.name = name
        self.envelope = envelope
        self.assetURL = assetURL
        self.precondition = precondition
    }
}

public struct CloudDeletion: Equatable, Sendable {
    public var name: String
    public var precondition: CloudPrecondition

    public init(name: String, precondition: CloudPrecondition = .none) {
        self.name = name
        self.precondition = precondition
    }
}

public enum CloudWriteResult: Equatable, Sendable {
    /// Saved (`item` is the server's record now) or, for a deletion, gone (`item` nil).
    case done(CloudItem?)
    /// The precondition failed: the current record, nil when there is none.
    case conflict(CloudItem?)
    /// This item failed alone, with a protocol class word.
    case refused(String)
}

/// One page of a zone's changes after a server change token.
public struct CloudPage: Equatable, Sendable {
    public var changed: [CloudItem]
    public var deleted: [String]
    /// The archived server change token after this page.
    public var token: Data?
    public var more: Bool

    public init(changed: [CloudItem] = [], deleted: [String] = [], token: Data?, more: Bool = false) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
        self.more = more
    }
}

public protocol BridgeCloud: Sendable {
    /// One result per write, in order. Throws `BridgeCloudFailure` when the call failed as a whole.
    func save(zone: String, _ writes: [CloudWrite]) async throws -> [CloudWriteResult]
    /// One result per deletion, in order; deleting a missing record is done.
    func delete(zone: String, _ deletions: [CloudDeletion]) async throws -> [CloudWriteResult]
    /// The record now; nil when there is none.
    func fetch(zone: String, name: String) async throws -> CloudItem?
    /// The zone's changes after `token` (nil = everything there is now). An expired token is `.tokenExpired`.
    func changes(zone: String, since token: Data?) async throws -> CloudPage
    /// Writes the record's asset (sealed bytes) to `dst` (0600).
    func downloadAsset(zone: String, name: String, to dst: URL) async throws
    /// The Mac's iCloud user record name; "" while the account has no user.
    func ownerUser() async throws -> String
}

/// The protocol's class word for an error a CloudKit call threw.
public func bridgeFailureClass(_ error: any Error) -> String {
    if let failure = error as? BridgeCloudFailure { return failure.failureClass }
    guard let ck = error as? CKError else { return "unavailable" }
    switch ck.code {
    case .requestRateLimited, .zoneBusy: return "rate_limited"
    case .changeTokenExpired: return "token_expired"
    case .limitExceeded: return "record_too_large"
    case .quotaExceeded: return "quota"
    case .permissionFailure, .notAuthenticated, .managedAccountRestricted, .missingEntitlement: return "forbidden"
    case .invalidArguments, .badContainer, .badDatabase, .constraintViolation: return "bad_request"
    default: return "unavailable"
    }
}

// MARK: - The CloudKit database seam

/// A record CloudKit returned, with its change tag (read from the record by the live seam; a test sets it).
public struct DatabaseRecord: @unchecked Sendable {
    public let record: CKRecord
    public let changeTag: String
    /// `creatorUserRecordID.recordName` as CloudKit reports it (`__defaultOwner__` for the Mac's own user);
    /// nil when it gives none.
    public let creator: String?

    public init(record: CKRecord, changeTag: String, creator: String? = nil) {
        self.record = record
        self.changeTag = changeTag
        self.creator = creator
    }
}

/// One record to save. `baseTag` is the change tag the record's system fields carry (nil for a fresh
/// record): the live database reads it from the record itself; a fake compares it.
public struct DatabaseSave: @unchecked Sendable {
    public let record: CKRecord
    public let baseTag: String?

    public init(record: CKRecord, baseTag: String?) {
        self.record = record
        self.baseTag = baseTag
    }
}

public enum DatabaseSaveResult: @unchecked Sendable {
    case saved(DatabaseRecord)
    /// `.ifServerRecordUnchanged` failed: the server's copy (nil when CloudKit sent none).
    case changed(DatabaseRecord?)
    case failed(any Error)
}

public struct DatabaseChanges: @unchecked Sendable {
    /// Per record: the record, or the error CloudKit gave for it alone.
    public let modifications: [(id: CKRecord.ID, result: Result<DatabaseRecord, any Error>)]
    public let deletions: [String]
    /// The archived server change token after this page.
    public let token: Data
    public let more: Bool

    public init(
        modifications: [(id: CKRecord.ID, result: Result<DatabaseRecord, any Error>)],
        deletions: [String],
        token: Data,
        more: Bool
    ) {
        self.modifications = modifications
        self.deletions = deletions
        self.token = token
        self.more = more
    }
}

/// The few CloudKit database calls the bridge makes; `LiveBridgeDatabase` over `CKDatabase`, a fake in tests.
/// Zone-missing errors come back as thrown `CKError`s (`.zoneNotFound`), an expired token as
/// `BridgeCloudFailure.tokenExpired`.
public protocol BridgeDatabase: Sendable {
    func save(_ saves: [DatabaseSave], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> [CKRecord.ID: DatabaseSaveResult]
    /// One result per id; a deletion of a missing record succeeds.
    func delete(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<Void, any Error>]
    /// The records that exist (a missing one is absent from the answer), with only `desiredKeys` filled
    /// (nil = every key).
    func records(_ ids: [CKRecord.ID], desiredKeys: [String]?) async throws -> [CKRecord.ID: DatabaseRecord]
    func zoneChanges(_ zone: CKRecordZone.ID, since token: Data?, desiredKeys: [String], limit: Int) async throws -> DatabaseChanges
    func saveZones(_ ids: [CKRecordZone.ID]) async throws
    /// `CKContainer.userRecordID().recordName`; nil when there is no signed-in account.
    func ownerUserRecordName() async throws -> String?
}

/// The live seam: the container's private database.
public struct LiveBridgeDatabase: BridgeDatabase {
    public let containerID: String

    public init(containerID: String = WatchtowerCloud.containerID) {
        self.containerID = containerID
    }

    private var db: CKDatabase { CKContainer(identifier: containerID).privateCloudDatabase }

    private static func tagged(_ ck: CKRecord) -> DatabaseRecord {
        DatabaseRecord(record: ck, changeTag: ck.recordChangeTag ?? "", creator: ck.creatorUserRecordID?.recordName)
    }

    public func save(_ saves: [DatabaseSave], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> [CKRecord.ID: DatabaseSaveResult] {
        let results = try await db.modifyRecords(saving: saves.map(\.record), deleting: [], savePolicy: policy, atomically: false).saveResults
        return results.mapValues { result in
            switch result {
            case .success(let ck):
                return .saved(Self.tagged(ck))
            case .failure(let error as CKError) where error.code == .serverRecordChanged:
                return .changed(error.serverRecord.map(Self.tagged))
            case .failure(let error):
                return .failed(error)
            }
        }
    }

    public func delete(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<Void, any Error>] {
        try await db.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false).deleteResults
    }

    public func records(_ ids: [CKRecord.ID], desiredKeys: [String]?) async throws -> [CKRecord.ID: DatabaseRecord] {
        var out: [CKRecord.ID: DatabaseRecord] = [:]
        for (id, result) in try await db.records(for: ids, desiredKeys: desiredKeys) {
            switch result {
            case .success(let ck):
                out[id] = Self.tagged(ck)
            case .failure(let error as CKError) where error.code == .unknownItem:
                continue
            case .failure(let error):
                throw error
            }
        }
        return out
    }

    public func zoneChanges(_ zone: CKRecordZone.ID, since token: Data?, desiredKeys: [String], limit: Int) async throws -> DatabaseChanges {
        var serverToken: CKServerChangeToken?
        if let token {
            guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token) else {
                throw BridgeCloudFailure.tokenExpired
            }
            serverToken = decoded
        }
        let page = try await db.recordZoneChanges(inZoneWith: zone, since: serverToken, desiredKeys: desiredKeys, resultsLimit: limit)
        let modifications = page.modificationResultsByID.map { id, result in
            (id: id, result: result.map { Self.tagged($0.record) })
        }
        let archived = try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true)
        return DatabaseChanges(
            modifications: modifications, deletions: page.deletions.map(\.recordID.recordName), token: archived,
            more: page.moreComing)
    }

    public func saveZones(_ ids: [CKRecordZone.ID]) async throws {
        _ = try await db.modifyRecordZones(saving: ids.map { CKRecordZone(zoneID: $0) }, deleting: [])
    }

    public func ownerUserRecordName() async throws -> String? {
        do {
            return try await CKContainer(identifier: containerID).userRecordID().recordName
        } catch let error as CKError where error.code == .notAuthenticated {
            return nil
        }
    }
}

// MARK: - CloudKit

/// The bridge's CloudKit backend: the hub's two zones in the Mac user's private database, through a
/// `BridgeDatabase`. Without the iCloud entitlement (an unsigned build) it never touches the database, which
/// would crash: every call is `forbidden`. A change feed never downloads an asset (`desiredKeys` leaves it
/// out): every relay-zone record carries its name as `asset_id`, and `Download` fetches the asset alone —
/// the hub asks only for the recordings whose sealed frame names an asset.
public struct CloudKitBridgeCloud: BridgeCloud {
    public let hubID: String
    private let database: any BridgeDatabase
    private let entitlementPresent: @Sendable () -> Bool
    /// CloudKit's change page limit; the bridge splits a page that does not fit a frame.
    static let pageLimit = 200
    /// Every key but the asset.
    static let feedKeys = ["kind", "modifiedAt", "payload", "notifyLevel"]

    public init(
        hubID: String,
        database: any BridgeDatabase = LiveBridgeDatabase(),
        entitlementPresent: (@Sendable () -> Bool)? = nil
    ) {
        self.hubID = hubID
        self.database = database
        self.entitlementPresent = entitlementPresent ?? { CloudKitTransport.entitlementPresent() }
    }

    private var zones: HubZones { HubZones(scope: .private, hubID: hubID) }

    private func db() throws -> any BridgeDatabase {
        guard entitlementPresent() else { throw BridgeCloudFailure.forbidden }
        return database
    }

    private func zone(_ name: String) throws -> (id: CKRecordZone.ID, kind: CloudZoneID) {
        guard let kind = CloudZoneID.allCases.first(where: { zones.zoneID(for: $0).zoneName == name }) else {
            throw BridgeCloudFailure.unsupportedZone
        }
        return (zones.zoneID(for: kind), kind)
    }

    /// Runs `body`, and once more after creating the hub's zones when CloudKit says a zone is missing.
    private func withZones<T>(_ db: any BridgeDatabase, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            try await db.saveZones(zones.allZoneIDs)
            return try await body()
        }
    }

    static func isSignal(_ name: String, _ envelope: Data) -> Bool {
        envelope.isEmpty && name.hasPrefix("\(WireKind.signal)-")
    }

    private func item(_ fetched: DatabaseRecord, kind: CloudZoneID) -> CloudItem? {
        let ck = fetched.record
        guard let record = CloudKitTransport.cloudRecord(from: ck, zone: kind) else { return nil }
        return CloudItem(
            name: ck.recordID.recordName, envelope: record.payload, changeTag: fetched.changeTag,
            systemFields: CloudKitTransport.archivedSystemFields(of: ck), serverAt: ck.modificationDate,
            hasAsset: kind == .relay, creator: fetched.creator)
    }

    public func save(zone name: String, _ writes: [CloudWrite]) async throws -> [CloudWriteResult] {
        let db = try db()
        let (zoneID, kind) = try zone(name)
        var results = [CloudWriteResult?](repeating: nil, count: writes.count)
        var conditional: [(Int, DatabaseSave)] = [], plain: [(Int, DatabaseSave)] = []
        for (i, write) in writes.enumerated() {
            let signal = Self.isSignal(write.name, write.envelope)
            guard signal || !write.envelope.isEmpty else {
                // Only a sig- record is payload-free; an empty envelope anywhere else is not a sealed record.
                results[i] = .refused("bad_request")
                continue
            }
            let record = CloudRecord(
                recordName: write.name, zone: kind, kind: signal ? WireKind.signal : WireKind.envelope,
                modifiedAt: Date(), payload: write.envelope, assetFileURL: write.assetURL)
            switch write.precondition {
            case .none:
                plain.append((i, DatabaseSave(record: CloudKitTransport.ckRecord(from: record, in: zoneID, systemFields: nil), baseTag: nil)))
            case .absent:
                conditional.append((i, DatabaseSave(record: CloudKitTransport.ckRecord(from: record, in: zoneID, systemFields: nil), baseTag: nil)))
            case let .unchanged(tag, fields):
                let based = CloudKitTransport.ckRecord(from: record, in: zoneID, systemFields: fields)
                conditional.append((i, DatabaseSave(record: based, baseTag: tag)))
            }
        }
        // CloudKit compares change tags only under .ifServerRecordUnchanged; an unconditional save overwrites.
        for (group, policy) in [(conditional, CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged), (plain, .allKeys)]
        where !group.isEmpty {
            let saved = try await withZones(db) { try await db.save(group.map(\.1), policy: policy) }
            for (i, pending) in group {
                switch saved[pending.record.recordID] {
                case .saved(let server)?:
                    results[i] = item(server, kind: kind).map { .done($0) } ?? .refused("unavailable")
                case .changed(let server)?:
                    results[i] = .conflict(server.flatMap { item($0, kind: kind) })
                case .failed(let error)?:
                    results[i] = .refused(bridgeFailureClass(error))
                case nil:
                    results[i] = .refused("unavailable")
                }
            }
        }
        return results.map { $0 ?? .refused("unavailable") }
    }

    public func delete(zone name: String, _ deletions: [CloudDeletion]) async throws -> [CloudWriteResult] {
        let db = try db()
        let (zoneID, kind) = try zone(name)
        // CloudKit has no conditional delete. A conditional one is checked against one fresh read of the
        // batch just before: a write that lands between that read and the delete is lost. The hub deletes
        // conditionally only records written once under their name (ordered actions, controls) or its own
        // echoes, so the window loses no phone write (Go hub plan phase 3, Task 10).
        let checked = deletions.indices.filter { deletions[$0].precondition != .none }
        let ids = deletions.map { CKRecord.ID(recordName: $0.name, zoneID: zoneID) }
        var current: [CKRecord.ID: DatabaseRecord] = [:]
        if !checked.isEmpty {
            do {
                current = try await db.records(checked.map { ids[$0] }, desiredKeys: Self.feedKeys)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                current = [:]
            }
        }
        var results = [CloudWriteResult?](repeating: nil, count: deletions.count)
        var sendable: [Int] = []
        for (i, deletion) in deletions.enumerated() {
            let now = current[ids[i]]
            switch deletion.precondition {
            case .none:
                sendable.append(i)
            case .absent:
                if let now { results[i] = .conflict(item(now, kind: kind)) } else { results[i] = .done(nil) }
            case .unchanged(let tag, _):
                if let now, now.changeTag == tag { sendable.append(i) } else { results[i] = .conflict(now.flatMap { item($0, kind: kind) }) }
            }
        }
        if !sendable.isEmpty {
            let deleted: [CKRecord.ID: Result<Void, any Error>]
            do {
                deleted = try await db.delete(sendable.map { ids[$0] })
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                deleted = [:] // no zone, no record: what was asked for
            }
            for i in sendable {
                switch deleted[ids[i]] {
                case .failure(let error as CKError)? where error.code == .unknownItem || error.code == .zoneNotFound:
                    results[i] = .done(nil)
                case .failure(let error)?:
                    results[i] = .refused(bridgeFailureClass(error))
                case .success?, nil:
                    results[i] = .done(nil)
                }
            }
        }
        return results.map { $0 ?? .refused("unavailable") }
    }

    public func fetch(zone name: String, name recordName: String) async throws -> CloudItem? {
        let db = try db()
        let (zoneID, kind) = try zone(name)
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            return try await db.records([id], desiredKeys: Self.feedKeys)[id].flatMap { item($0, kind: kind) }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            return nil
        }
    }

    /// A record that fails alone fails the page: its cursor would otherwise pass a record the hub never saw.
    public func changes(zone name: String, since token: Data?) async throws -> CloudPage {
        let db = try db()
        let (zoneID, kind) = try zone(name)
        let page = try await withZones(db) {
            try await db.zoneChanges(zoneID, since: token, desiredKeys: Self.feedKeys, limit: Self.pageLimit)
        }
        var changed: [(Date, String, CloudItem)] = []
        for (id, result) in page.modifications {
            switch result {
            case .success(let fetched):
                guard let it = item(fetched, kind: kind) else { continue } // another record type: never read
                changed.append((fetched.record.modificationDate ?? .distantPast, id.recordName, it))
            case .failure(let error):
                let failureClass = bridgeFailureClass(error)
                bridgeLogger.error("a record of the change page failed: \(failureClass, privacy: .public); page refused")
                throw BridgeCloudFailure(failureClass)
            }
        }
        changed.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        return CloudPage(changed: changed.map(\.2), deleted: page.deletions, token: page.token, more: page.more)
    }

    public func downloadAsset(zone name: String, name recordName: String, to dst: URL) async throws {
        let db = try db()
        let (zoneID, _) = try zone(name)
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        guard let url = (try await db.records([id], desiredKeys: ["asset"])[id]?.record["asset"] as? CKAsset)?.fileURL else {
            throw BridgeCloudFailure.badRequest
        }
        try FileManager.default.copyItem(at: url, to: dst)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
    }

    public func ownerUser() async throws -> String {
        try await db().ownerUserRecordName() ?? ""
    }
}

/// The bridge's log: ids, counts and classes only (FILES-01), never an envelope or a path's contents.
let bridgeLogger = Logger(subsystem: "com.watchtower.desktop.cloudbridge", category: "bridge")
