import CloudKit
import Foundation
import os
#if os(macOS)
import Security
#elseif targetEnvironment(simulator)
import MachO
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
///
/// The same code runs on the Mac user's private database and on a
/// participant's shared database (`CloudDatabaseScope`, spec §2.3), and
/// handles the transport errors of spec §9: batch halving on
/// `.limitExceeded`, retry-after backoff on `.requestRateLimited` /
/// `.zoneBusy`, the quota pause, and "unlinked" when a share vanishes.
public actor CloudKitTransport: CloudSyncTransport, CompactingTransport, SweepingTransport {
    static let recordType = "WatchtowerRecord"
    /// Records per send batch; `.limitExceeded` halves it (spec §9).
    static let maxBatchSize = 200
    /// Backoff when a throttle carries no `CKErrorRetryAfterKey` (spec §9).
    static let initialBackoff: TimeInterval = 5
    static let maxBackoff: TimeInterval = 120

    typealias EngineFactory = @Sendable (
        _ stateSerialization: CKSyncEngine.State.Serialization?,
        _ delegate: any CKSyncEngineDelegate
    ) -> any SyncEngineDriving

    private let store: TransportStore
    private let containerID: String
    /// The database this transport syncs, fixed for its lifetime.
    nonisolated public let scope: CloudDatabaseScope
    private let entitlementCheck: @Sendable () -> Bool
    private let engineFactory: EngineFactory
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let logger = Logger(subsystem: "WatchtowerKit", category: "CloudKitTransport")

    private var engine: (any SyncEngineDriving)?
    private var delegateBox: DelegateBox?
    /// Last recorded failure (startup or store I/O), surfaced via availability().
    private var lastError: String?
    /// Number of CloudKit account changes that forced a local reset. Read via
    /// `await transport.accountResetCount` (the hub surfaces it for diagnostics).
    public private(set) var accountResetCount = 0
    /// Fired after an account-change reset so an owner (the desktop hub) can
    /// wipe its own derived state. Set before `start()` via `setAccountResetHandler`.
    private var accountResetHandler: (@Sendable () -> Void)?
    private var eventHandler: (@Sendable (TransportEvent) -> Void)?
    private var recordRejectedHandler: (@Sendable (_ recordName: String, _ zone: CloudZoneID) -> Void)?
    /// The relaunch an account-change reset schedules (awaitable in tests).
    private(set) var restartTask: Task<Void, Never>?

    // Send-side error state (spec §9).
    private(set) var batchLimit = maxBatchSize
    /// Saves + deletes in the batch last handed to the engine.
    private var lastBatchSize = 0
    /// Start of the current throttling stretch; nil once a send succeeds.
    /// Settings shows "iCloud is slowing sync down" after 60 s of it.
    public private(set) var throttledSince: Date?
    /// No sends and no fetches before this instant.
    private var throttledUntil: Date?
    private var nextBackoff = initialBackoff
    /// The wait-then-resend scheduled by the last throttle (awaitable in tests).
    private(set) var retryTask: Task<Void, Never>?
    /// True after `.quotaExceeded`: nothing is sent until `resume()`.
    public private(set) var isPaused = false
    private var unlinkedEmitted = false

    public init(
        store: TransportStore,
        scope: CloudDatabaseScope = .private,
        containerID: String = WatchtowerCloud.containerID
    ) {
        self.init(
            store: store,
            scope: scope,
            containerID: containerID,
            entitlementPresent: { CloudKitTransport.entitlementPresent(containerID: containerID) },
            engineFactory: { state, delegate in
                CKSyncEngineDriver(containerID: containerID, scope: scope, stateSerialization: state, delegate: delegate)
            },
            now: { Date() },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        )
    }

    /// Test seam: a fake engine, a clock and a sleeper replace CloudKit.
    init(
        store: TransportStore,
        scope: CloudDatabaseScope,
        containerID: String = WatchtowerCloud.containerID,
        entitlementPresent: @escaping @Sendable () -> Bool,
        engineFactory: @escaping EngineFactory,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        self.store = store
        self.scope = scope
        self.containerID = containerID
        entitlementCheck = entitlementPresent
        self.engineFactory = engineFactory
        self.now = now
        self.sleep = sleep
    }

    public func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) {
        accountResetHandler = handler
    }

    /// Receives `TransportEvent`s (unlinked, quota exceeded).
    public func setEventHandler(_ handler: (@Sendable (TransportEvent) -> Void)?) {
        eventHandler = handler
    }

    /// Called with a record CloudKit rejects even in a batch of one
    /// (`.limitExceeded`). The transport has dropped it from its send queue;
    /// the hub clears the record's `slice_state` hash so it is not believed
    /// published (spec §9).
    public func setRecordRejectedHandler(_ handler: (@Sendable (_ recordName: String, _ zone: CloudZoneID) -> Void)?) {
        recordRejectedHandler = handler
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

    @discardableResult
    public func sweepEvents(in zone: CloudZoneID, olderThan cutoff: Date, upTo token: CloudChangeToken) async throws -> Int {
        try store.sweepEvents(in: zone, olderThan: cutoff, upTo: token)
    }

    // MARK: - Lifecycle

    /// Builds the CKSyncEngine on the scope's database with the stored
    /// engine state and, in `private` scope, registers both zones as pending
    /// database changes (a `shared` participant cannot create zones).
    /// Failures are recorded and surfaced via availability() — never thrown,
    /// never fatal: unsigned dev builds routinely lack the iCloud entitlement
    /// and must degrade to store-only operation (records wait in the pending
    /// queue).
    public func start() async {
        guard engine == nil else { return }
        guard entitlementCheck() else {
            lastError = "missing iCloud entitlement (unsigned dev build?)"
            return
        }
        do {
            if try store.adoptScope(scope) {
                logger.notice("transport store held another database scope's state; wiped it")
            }
        } catch {
            // The store's scope is unknown: starting could drive this
            // database with the other database's engine state.
            recordError(error)
            return
        }

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
        let engine = engineFactory(stateSerialization, box)
        self.engine = engine
        delegateBox = box

        if scope.writesZones {
            engine.add(pendingDatabaseChanges: CloudZoneID.allCases.map {
                .saveZone(CKRecordZone(zoneID: scope.zoneID(for: $0)))
            })
        }
        lastError = nil
        nudgeEngine()
    }

    /// Manual fetch — poll loops call this; push wake calls it implicitly
    /// when entitlements land. No-op while the engine is unavailable or the
    /// server asked us to wait. Fetch errors the transport can act on
    /// (unlinked, an expired token, throttling) are handled, not thrown.
    public func pull() async throws {
        guard let engine else { return }
        if let throttledUntil, now() < throttledUntil { return }
        do {
            try await engine.fetchChanges()
        } catch let error as CKError {
            try await handleFetchError(error, engine: engine)
        }
    }

    /// Lifts the quota pause (the owner freed iCloud space) and sends again.
    public func resume() async {
        guard isPaused else { return }
        isPaused = false
        await resend()
    }

    public func availability() async -> CloudAvailability {
        if let lastError { return .unavailable(lastError) }
        guard entitlementCheck() else {
            return .unavailable("missing iCloud entitlement (unsigned dev build?)")
        }
        do {
            switch try await CKContainer(identifier: containerID).accountStatus() {
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
            let pending = try store.pendingBatch(limit: Self.maxBatchSize)
            var changes: [CKSyncEngine.PendingRecordZoneChange] = pending.saves.map {
                .saveRecord(CKRecord.ID(recordName: $0.recordName, zoneID: scope.zoneID(for: $0.zone)))
            }
            changes += pending.deletes.map {
                .deleteRecord(CKRecord.ID(recordName: $0.name, zoneID: scope.zoneID(for: $0.zone)))
            }
            guard !changes.isEmpty else { return }
            engine.add(pendingRecordZoneChanges: changes)
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
            handleSentChanges(
                saved: sent.savedRecords,
                deleted: sent.deletedRecordIDs,
                failedSaves: sent.failedRecordSaves.map { ($0.record, $0.error) },
                failedDeletes: sent.failedRecordDeletes
            )
        case .fetchedDatabaseChanges(let changes):
            handleDeletedZones(changes.deletions.map(\.zoneID))
        case .didFetchRecordZoneChanges(let fetched):
            // Not awaited here: a re-fetch from inside the engine's own
            // event delivery would wait on the fetch that is delivering.
            if let error = fetched.error {
                Task { await self.handleFetchFailure(error) }
            }
        case .accountChange(let change):
            handleAccountChange(change.changeType)
        default:
            break
        }
    }

    /// A server-side zone deletion evicts that zone's buffered events and
    /// archived system fields. In `private` scope it then re-registers the
    /// zone so the surviving pending rows re-create it and re-send on the
    /// next batch. In `shared` scope the owner removed this participant or
    /// deleted the share: the phone is unlinked, and it must not (and
    /// cannot) re-create the owner's zone.
    func handleDeletedZones(_ zoneIDs: [CKRecordZone.ID]) {
        let deletedZones = zoneIDs.compactMap(scope.cloudZone(for:))
        guard !deletedZones.isEmpty else { return }
        do {
            for zone in deletedZones {
                try store.evictZone(zone)
                if scope.writesZones {
                    engine?.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: scope.zoneID(for: zone)))])
                }
            }
            lastError = nil
        } catch {
            recordError(error)
        }
        if scope.writesZones {
            nudgeEngine()
        } else {
            emitUnlinked(reason: "zone deleted")
        }
    }

    /// Acts on a fetch error. `shared` scope: `.zoneNotFound` (or the
    /// owner's zone deleted) means unlinked. Both scopes: an expired change
    /// token re-fetches once — unless, in `shared` scope, a zone is gone,
    /// which is unlinked too; throttling waits. Anything else is rethrown.
    func handleFetchError(_ error: CKError, engine: any SyncEngineDriving) async throws {
        let errors = Self.flatten(error)
        let codes = Set(errors.map(\.code))
        if !scope.writesZones, !codes.isDisjoint(with: Self.zoneGoneCodes) {
            emitUnlinked(reason: "zone not found on fetch")
            return
        }
        if codes.contains(.changeTokenExpired) {
            if !scope.writesZones, try await !ownersZonesExist(engine: engine) {
                emitUnlinked(reason: "change token expired on a missing zone")
                return
            }
            // One re-fetch; a second failure surfaces to the caller.
            try await engine.fetchChanges()
            return
        }
        if applyThrottle(from: errors) { return }
        throw error
    }

    private func handleFetchFailure(_ error: CKError) async {
        guard let engine else { return }
        do {
            try await handleFetchError(error, engine: engine)
        } catch {
            recordError(error)
        }
    }

    private func ownersZonesExist(engine: any SyncEngineDriving) async throws -> Bool {
        let existing = try await engine.existingZoneNames()
        return CloudZoneID.allCases.allSatisfy { existing.contains($0.rawValue) }
    }

    /// A CloudKit account sign-out or switch makes all local state belong to
    /// the wrong account: wipe and relaunch with fresh engine state. A plain
    /// sign-in has nothing local to discard (the reconcile fetch handles it).
    func handleAccountChange(_ changeType: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch changeType {
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
            delegateBox = nil
            return
        }
        engine = nil
        delegateBox = nil
        // The old account's throttle and quota say nothing about the new one.
        retryTask?.cancel()
        throttledSince = nil
        throttledUntil = nil
        nextBackoff = Self.initialBackoff
        isPaused = false
        batchLimit = Self.maxBatchSize
        accountResetCount += 1
        accountResetHandler?()
        // Relaunch with fresh state (loadEngineState is now empty). No-op on
        // unsigned dev builds — start() re-checks the entitlement and returns.
        restartTask = Task { await start() }
    }

    func nextEngineBatch() -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !isPaused else { return nil }
        if let throttledUntil, now() < throttledUntil { return nil }
        do {
            let pending = try store.pendingBatch(limit: batchLimit)
            guard !pending.saves.isEmpty || !pending.deletes.isEmpty else {
                // Queue drained: the next backlog starts at full size again.
                batchLimit = Self.maxBatchSize
                return nil
            }
            lastBatchSize = pending.saves.count + pending.deletes.count
            let recordsToSave = try pending.saves.map {
                Self.ckRecord(
                    from: $0,
                    in: scope.zoneID(for: $0.zone),
                    systemFields: try store.systemFields(recordName: $0.recordName, zone: $0.zone)
                )
            }
            let recordIDsToDelete = pending.deletes.map {
                CKRecord.ID(recordName: $0.name, zoneID: scope.zoneID(for: $0.zone))
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
        let modifications = event.modifications.filter { scope.cloudZone(for: $0.record.recordID.zoneID) != nil }
        let changed = modifications.compactMap { modification -> CloudRecord? in
            guard let record = Self.cloudRecord(from: modification.record) else { return nil }
            // CKAsset downloads land in a temporary staging area that may be
            // purged after this callback; the buffered event outlives it, so
            // stash a durable copy and point the event at that. A failed
            // stash keeps the temporary URL — best-effort, the consumer's
            // validation surfaces a vanished file as a failed ingest.
            guard let assetURL = record.assetFileURL,
                  let stashed = store.stashAsset(from: assetURL, recordName: record.recordName) else {
                return record
            }
            return CloudRecord(
                recordName: record.recordName,
                zone: record.zone,
                kind: record.kind,
                modifiedAt: record.modifiedAt,
                payload: record.payload,
                notifyLevel: record.notifyLevel,
                assetFileURL: stashed
            )
        }
        var deletedByZone: [CloudZoneID: [String]] = [:]
        for deletion in event.deletions {
            guard let zone = scope.cloudZone(for: deletion.recordID.zoneID) else { continue }
            deletedByZone[zone, default: []].append(deletion.recordID.recordName)
        }
        do {
            try store.bufferChanged(changed)
            // Persist the fetched records' system fields so a later local save
            // of the same recordName goes out with the server's change tag
            // (e.g. desktop status write-backs onto mobile-created records).
            for modification in modifications {
                guard let zone = scope.cloudZone(for: modification.record.recordID.zoneID) else { continue }
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

    /// The outcome of one sent batch: clears what landed, persists fresh
    /// system fields, and applies the spec §9 error rules to what failed.
    /// Internal (plain arrays, not the engine's event type) so it is
    /// exercisable without fabricating a CKSyncEngine event.
    func handleSentChanges(
        saved: [CKRecord],
        deleted: [CKRecord.ID],
        failedSaves: [(record: CKRecord, error: CKError)],
        failedDeletes: [CKRecord.ID: CKError]
    ) {
        var saves: [(name: String, zone: CloudZoneID, sentModifiedAt: Date)] = []
        var savedFields: [(name: String, zone: CloudZoneID, data: Data)] = []
        for record in saved {
            guard let zone = scope.cloudZone(for: record.recordID.zoneID) else { continue }
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
        for recordID in deleted {
            guard let zone = scope.cloudZone(for: recordID.zoneID) else { continue }
            deletes.append((name: recordID.recordName, zone: zone))
        }
        // Failed saves stay pending — the engine retries them. Failed deletes
        // for records the server never saw count as success under the seam's
        // idempotent-delete contract, so clear those too.
        for (recordID, error) in failedDeletes where error.code == .unknownItem {
            guard let zone = scope.cloudZone(for: recordID.zoneID) else { continue }
            deletes.append((name: recordID.recordName, zone: zone))
        }

        let failures = failedSaves.map(\.error) + Array(failedDeletes.values)
        applySendFailures(failures)
        let throttled = applyThrottle(from: failures)
        if !saved.isEmpty || !deleted.isEmpty, !throttled {
            clearThrottle()
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
            try fixSystemFieldsForFailedSaves(failedSaves)
            try shrinkBatch(after: failedSaves)
            lastError = nil
        } catch {
            recordError(error)
        }
    }

    /// An error from an engine send call itself rather than per record.
    func handleSendError(_ error: CKError) {
        let errors = Self.flatten(error)
        applySendFailures(errors)
        if !applyThrottle(from: errors), !errors.contains(where: { Self.handledSendCodes.contains($0.code) }) {
            recordError(error)
        }
    }

    /// Failed saves stay pending and the trailing re-nudge reschedules them,
    /// but two error codes need system-field surgery first or the retry fails
    /// identically forever.
    private func fixSystemFieldsForFailedSaves(_ failures: [(record: CKRecord, error: CKError)]) throws {
        for failure in failures {
            guard let zone = scope.cloudZone(for: failure.record.recordID.zoneID) else { continue }
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

    // MARK: - Error rules (spec §9)

    /// Codes that mean the owner's zone is gone for this participant.
    private static let zoneGoneCodes: Set<CKError.Code> = [.zoneNotFound, .userDeletedZone]
    private static let throttleCodes: Set<CKError.Code> = [.requestRateLimited, .zoneBusy]
    private static let handledSendCodes: Set<CKError.Code> = zoneGoneCodes.union([.quotaExceeded, .limitExceeded])

    /// The per-item errors of a `.partialFailure`, or the error itself.
    private static func flatten(_ error: CKError) -> [CKError] {
        guard error.code == .partialFailure, let partial = error.partialErrorsByItemID else { return [error] }
        let inner = partial.values.compactMap { $0 as? CKError }
        return inner.isEmpty ? [error] : inner
    }

    /// Unlinked (`shared` scope) and the quota pause.
    private func applySendFailures(_ errors: [CKError]) {
        let codes = Set(errors.map(\.code))
        if !scope.writesZones, !codes.isDisjoint(with: Self.zoneGoneCodes) {
            emitUnlinked(reason: "zone not found on send")
        }
        if codes.contains(.quotaExceeded) {
            pauseForQuota()
        }
    }

    /// `.limitExceeded`: halve the next batch and retry. A record that
    /// fails even alone is logged, dropped from the queue, and handed to
    /// the rejected-record handler, so it never retries forever.
    private func shrinkBatch(after failures: [(record: CKRecord, error: CKError)]) throws {
        let tooLarge = failures.filter { $0.error.code == .limitExceeded }
        guard !tooLarge.isEmpty else { return }
        guard lastBatchSize <= 1 else {
            batchLimit = max(1, lastBatchSize / 2)
            return
        }
        for failure in tooLarge {
            guard let zone = scope.cloudZone(for: failure.record.recordID.zoneID) else { continue }
            let name = failure.record.recordID.recordName
            try store.dropPending(recordName: name, zone: zone)
            logger.error("CloudKit rejected \(name, privacy: .public) even alone (limitExceeded); dropped it from the send queue")
            recordRejectedHandler?(name, zone)
        }
        batchLimit = Self.maxBatchSize
    }

    /// Throttles on `.requestRateLimited` / `.zoneBusy`, once for all of
    /// them. Returns whether it did.
    private func applyThrottle(from errors: [CKError]) -> Bool {
        let throttling = errors.filter { Self.throttleCodes.contains($0.code) }
        guard !throttling.isEmpty else { return false }
        throttle(retryAfter: throttling.compactMap(\.retryAfterSeconds).max())
        return true
    }

    /// Waits `retryAfter` (the server's `CKErrorRetryAfterKey`) or the
    /// default backoff — 5 s, doubling to a 120 s cap — then sends again.
    private func throttle(retryAfter: TimeInterval?) {
        let delay: TimeInterval
        if let retryAfter {
            delay = retryAfter
        } else {
            delay = nextBackoff
            nextBackoff = min(nextBackoff * 2, Self.maxBackoff)
        }
        let start = now()
        if throttledSince == nil { throttledSince = start }
        throttledUntil = start.addingTimeInterval(delay)
        logger.notice("CloudKit throttled sync; retrying in \(delay, privacy: .public) s")
        retryTask?.cancel()
        retryTask = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.throttleElapsed()
        }
    }

    private func throttleElapsed() async {
        throttledUntil = nil
        guard !isPaused else { return }
        await resend()
    }

    private func clearThrottle() {
        throttledSince = nil
        throttledUntil = nil
        nextBackoff = Self.initialBackoff
    }

    private func pauseForQuota() {
        guard !isPaused else { return }
        isPaused = true
        logger.error("iCloud quota exceeded; sync paused until resume()")
        eventHandler?(.quotaExceeded)
    }

    private func emitUnlinked(reason: String) {
        guard !unlinkedEmitted else { return }
        unlinkedEmitted = true
        logger.notice("shared zones gone (\(reason, privacy: .public)); unlinked")
        eventHandler?(.unlinked)
    }

    /// Re-schedules the pending queue and asks the engine to send now.
    private func resend() async {
        guard let engine else { return }
        nudgeEngine()
        do {
            try await engine.sendChanges()
        } catch let error as CKError {
            handleSendError(error)
        } catch {
            recordError(error)
        }
    }

    private func recordError(_ error: Error) {
        lastError = error.localizedDescription
    }

    /// Whether the RUNNING PROCESS is code-signed with the given iCloud
    /// container. Public because it is the composition-time transport switch
    /// (Plan 6 Decision 1): `AppEnvironment.init()` probes this to pick
    /// CloudKitTransport (entitled) vs InMemory+DemoSeed (unsigned sim/CI),
    /// and `start()`/`availability()` probe it to degrade instead of crash —
    /// CloudKit raises an uncatchable ObjC exception when touched without
    /// the entitlement. That exception fires specifically when the container
    /// ID is absent from `com.apple.developer.icloud-container-identifiers`,
    /// so we check that list rather than the presence of `icloud-services`.
    ///
    /// Per platform:
    /// - macOS: read the code-sign entitlements of the running process.
    /// - iOS simulator: signing embeds entitlements as the main executable's
    ///   `__TEXT,__entitlements` Mach-O section; `CODE_SIGNING_ALLOWED=NO`
    ///   builds (CI, `make mobile-test`/`mobile-run`) have no section and
    ///   probe false — the sim stays on the demo path.
    /// - iOS device: always true — an unsigned build cannot install on a
    ///   device, and entitlements come from the provisioning profile.
    public static func entitlementPresent(containerID: String = WatchtowerCloud.containerID) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        ) else { return false }
        guard let list = value as? [String] else { return false }
        return list.contains(containerID)
        #elseif targetEnvironment(simulator)
        guard let data = simulatorEntitlementsSection(),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entitlements = plist as? [String: Any],
              let list = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        else { return false }
        return list.contains(containerID)
        #else
        return true
        #endif
    }

    #if targetEnvironment(simulator)
    /// The main executable's `__TEXT,__entitlements` section (XML plist),
    /// present only when the simulator build was actually code-signed. Found
    /// by scanning loaded images for MH_EXECUTE rather than referencing
    /// `_mh_execute_header`, which does not link from a test bundle.
    private static func simulatorEntitlementsSection() -> Data? {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index),
                  header.pointee.filetype == UInt32(MH_EXECUTE),
                  // 64-bit magic before the mach_header_64 rebind — iOS 17
                  // sims are 64-bit-only, this makes the safety self-evident.
                  header.pointee.magic == MH_MAGIC_64 else { continue }
            var size: UInt = 0
            let bytes = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
                getsectiondata($0, "__TEXT", "__entitlements", &size)
            }
            guard let bytes, size > 0 else { return nil }
            return Data(bytes: bytes, count: Int(size))
        }
        return nil
    }
    #endif

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

    static func cloudRecord(from ck: CKRecord) -> CloudRecord? {
        guard let payload = ck.encryptedValues["payload"] as? Data,
              let zone = CloudZoneID(rawValue: ck.recordID.zoneID.zoneName) else { return nil }
        return CloudRecord(
            recordName: ck.recordID.recordName,
            zone: zone,
            kind: (ck["kind"] as? String) ?? "",
            modifiedAt: (ck["modifiedAt"] as? Date) ?? Date(timeIntervalSince1970: 0),
            payload: payload,
            notifyLevel: ck.encryptedValues["notifyLevel"] as? String,
            // CloudKit's staged download location — temporary; the buffering
            // path stashes a durable copy before persisting the event.
            assetFileURL: (ck["asset"] as? CKAsset)?.fileURL
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
