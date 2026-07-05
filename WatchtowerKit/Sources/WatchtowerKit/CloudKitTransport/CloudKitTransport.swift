import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

/// Result of probing the CloudKit account. `.unavailable` carries a
/// human-readable reason (missing entitlement, network, CK errors).
public enum CloudAvailability: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case unavailable(String)
}

/// CloudKit adapter for the CloudSyncTransport seam, built on CKSyncEngine.
/// Push-shaped engine events land in the TransportStore buffer; the seam's
/// pull-shaped changes(since:) reads that buffer, so consumer tokens are
/// local seqs and CKServerChangeToken/engine state never leak (design
/// decision 1 in the Plan 2 header).
public actor CloudKitTransport: CloudSyncTransport {
    static let recordType = "WatchtowerRecord"

    private let store: TransportStore
    private let containerID: String
    private var container: CKContainer?
    private var engine: CKSyncEngine?
    private var delegateBox: DelegateBox?
    /// Last recorded failure (startup or store I/O), surfaced via availability().
    private var lastError: String?

    public init(store: TransportStore, containerID: String = WatchtowerCloud.containerID) {
        self.store = store
        self.containerID = containerID
    }

    // MARK: - CloudSyncTransport

    public func save(_ records: [CloudRecord]) async throws {
        try store.enqueueSave(records)
        nudgeEngine()
    }

    public func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try store.enqueueDelete(recordNames: recordNames, zone: zone)
        nudgeEngine()
    }

    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try store.changes(in: zone, since: token)
    }

    // MARK: - Lifecycle

    /// Builds the CKContainer/CKSyncEngine pair with the stored engine state
    /// and registers both zones as pending database changes. Failures are
    /// recorded and surfaced via availability() — never thrown, never fatal:
    /// unsigned dev builds routinely lack the iCloud entitlement and must
    /// degrade to store-only operation (records wait in the pending queue).
    public func start() async {
        guard engine == nil else { return }
        guard Self.hasCloudKitEntitlement() else {
            lastError = "missing iCloud entitlement (unsigned dev build?)"
            return
        }

        let container = CKContainer(identifier: containerID)
        self.container = container

        var stateSerialization: CKSyncEngine.State.Serialization?
        do {
            if let data = try store.loadEngineState() {
                stateSerialization = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            }
        } catch {
            // Unreadable state blob: start the engine fresh (it re-fetches
            // everything and re-emits a .stateUpdate) rather than failing.
            stateSerialization = nil
        }

        let box = DelegateBox()
        box.transport = self
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: box
        )
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        delegateBox = box

        engine.state.add(pendingDatabaseChanges: CloudZoneID.allCases.map {
            .saveZone(CKRecordZone(zoneName: $0.rawValue))
        })
        lastError = nil
        nudgeEngine()
    }

    /// Manual fetch — poll loops call this; push wake calls it implicitly
    /// when entitlements land. No-op while the engine is unavailable.
    public func pull() async throws {
        try await engine?.fetchChanges()
    }

    public func availability() async -> CloudAvailability {
        if let lastError { return .unavailable(lastError) }
        guard Self.hasCloudKitEntitlement() else {
            return .unavailable("missing iCloud entitlement (unsigned dev build?)")
        }
        let container = self.container ?? CKContainer(identifier: containerID)
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .unavailable("iCloud account status could not be determined")
            case .temporarilyUnavailable: return .unavailable("iCloud account temporarily unavailable")
            @unknown default: return .unavailable("unknown iCloud account status")
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Engine plumbing

    /// Schedules the store's pending rows on the engine so it calls
    /// nextRecordZoneChangeBatch. No-op while the engine is nil (CloudKit
    /// unavailable) — records simply wait in the store until start() succeeds.
    private func nudgeEngine() {
        guard let engine else { return }
        do {
            let pending = try store.pendingBatch(limit: 200)
            var changes: [CKSyncEngine.PendingRecordZoneChange] = pending.saves.map {
                .saveRecord(CKRecord.ID(recordName: $0.recordName, zoneID: Self.zoneID(for: $0.zone)))
            }
            changes += pending.deletes.map {
                .deleteRecord(CKRecord.ID(recordName: $0.name, zoneID: Self.zoneID(for: $0.zone)))
            }
            guard !changes.isEmpty else { return }
            engine.state.add(pendingRecordZoneChanges: changes)
        } catch {
            recordError(error)
        }
    }

    fileprivate func handleEngineEvent(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let stateUpdate):
            persistEngineState(stateUpdate.stateSerialization)
        case .fetchedRecordZoneChanges(let changes):
            bufferFetchedChanges(changes)
        case .sentRecordZoneChanges(let sent):
            clearSentChanges(sent)
        default:
            break
        }
    }

    fileprivate func nextEngineBatch() -> CKSyncEngine.RecordZoneChangeBatch? {
        do {
            let pending = try store.pendingBatch(limit: 200)
            guard !pending.saves.isEmpty || !pending.deletes.isEmpty else { return nil }
            let recordsToSave = pending.saves.map { Self.ckRecord(from: $0, in: Self.zoneID(for: $0.zone)) }
            let recordIDsToDelete = pending.deletes.map {
                CKRecord.ID(recordName: $0.name, zoneID: Self.zoneID(for: $0.zone))
            }
            return CKSyncEngine.RecordZoneChangeBatch(
                recordsToSave: recordsToSave,
                recordIDsToDelete: recordIDsToDelete,
                atomicByZone: false
            )
        } catch {
            recordError(error)
            return nil
        }
    }

    private func persistEngineState(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(serialization)
            try store.saveEngineState(data)
        } catch {
            recordError(error)
        }
    }

    private func bufferFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        let changed = event.modifications.compactMap { Self.cloudRecord(from: $0.record) }
        var deletedByZone: [CloudZoneID: [String]] = [:]
        for deletion in event.deletions {
            guard let zone = CloudZoneID(rawValue: deletion.recordID.zoneID.zoneName) else { continue }
            deletedByZone[zone, default: []].append(deletion.recordID.recordName)
        }
        do {
            try store.bufferChanged(changed)
            for (zone, names) in deletedByZone {
                try store.bufferDeleted(recordNames: names, zone: zone)
            }
        } catch {
            recordError(error)
        }
    }

    private func clearSentChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) {
        var saves: [(name: String, zone: CloudZoneID)] = []
        for record in event.savedRecords {
            guard let zone = CloudZoneID(rawValue: record.recordID.zoneID.zoneName) else { continue }
            saves.append((name: record.recordID.recordName, zone: zone))
        }
        var deletes: [(name: String, zone: CloudZoneID)] = []
        for recordID in event.deletedRecordIDs {
            guard let zone = CloudZoneID(rawValue: recordID.zoneID.zoneName) else { continue }
            deletes.append((name: recordID.recordName, zone: zone))
        }
        // Failed saves stay pending — the engine retries them. Failed deletes
        // for records the server never saw count as success under the seam's
        // idempotent-delete contract, so clear those too.
        for (recordID, error) in event.failedRecordDeletes where error.code == .unknownItem {
            guard let zone = CloudZoneID(rawValue: recordID.zoneID.zoneName) else { continue }
            deletes.append((name: recordID.recordName, zone: zone))
        }
        do {
            try store.clearPending(saves: saves, deletes: deletes)
        } catch {
            recordError(error)
        }
    }

    private func recordError(_ error: Error) {
        lastError = error.localizedDescription
    }

    private static func zoneID(for zone: CloudZoneID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
    }

    /// On macOS an unsigned dev build has no iCloud entitlement, and CloudKit
    /// raises an uncatchable ObjC exception when touched without one — so we
    /// probe the entitlement first and degrade instead. iOS builds always
    /// carry entitlements from the provisioning profile.
    private static func hasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
        #else
        return true
        #endif
    }

    // MARK: - Mapping (pure, unit-tested)

    static func ckRecord(from record: CloudRecord, in zoneID: CKRecordZone.ID) -> CKRecord {
        let id = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
        let ck = CKRecord(recordType: Self.recordType, recordID: id)
        ck.encryptedValues["payload"] = record.payload
        ck["kind"] = record.kind
        ck["modifiedAt"] = record.modifiedAt
        return ck
    }

    static func cloudRecord(from ck: CKRecord) -> CloudRecord? {
        guard let payload = ck.encryptedValues["payload"] as? Data,
              let zone = CloudZoneID(rawValue: ck.recordID.zoneID.zoneName) else { return nil }
        return CloudRecord(
            recordName: ck.recordID.recordName,
            zone: zone,
            kind: (ck["kind"] as? String) ?? "",
            modifiedAt: (ck["modifiedAt"] as? Date) ?? Date(timeIntervalSince1970: 0),
            payload: payload
        )
    }
}

/// Forwards CKSyncEngineDelegate callbacks into the actor. Held strongly by
/// the transport; holds the transport weakly, so no retain cycle regardless
/// of how CKSyncEngine.Configuration retains its delegate.
private final class DelegateBox: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    weak var transport: CloudKitTransport?

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await transport?.handleEngineEvent(event)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await transport?.nextEngineBatch()
    }
}
