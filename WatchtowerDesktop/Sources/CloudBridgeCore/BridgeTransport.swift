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

// MARK: - CloudKit

/// The bridge's CloudKit backend: the hub's two zones in the Mac user's private database. Without the iCloud
/// entitlement (an unsigned build) it never touches `CKContainer`, which would crash: every call is
/// `forbidden`. A record's fetched asset is moved into `stashDirectory` (the bridge's own state dir) until
/// `Download` takes it, so an upload's audio is fetched once.
public struct CloudKitBridgeCloud: BridgeCloud {
    public let hubID: String
    public let containerID: String
    public let stashDirectory: URL
    private let entitlementPresent: @Sendable () -> Bool
    /// CloudKit's own change page limit; the bridge splits a page that does not fit a frame.
    static let pageLimit = 200

    public init(
        hubID: String,
        stashDirectory: URL,
        containerID: String = WatchtowerCloud.containerID,
        entitlementPresent: (@Sendable () -> Bool)? = nil
    ) {
        self.hubID = hubID
        self.stashDirectory = stashDirectory
        self.containerID = containerID
        self.entitlementPresent = entitlementPresent ?? { CloudKitTransport.entitlementPresent(containerID: containerID) }
    }

    private var zones: HubZones { HubZones(scope: .private, hubID: hubID) }

    private func database() throws -> CKDatabase {
        guard entitlementPresent() else { throw BridgeCloudFailure.forbidden }
        return CKContainer(identifier: containerID).privateCloudDatabase
    }

    private func zone(_ name: String) throws -> (id: CKRecordZone.ID, kind: CloudZoneID) {
        guard let kind = CloudZoneID.allCases.first(where: { zones.zoneID(for: $0).zoneName == name }) else {
            throw BridgeCloudFailure.unsupportedZone
        }
        return (zones.zoneID(for: kind), kind)
    }

    /// Creates the hub's two zones (the hub role owns them); an existing zone is kept.
    private func ensureZones(_ db: CKDatabase) async throws {
        _ = try await db.modifyRecordZones(saving: zones.allZoneIDs.map { CKRecordZone(zoneID: $0) }, deleting: [])
    }

