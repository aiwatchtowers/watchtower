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
    private(set) var lastError: String?
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
    /// The batch last handed to the engine: what a request-level
    /// `.limitExceeded` (which names no record) is about.
    private var lastBuiltBatch: (id: Int, size: Int, saves: [(name: String, zone: CloudZoneID)])?
    private var batchSerial = 0
    /// The batch a `.limitExceeded` was already applied to — the same
    /// failure can arrive thrown and per record; it shrinks once.
    private var shrunkBatchID: Int?
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
    /// `shared` scope: the owner's zones are gone (`TransportEvent.unlinked`
    /// was emitted). Terminal for this transport's lifetime — nothing is
    /// sent, nudged or fetched any more, and neither an account-change reset
    /// nor anything else clears it. One transport serves one link: the phone
    /// builds a new transport (and store scope) when it links again.
    public private(set) var isUnlinked = false
    /// An expired-token zone check + re-fetch is running (two concurrent
    /// pulls, or a pull and the event path, must not both run one).
    private var refetchInFlight = false
    /// The running pull, error handling included. A `pull()` arriving
    /// meanwhile joins it (awaits it, gets its outcome) instead of starting
    /// a second fetch, so the flag and parked events below belong to it.
    private var pullTask: Task<Void, Error>?
    /// Pulls that joined a running one (observable in tests).
    private(set) var pullJoins = 0
    /// The running pull's `fetchChanges()` is awaiting the engine (cleared
    /// before its error handling). Fetch-error events delivered meanwhile
    /// are parked — every one: in `shared` scope one fetch covers every
    /// zone and fails once per zone — and handled by the pull, so one
    /// server failure is handled once.
    private var manualFetchInFlight = false
    private var parkedEventErrors: [(error: CKError, zoneID: CKRecordZone.ID)] = []

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

    /// In `shared` scope an account switch does NOT emit `.unlinked`: the
    /// transport wipes and relaunches on the new account's shared database
    /// with the same `ownerName`. The phone decides (Task 12, spec §9) from
    /// this handler whether the old link still stands.
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
    /// when entitlements land. No-op while the engine is unavailable, the
    /// server asked us to wait, or the link is gone. Fetch errors the
    /// transport can act on (unlinked, an expired token, throttling) are
    /// handled, not thrown. A successful fetch ends a throttling stretch.
    public func pull() async throws {
        if let pullTask {
            pullJoins += 1
            return try await pullTask.value
        }
        guard let engine, !isUnlinked else { return }
        if let throttledUntil, now() < throttledUntil { return }
        // Actor-isolated: the body runs after this job suspends below, so
        // `pullTask` is set before it can clear it.
        let task = Task {
            defer { self.pullTask = nil }
            try await self.performPull(engine: engine)
        }
        pullTask = task
        try await task.value
    }

    private func performPull(engine: any SyncEngineDriving) async throws {
        manualFetchInFlight = true
        parkedEventErrors = []
        do {
            try await fetchAndHandle(engine: engine)
        } catch where isUnlinked {
            // The link ended while this pull ran (the event path or the
            // handling unlinked): `.unlinked` already told the owner, so a
            // leftover zone error is not a new outage.
            return
        }
    }

    private func fetchAndHandle(engine: any SyncEngineDriving) async throws {
        var thrown: CKError?
        do {
            try await engine.fetchChanges()
        } catch let error as CKError {
            thrown = error
        } catch {
            manualFetchInFlight = false
            parkedEventErrors = []
            throw error
        }
        let parked = parkedEventErrors
        manualFetchInFlight = false
        parkedEventErrors = []
        if let thrown {
            // The thrown error supersedes the event copies of it, but keeps
            // their zones: a bare error is ours when nothing was parked or
            // any parked zone is ours, and otherwise is about a foreign zone.
            let zoneID = parked.isEmpty ? nil : (parked.first { ownsZone($0.zoneID) } ?? parked[0]).zoneID
            try await handleFetchError(thrown, zoneID: zoneID, engine: engine)
        } else if !parked.isEmpty {
            // The engine reported this fetch's failures as events only.
            let items = parked.flatMap { Self.flatten($0.error, zoneID: $0.zoneID) }
            try await handleFetchItems(items, original: parked[0].error, engine: engine)
        } else {
            clearThrottle()
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
        guard let engine, !isUnlinked else { return }
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
            // Parked right here while a pull's fetch is awaiting the engine:
            // the engine awaits this delivery inside that fetch, so the park
            // happens before `fetchChanges()` returns — no Task hop that
            // could lose the race with the pull's resume. Shared scope only
            // (private scope ignores event-path errors, as before scopes).
            if let error = fetched.error {
                if manualFetchInFlight, !scope.writesZones, !isUnlinked {
                    parkedEventErrors.append((error, fetched.zoneID))
                } else {
                    Task { await self.handleFetchEventError(error, zoneID: fetched.zoneID) }
                }
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

    /// Acts on a fetch error, `zoneID` being the zone it is about when
    /// known (the event path). Per-zone errors of a `.partialFailure` carry
    /// their own zone. Only this scope's zones count: in `shared` scope an
    /// error about another (stale) owner's zone never touches this link.
    /// - `shared`: `.zoneNotFound` / `.userDeletedZone` → unlinked.
    /// - Both scopes: an expired change token re-fetches once (unless, in
    ///   `shared` scope, a zone is gone: unlinked); throttling waits.
    /// - Anything else is rethrown (`shared`: unless it is only about other
    ///   owners' zones).
    func handleFetchError(_ error: CKError, zoneID: CKRecordZone.ID?, engine: any SyncEngineDriving) async throws {
        try await handleFetchItems(Self.flatten(error, zoneID: zoneID), original: error, engine: engine)
    }

    /// `handleFetchError` over already-flattened items (one server failure
    /// may arrive as several parked events); `original` is what is rethrown.
    private func handleFetchItems(
        _ items: [(zoneID: CKRecordZone.ID?, error: CKError)],
        original error: CKError,
        engine: any SyncEngineDriving
    ) async throws {
        let mine = items.filter { ownsZone($0.zoneID) }.map(\.error)
        if !scope.writesZones, mine.contains(where: { Self.zoneGoneCodes.contains($0.code) }) {
            emitUnlinked(reason: "zone not found on fetch")
            return
        }
        if mine.contains(where: { $0.code == .changeTokenExpired }) {
            try await refetchAfterExpiredToken(engine: engine)
            return
        }
        if applyThrottle(from: mine) { return }
        if !scope.writesZones, mine.isEmpty { return }
        throw error
    }

    /// The engine's report that fetching one zone failed. Private scope:
    /// ignored, exactly as before scopes (the engine retries its own
    /// automatic fetches; `pull()` handles manual ones). Shared scope: acts
    /// only on "zone gone" and an expired token for this owner's zones.
    /// While a `pull()` is awaiting the engine the error is parked for it.
    func handleFetchEventError(_ error: CKError, zoneID: CKRecordZone.ID) async {
        guard !scope.writesZones, let engine, !isUnlinked else { return }
        if manualFetchInFlight {
            parkedEventErrors.append((error, zoneID))
            return
        }
        let mine = Self.flatten(error, zoneID: zoneID).filter { ownsZone($0.zoneID) }.map(\.error)
        if mine.contains(where: { Self.zoneGoneCodes.contains($0.code) }) {
            emitUnlinked(reason: "zone not found on an engine fetch")
        } else if mine.contains(where: { $0.code == .changeTokenExpired }) {
            do {
                try await refetchAfterExpiredToken(engine: engine)
            } catch where !isUnlinked {
                recordError(error)
            } catch {
                // Unlinked meanwhile: the event already said so.
            }
        }
    }

    /// One zone check and re-fetch after `.changeTokenExpired`; a second
    /// failure surfaces to the caller. A throttle on the zone check waits
    /// like any throttle.
    private func refetchAfterExpiredToken(engine: any SyncEngineDriving) async throws {
        guard !refetchInFlight else { return }
        refetchInFlight = true
        defer { refetchInFlight = false }
        if !scope.writesZones {
            let exists: Bool
            do {
                exists = try await ownersZonesExist(engine: engine)
            } catch let error as CKError {
                if applyThrottle(from: Self.flatten(error, zoneID: nil).map(\.error)) { return }
                throw error
            }
            guard exists else {
                emitUnlinked(reason: "change token expired on a missing zone")
                return
            }
        }
        try await engine.fetchChanges()
        clearThrottle()
    }

    /// nil (no zone context) counts as ours: the error may be about any zone.
    private func ownsZone(_ zoneID: CKRecordZone.ID?) -> Bool {
        guard let zoneID else { return true }
        return scope.cloudZone(for: zoneID) != nil
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
        lastBuiltBatch = nil
        shrunkBatchID = nil
        accountResetCount += 1
        accountResetHandler?()
        // Relaunch with fresh state (loadEngineState is now empty). No-op on
        // unsigned dev builds — start() re-checks the entitlement and returns.
        restartTask = Task { await start() }
    }

    func nextEngineBatch() -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !isPaused, !isUnlinked else { return nil }
        if let throttledUntil, now() < throttledUntil { return nil }
        do {
            let pending = try store.pendingBatch(limit: batchLimit)
            guard !pending.saves.isEmpty || !pending.deletes.isEmpty else {
                // Queue drained: the next backlog starts at full size again.
                batchLimit = Self.maxBatchSize
                return nil
            }
            let recordsToSave = try pending.saves.map {
                Self.ckRecord(
                    from: $0,
                    in: scope.zoneID(for: $0.zone),
                    systemFields: try store.systemFields(recordName: $0.recordName, zone: $0.zone)
                )
            }
            batchSerial += 1
            lastBuiltBatch = (
                id: batchSerial,
                size: pending.saves.count + pending.deletes.count,
                saves: pending.saves.map { (name: $0.recordName, zone: $0.zone) }
            )
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
            let batchSize = saved.count + deleted.count + failedSaves.count + failedDeletes.count
            let tooLarge = failedSaves.filter { $0.error.code == .limitExceeded }.compactMap { failure in
                scope.cloudZone(for: failure.record.recordID.zoneID).map { (name: failure.record.recordID.recordName, zone: $0) }
            }
            if !tooLarge.isEmpty {
                try shrinkBatch(size: batchSize, rejectable: tooLarge)
            }
            lastError = nil
        } catch {
            recordError(error)
        }
    }

    /// An error from an engine send call itself rather than per record.
    func handleSendError(_ error: CKError) {
        let errors = Self.flatten(error, zoneID: nil).map(\.error)
        applySendFailures(errors)
        if errors.contains(where: { $0.code == .limitExceeded }) {
            // A request-level rejection names no record: it is about the
            // batch last handed out.
            if let batch = lastBuiltBatch {
                do {
                    try shrinkBatch(size: batch.size, rejectable: batch.saves)
                } catch {
                    recordError(error)
                }
            } else {
                batchLimit = max(1, batchLimit / 2)
            }
        }
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

    /// The per-item errors of a `.partialFailure`, each with its zone when
    /// the item key names one (a zone ID, or a record ID's zone), or the
    /// error itself with `zoneID`.
    private static func flatten(_ error: CKError, zoneID: CKRecordZone.ID?) -> [(zoneID: CKRecordZone.ID?, error: CKError)] {
        guard error.code == .partialFailure, let partial = error.partialErrorsByItemID else { return [(zoneID, error)] }
        let inner: [(zoneID: CKRecordZone.ID?, error: CKError)] = partial.compactMap { key, value in
            guard let itemError = value as? CKError else { return nil }
            let itemZone = (key as? CKRecordZone.ID) ?? (key as? CKRecord.ID)?.zoneID ?? zoneID
            return (itemZone, itemError)
        }
        return inner.isEmpty ? [(zoneID, error)] : inner
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

    /// `.limitExceeded` on a batch of `size`: halve the next batch and
    /// retry. A record that fails even alone (`rejectable`) is logged,
    /// dropped from the queue, and handed to the rejected-record handler,
    /// so it never retries forever. Applied once per built batch.
    private func shrinkBatch(size: Int, rejectable: [(name: String, zone: CloudZoneID)]) throws {
        if let id = lastBuiltBatch?.id {
            guard shrunkBatchID != id else { return }
            shrunkBatchID = id
        }
        guard size <= 1 else {
            batchLimit = max(1, size / 2)
            return
        }
        for (name, zone) in rejectable {
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
        guard !isPaused, !isUnlinked else { return }
        let pending: (saves: [CloudRecord], deletes: [(name: String, zone: CloudZoneID)])
        do {
            pending = try store.pendingBatch(limit: 1)
        } catch {
            recordError(error)
            return
        }
        guard !pending.saves.isEmpty || !pending.deletes.isEmpty else {
            // Nothing waits to be sent (a fetch-only throttle): the stretch
            // is over. The backoff stays until a request succeeds.
            throttledSince = nil
            return
        }
        await resend()
    }

    /// A request succeeded: the throttling stretch and its backoff end.
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
        guard !isUnlinked else { return }
        isUnlinked = true
        logger.notice("shared zones gone (\(reason, privacy: .public)); unlinked")
        eventHandler?(.unlinked)
    }

    /// Re-schedules the pending queue and asks the engine to send now.
    private func resend() async {
        guard let engine, !isUnlinked else { return }
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
