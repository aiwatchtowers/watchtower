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
public actor CloudKitTransport: CloudSyncTransport, CompactingTransport {
    static let recordType = "WatchtowerRecord"

    private let store: TransportStore
    private let containerID: String
    private var container: CKContainer?
    private var engine: CKSyncEngine?
    private var delegateBox: DelegateBox?
    /// Last recorded failure (startup or store I/O), surfaced via availability().
    private var lastError: String?
    /// Number of CloudKit account changes that forced a local reset. Read via
    /// `await transport.accountResetCount` (the hub surfaces it for diagnostics).
    public private(set) var accountResetCount = 0
    /// Fired after an account-change reset so an owner (the desktop hub) can
    /// wipe its own derived state. Set before `start()` via `setAccountResetHandler`.
    private var accountResetHandler: (@Sendable () -> Void)?

    public init(store: TransportStore, containerID: String = WatchtowerCloud.containerID) {
        self.store = store
        self.containerID = containerID
    }

    public func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) {
        accountResetHandler = handler
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

    public func compact(in zone: CloudZoneID, keepSince token: CloudChangeToken) async throws {
        try store.compactEvents(in: zone, keepSince: token)
    }

    // MARK: - Lifecycle

    /// Builds the CKContainer/CKSyncEngine pair with the stored engine state
    /// and registers both zones as pending database changes. Failures are
    /// recorded and surfaced via availability() — never thrown, never fatal:
    /// unsigned dev builds routinely lack the iCloud entitlement and must
    /// degrade to store-only operation (records wait in the pending queue).
    public func start() async {
        guard engine == nil else { return }
        guard Self.hasCloudKitEntitlement(containerID: containerID) else {
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
        guard Self.hasCloudKitEntitlement(containerID: containerID) else {
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
        case .fetchedDatabaseChanges(let changes):
            handleFetchedDatabaseChanges(changes)
        case .accountChange(let change):
            handleAccountChange(change)
        default:
            break
        }
    }

    /// A server-side zone deletion evicts that zone's buffered events and
    /// archived system fields, then re-registers the zone so the surviving
    /// pending rows re-create it and re-send on the next batch.
    private func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        let deletedZones = event.deletions.compactMap { CloudZoneID(rawValue: $0.zoneID.zoneName) }
        guard !deletedZones.isEmpty else { return }
        do {
            for zone in deletedZones {
                try store.evictZone(zone)
                engine?.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneName: zone.rawValue))
                ])
            }
            lastError = nil
            nudgeEngine()
        } catch {
            recordError(error)
        }
    }

    /// A CloudKit account sign-out or switch makes all local state belong to
    /// the wrong account: wipe and relaunch with fresh engine state. A plain
    /// sign-in has nothing local to discard (the reconcile fetch handles it).
    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        switch event.changeType {
        case .signIn:
            return
        case .signOut, .switchAccounts:
            resetForAccountChange()
        @unknown default:
            resetForAccountChange()
        }
    }

    /// Wipes the store, drops the engine, and relaunches it fresh, recording
    /// the reset and notifying the owner. Internal so it is exercisable
    /// without fabricating a CKSyncEngine account event.
    func resetForAccountChange() {
        do {
            try store.wipe()
        } catch {
            // Wipe failed: the store may contain stale old-account state.
            // Drop the engine so the transport is inert (.unavailable via lastError)
            // until the operator restarts — relaunching against a partially-wiped
            // store would reload old-account engine state/system_fields into the
            // new account context, and clearing lastError would make availability()
            // lie. The reset handler is intentionally NOT fired: the hub must not
            // wipe its own derived state when the transport's store is in an
            // unknown state.
            recordError(error)
            engine = nil
            container = nil
            delegateBox = nil
            return
        }
        engine = nil
        container = nil
        delegateBox = nil
        accountResetCount += 1
        accountResetHandler?()
        // Relaunch with fresh state (loadEngineState is now empty). No-op on
        // unsigned dev builds — start() re-checks the entitlement and returns.
        Task { await start() }
    }

    fileprivate func nextEngineBatch() -> CKSyncEngine.RecordZoneChangeBatch? {
        do {
            let pending = try store.pendingBatch(limit: 200)
            guard !pending.saves.isEmpty || !pending.deletes.isEmpty else { return nil }
            let recordsToSave = try pending.saves.map {
                Self.ckRecord(
                    from: $0,
                    in: Self.zoneID(for: $0.zone),
                    systemFields: try store.systemFields(recordName: $0.recordName, zone: $0.zone)
                )
            }
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
            lastError = nil
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
            // Persist the fetched records' system fields so a later local save
            // of the same recordName goes out with the server's change tag
            // (e.g. desktop status write-backs onto mobile-created records).
            for modification in event.modifications {
                guard let zone = CloudZoneID(rawValue: modification.record.recordID.zoneID.zoneName) else { continue }
                try store.saveSystemFields(
                    Self.archivedSystemFields(of: modification.record),
                    recordName: modification.record.recordID.recordName,
                    zone: zone
                )
            }
            for (zone, names) in deletedByZone {
                try store.bufferDeleted(recordNames: names, zone: zone)
                try store.deleteSystemFields(recordNames: names, zone: zone)
            }
            lastError = nil
        } catch {
            recordError(error)
        }
    }

    private func clearSentChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) {
        var saves: [(name: String, zone: CloudZoneID, sentModifiedAt: Date)] = []
        var savedFields: [(name: String, zone: CloudZoneID, data: Data)] = []
        for record in event.savedRecords {
            guard let zone = CloudZoneID(rawValue: record.recordID.zoneID.zoneName) else { continue }
            // Use the record's own modifiedAt as the stamp so that a newer
            // local re-enqueue (modified_at > stamp) is not silently lost.
            // Missing field → .distantFuture → clears unconditionally (old behaviour).
            let stamp = (record["modifiedAt"] as? Date) ?? .distantFuture
            saves.append((name: record.recordID.recordName, zone: zone, sentModifiedAt: stamp))
            // The saved record carries the fresh server change tag — persist it
            // so the NEXT save of this record (heartbeat re-save, status flip)
            // doesn't hit .serverRecordChanged.
            savedFields.append((
                name: record.recordID.recordName,
                zone: zone,
                data: Self.archivedSystemFields(of: record)
            ))
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
        // re-nudge: pendingBatch is capped at 200; without this a large offline
        // backlog stalls — and it is also what reschedules the still-pending
        // failed saves with their corrected system fields. Deferred so a store
        // error mid-block cannot skip the reschedule (Task 1 review Minor 1).
        defer { nudgeEngine() }
        do {
            try store.clearPending(saves: saves, deletes: deletes)
            for entry in savedFields {
                try store.saveSystemFields(entry.data, recordName: entry.name, zone: entry.zone)
            }
            for entry in deletes {
                try store.deleteSystemFields(recordNames: [entry.name], zone: entry.zone)
            }
            try fixSystemFieldsForFailedSaves(event.failedRecordSaves)
            lastError = nil
        } catch {
            recordError(error)
        }
    }

    /// Failed saves stay pending and the trailing re-nudge reschedules them,
    /// but two error codes need system-field surgery first or the retry fails
    /// identically forever.
    private func fixSystemFieldsForFailedSaves(
        _ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave]
    ) throws {
        for failure in failures {
            guard let zone = CloudZoneID(rawValue: failure.record.recordID.zoneID.zoneName) else { continue }
            let name = failure.record.recordID.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                // Conflict policy: this device's payload wins — desktop is the
                // source of truth for DataZone, and for RelayZone the
                // write-back/chunk author wins by protocol design. Persist the
                // SERVER record's system fields (userInfo's
                // CKRecordChangedErrorServerRecordKey, surfaced as
                // CKError.serverRecord) so the retry carries the server change
                // tag and succeeds instead of looping.
                if let server = failure.error.serverRecord {
                    try store.saveSystemFields(
                        Self.archivedSystemFields(of: server),
                        recordName: name,
                        zone: zone
                    )
                }
            case .unknownItem:
                // The server-side record vanished while we held its change tag
                // (deleted by another device). Drop the stale system fields so
                // the retry goes out as a fresh record instead of wedging on a
                // tag the server no longer knows.
                try store.deleteSystemFields(recordNames: [name], zone: zone)
            default:
                break
            }
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
    /// probe the entitlement first and degrade instead. The uncatchable
    /// exception fires specifically when the container ID is absent from
    /// `com.apple.developer.icloud-container-identifiers`, so we check that
    /// list rather than the presence of `icloud-services`.
    /// iOS builds always carry entitlements from the provisioning profile.
    private static func hasCloudKitEntitlement(containerID: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        ) else { return false }
        guard let list = value as? [String] else { return false }
        return list.contains(containerID)
        #else
        return true
        #endif
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
            ck = CKRecord(recordType: Self.recordType, recordID: id)
        }
        ck.encryptedValues["payload"] = record.payload
        ck["kind"] = record.kind
        ck["modifiedAt"] = record.modifiedAt
        return ck
    }

    /// Archives identity + server metadata (change tag) without payload fields.
    static func archivedSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
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