    /// Runs `body`, and once more after creating the zones when CloudKit says a zone is missing.
    private func withZones<T>(_ db: CKDatabase, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            try await ensureZones(db)
            return try await body()
        }
    }

    static func isSignal(_ name: String, _ envelope: Data) -> Bool {
        envelope.isEmpty && name.hasPrefix("\(WireKind.signal)-")
    }

    private func item(_ ck: CKRecord, kind: CloudZoneID) -> CloudItem? {
        guard let record = CloudKitTransport.cloudRecord(from: ck, zone: kind) else { return nil }
        return CloudItem(
            name: ck.recordID.recordName, envelope: record.payload, changeTag: ck.recordChangeTag ?? "",
            systemFields: CloudKitTransport.archivedSystemFields(of: ck), serverAt: ck.modificationDate,
            hasAsset: record.assetFileURL != nil, creator: record.origin.author)
    }

    public func save(zone name: String, _ writes: [CloudWrite]) async throws -> [CloudWriteResult] {
        let db = try database()
        let (zoneID, kind) = try zone(name)
        var results = [CloudWriteResult?](repeating: nil, count: writes.count)
        var records: [Int: CKRecord] = [:]
        for (i, write) in writes.enumerated() {
            let signal = Self.isSignal(write.name, write.envelope)
            guard signal || !write.envelope.isEmpty else {
                results[i] = .refused("bad_request")
                continue
            }
            let record = CloudRecord(
                recordName: write.name, zone: kind, kind: signal ? WireKind.signal : WireKind.envelope,
                modifiedAt: Date(), payload: write.envelope, assetFileURL: write.assetURL)
            var systemFields: Data?
            if case .unchanged(_, let fields) = write.precondition { systemFields = fields }
            records[i] = CloudKitTransport.ckRecord(from: record, in: zoneID, systemFields: systemFields)
        }
        // CloudKit compares change tags only under .ifServerRecordUnchanged; an unconditional save overwrites.
        let conditional = records.filter { writes[$0.key].precondition != .none }
        let plain = records.filter { writes[$0.key].precondition == .none }
        for (group, policy) in [(conditional, CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged), (plain, .allKeys)]
        where !group.isEmpty {
            let saved = try await withZones(db) {
                try await db.modifyRecords(saving: Array(group.values), deleting: [], savePolicy: policy, atomically: false).saveResults
            }
            for (i, ck) in group {
                switch saved[ck.recordID] {
                case .success(let server):
                    results[i] = .done(item(server, kind: kind))
                case .failure(let error as CKError) where error.code == .serverRecordChanged:
                    results[i] = .conflict(error.serverRecord.flatMap { item($0, kind: kind) })
                case .failure(let error):
                    results[i] = .refused(bridgeFailureClass(error))
                case nil:
                    results[i] = .refused("unavailable")
                }
            }
        }
        return results.map { $0 ?? .refused("unavailable") }
    }

    public func delete(zone name: String, _ deletions: [CloudDeletion]) async throws -> [CloudWriteResult] {
        let db = try database()
        let (zoneID, _) = try zone(name)
        var results = [CloudWriteResult?](repeating: nil, count: deletions.count)
        var ids: [Int: CKRecord.ID] = [:]
        for (i, deletion) in deletions.enumerated() {
            // CloudKit has no conditional delete: the precondition is checked against a fresh read just before
            // (a write landing between the read and the delete is lost — accepted, the hub's deletes of a
            // phone's records follow its own reads).
            switch deletion.precondition {
            case .none:
                break
            case .absent:
                if let current = try await fetch(zone: name, name: deletion.name) {
                    results[i] = .conflict(current)
                    continue
                }
            case .unchanged(let tag, _):
                let current = try await fetch(zone: name, name: deletion.name)
                guard let current, current.changeTag == tag else {
                    results[i] = .conflict(current)
                    continue
                }
            }
            ids[i] = CKRecord.ID(recordName: deletion.name, zoneID: zoneID)
        }
        if !ids.isEmpty {
            let deleted: [CKRecord.ID: Result<Void, any Error>]
            do {
                deleted = try await db.modifyRecords(saving: [], deleting: Array(ids.values), savePolicy: .allKeys, atomically: false).deleteResults
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                deleted = [:] // no zone, no record: what was asked for
            }
            for (i, id) in ids {
                switch deleted[id] {
                case .failure(let error as CKError) where error.code != .unknownItem && error.code != .zoneNotFound:
                    results[i] = .refused(bridgeFailureClass(error))
                default:
                    results[i] = .done(nil)
                }
                removeStash(zone: name, name: deletions[i].name)
            }
        }
        return results.map { $0 ?? .refused("unavailable") }
    }

    public func fetch(zone name: String, name recordName: String) async throws -> CloudItem? {
        let db = try database()
        let (zoneID, kind) = try zone(name)
        do {
            let ck = try await db.record(for: CKRecord.ID(recordName: recordName, zoneID: zoneID))
            return item(ck, kind: kind)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    public func changes(zone name: String, since token: Data?) async throws -> CloudPage {
        let db = try database()
        let (zoneID, kind) = try zone(name)
        var serverToken: CKServerChangeToken?
        if let token {
            guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token) else {
                throw BridgeCloudFailure.tokenExpired
            }
            serverToken = decoded
        }
        let page = try await withZones(db) {
            try await db.recordZoneChanges(inZoneWith: zoneID, since: serverToken, desiredKeys: nil, resultsLimit: Self.pageLimit)
        }
        var changed: [(Date, CloudItem)] = []
        for (_, result) in page.modificationResultsByID {
            guard case .success(let modification) = result, let it = item(modification.record, kind: kind) else { continue }
            if let asset = (modification.record["asset"] as? CKAsset)?.fileURL {
                stash(asset, zone: name, name: it.name)
            }
            changed.append((modification.record.modificationDate ?? .distantPast, it))
        }
        let deleted = page.deletions.map(\.recordID.recordName)
        deleted.forEach { removeStash(zone: name, name: $0) }
        let archived = try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true)
        return CloudPage(
            changed: changed.sorted { $0.0 < $1.0 }.map(\.1), deleted: deleted, token: archived, more: page.moreComing)
    }

    public func downloadAsset(zone name: String, name recordName: String, to dst: URL) async throws {
        let fm = FileManager.default
        let stashed = stashURL(zone: name, name: recordName)
        if fm.fileExists(atPath: stashed.path) {
            try fm.moveItem(at: stashed, to: dst)
        } else {
            let db = try database()
            let (zoneID, _) = try zone(name)
            let ids = [CKRecord.ID(recordName: recordName, zoneID: zoneID)]
            let fetched = try await db.records(for: ids, desiredKeys: ["asset"])
            guard let ck = try fetched[ids[0]]?.get(), let url = (ck["asset"] as? CKAsset)?.fileURL else {
                throw BridgeCloudFailure.badRequest
            }
            try fm.copyItem(at: url, to: dst)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
    }

    // MARK: Asset stash

    private func stashURL(zone: String, name: String) -> URL {
        stashDirectory.appendingPathComponent(Self.fileName(zone)).appendingPathComponent(Self.fileName(name))
    }

    /// A record or zone name as a file name: [A-Za-z0-9-] kept, every other byte as `_xx`.
    static func fileName(_ name: String) -> String {
        let parts = name.utf8.map { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, 0x2d: return String(UnicodeScalar(byte))
            default: return String(format: "_%02x", byte)
            }
        }
        return parts.joined()
    }

    private func stash(_ file: URL, zone: String, name: String) {
        let fm = FileManager.default
        let dst = stashURL(zone: zone, name: name)
        do {
            try fm.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: file, to: dst)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        } catch {
            // Download fetches the asset again.
            bridgeLogger.notice("asset stash failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func removeStash(zone: String, name: String) {
        try? FileManager.default.removeItem(at: stashURL(zone: zone, name: name))
    }
}

/// The bridge's log: ids, counts and classes only (FILES-01), never an envelope or a path's contents.
let bridgeLogger = Logger(subsystem: "com.watchtower.desktop.cloudbridge", category: "bridge")
