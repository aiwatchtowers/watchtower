import CloudKit
import Foundation
import os

/// Result of probing the CloudKit account. `.unavailable` carries a
/// human-readable reason (missing entitlement, network, CK errors).
public enum CloudAvailability: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case unavailable(String)
}

/// What `removeLegacyZones` did with the single-hub build's fixed-name zones.
public enum LegacyZoneCleanup: String, Equatable, Sendable {
    case noneFound = "none_found"
    case deleted
    case kept
}

public enum HubZoneError: Error, Equatable {
    case notHub
    case noEntitlement
    case engineRunning
    /// The server step of `deleteHubZones` landed or may have landed (one
    /// zone is gone while the other's delete failed, or both are gone and
    /// the local store wipe did not land). Unlike a delete that removed
    /// nothing, this one has to be finished: the caller keeps its retry
    /// marker (multi-hub spec §3.3).
    case partlyDeleted
}

/// CloudKit adapter for the CloudSyncTransport seam, built on CKSyncEngine.
/// Push-shaped engine events land in the TransportStore buffer; the seam's
/// pull-shaped changes(since:) reads that buffer, so consumer tokens are
/// local seqs and CKServerChangeToken/engine state never leak (design
/// decision 1 in the Plan 2 header).
///
/// The same code runs on the Mac user's private database and on a
/// participant's shared database (`CloudDatabaseScope`, spec §2.3), always
/// on one hub's two zones (`HubZones`, multi-hub spec §4); only the hub
/// role writes zones (`TransportRole`). It handles the transport errors of spec §9: batch halving on
/// `.limitExceeded`, retry-after backoff on `.requestRateLimited` /
/// `.zoneBusy`, the quota pause, and "unlinked" when a share vanishes.
public actor CloudKitTransport: CloudSyncTransport, CompactingTransport, SweepingTransport {
    /// Every sealed record (mobile E2E spec §2.8: a new type, the hard cut). The pre-E2E type
    /// `WatchtowerRecord` is ignored on fetch (`cloudRecord(from:zone:)`).
    static let recordType = "WatchtowerEnvelope"
    /// A payload-free signal (`WireKind.signal`): the ask-alert subscription's trigger (D14).
    static let signalRecordType = "WatchtowerSignal"
    /// Record types already logged as ignored: one line per type, not one per record.
    static let ignoredTypesLogged = OSAllocatedUnfairLock(initialState: Set<String>())
    static let mappingLogger = Logger(subsystem: "WatchtowerKit", category: "CloudKitTransport")
    /// Records per send batch; `.limitExceeded` halves it (spec §9).
    static let maxBatchSize = 200
    /// Backoff when a throttle carries no `CKErrorRetryAfterKey` (spec §9).
    static let initialBackoff: TimeInterval = 5
    static let maxBackoff: TimeInterval = 120

    typealias EngineFactory = @Sendable (
        _ stateSerialization: CKSyncEngine.State.Serialization?,
        _ delegate: any CKSyncEngineDelegate
    ) -> any SyncEngineDriving

    let store: TransportStore
    let containerID: String
    /// The hub this transport syncs and its two zones, fixed for its lifetime.
    nonisolated public let zones: HubZones
    /// Which side of the link this transport plays (multi-hub spec §4.1).
    nonisolated public let role: TransportRole
    /// The database this transport syncs.
    nonisolated public var scope: CloudDatabaseScope { zones.scope }
    /// Only the hub creates, re-creates and deletes zones.
    var managesZones: Bool { role == .hub }
    let entitlementCheck: @Sendable () -> Bool
    let zoneAdmin: any CloudZoneAdministering
    let engineFactory: EngineFactory
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async -> Void
    /// Counts the CloudKit requests this transport issues (the phone's
    /// battery diagnostics); nil counts nothing.
    let energy: EnergyCounter?
    let logger = Logger(subsystem: "WatchtowerKit", category: "CloudKitTransport")

    var engine: (any SyncEngineDriving)?
    var delegateBox: DelegateBox?
    /// Last recorded failure (startup or store I/O), surfaced via availability().
    var lastError: String?
    /// Number of CloudKit account changes that forced a local reset. Read via
    /// `await transport.accountResetCount` (the hub surfaces it for diagnostics).
    public internal(set) var accountResetCount = 0
    /// Fired after an account-change reset so an owner (the desktop hub) can
    /// wipe its own derived state. Set before `start()` via `setAccountResetHandler`.
    var accountResetHandler: (@Sendable () -> Void)?
    /// Fired after a hub-role DataZone deletion (see
    /// `setDataZoneResetHandler`).
    var dataZoneResetHandler: (@Sendable () -> Void)?
    var eventHandler: (@Sendable (TransportEvent) -> Void)?
    var recordRejectedHandler: (@Sendable (_ recordName: String, _ zone: CloudZoneID) -> Void)?
    /// The relaunch an account-change reset schedules (awaitable in tests).
    var restartTask: Task<Void, Never>?
    /// Set by `stop()`, cleared only by the public `start()`: a reset's
    /// queued relaunch must not bring back an engine the owner stopped.
    var isStopped = false
    /// A batch the running engine fetched did not reach the buffer: the
    /// engine state is not saved until a full zone poll or the next engine
    /// start covers it (see `saveEngineState`).
    var engineBatchUnbuffered = false
    /// Engine batches that failed to buffer so far: a zone poll lifts
    /// `engineBatchUnbuffered` only when none failed while it ran.
    var engineBufferFailures = 0

    // Send-side error state (spec §9).
    var batchLimit = maxBatchSize
    /// The batch last handed to the engine: what a request-level
    /// `.limitExceeded` (which names no record) is about.
    var lastBuiltBatch: (id: Int, size: Int, saves: [(name: String, zone: CloudZoneID)])?
    var batchSerial = 0
    /// The batch a `.limitExceeded` was already applied to — the same
    /// failure can arrive thrown and per record; it shrinks once.
    var shrunkBatchID: Int?
    /// Start of the current throttling stretch; nil once a send succeeds.
    /// Settings shows "iCloud is slowing sync down" after 60 s of it.
    public internal(set) var throttledSince: Date?
    /// No sends and no fetches before this instant.
    var throttledUntil: Date?
    var nextBackoff = initialBackoff
    /// The wait-then-resend scheduled by the last throttle (awaitable in tests).
    var retryTask: Task<Void, Never>?
    /// True after `.quotaExceeded`: nothing is sent until `resume()`.
    public internal(set) var isPaused = false
    /// Phone role: the hub's zones are gone (`TransportEvent.unlinked`
    /// was emitted). Terminal for this transport's lifetime — nothing is
    /// sent, nudged or fetched any more, and neither an account-change reset
    /// nor anything else clears it. One transport serves one link: the phone
    /// builds a new transport (and store scope) when it links again.
    public internal(set) var isUnlinked = false
    /// An expired-token zone check + re-fetch is running (two concurrent
    /// pulls, or a pull and the event path, must not both run one).
    var refetchInFlight = false
    /// That re-fetch's `fetchChanges(scope:)` is awaiting the engine: a
    /// manual fetch, so its run events are not the engine's own (no
    /// `.engineFetchRun`, no `engineFetchedHandler`). Its fetch errors are
    /// not parked: the event path handles them as before.
    var refetchFetchInFlight = false
    /// The running pull, error handling included. A `pull()` arriving
    /// meanwhile joins it (awaits it, gets its outcome) instead of starting
    /// a second fetch, so the flag and parked events below belong to it.
    var pullTask: Task<Void, Error>?
    /// Pulls that joined a running one (observable in tests).
    var pullJoins = 0
    /// The running pull's `fetchChanges(scope:)` is awaiting the engine (cleared
    /// before its error handling). Fetch-error events delivered meanwhile
    /// are parked — every one: in the phone role one fetch covers every
    /// zone and fails once per zone — and handled by the pull, so one
    /// server failure is handled once.
    var manualFetchInFlight = false
    var parkedEventErrors: [(error: CKError, zoneID: CKRecordZone.ID)] = []
    /// The running `deleteHubZones` (server delete, then store wipe). It
    /// lives here, with the store it wipes, rather than on any one owner:
    /// `start()` and a second delete wait for it, so a late wipe never lands
    /// under an engine some other owner of this transport started.
    var hubZoneDelete: Task<Void, Error>?

    // The engine's own fetch runs (phone push path, board #724).
    /// Between the engine's own `willFetchChanges` and `didFetchChanges`
    /// (a run a manual fetch started is not tracked).
    var engineRunInFlight = false
    /// When the engine's current or last own fetch run began.
    var engineRunStartedAt: Date?
    /// `fetchForPush` callers waiting for an own run to begin: resumed with
    /// true when one begins, with false when their grace ends first, a
    /// `pull()` takes the push over or the engine goes.
    var engineRunStartWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// `fetchForPush` callers waiting for the running own run to end:
    /// resumed with true when it ends, with false when the wait's bound
    /// (`engineRunEndWait`) passes first, a `pull()` takes the push over or
    /// the engine goes.
    var engineRunEndWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Fired when an own fetch run of the engine ends (see
    /// `setEngineFetchedHandler`).
    var engineFetchedHandler: (@Sendable () -> Void)?
    /// The running `fetchForPush`; a second one joins it. A `pull()` waits
    /// for it only while it runs its own fallback fetch (one manual fetch
    /// at a time); while it still waits on the engine, the pull serves it.
    var pushFetchTask: Task<Void, Error>?
    /// The running push fetch has stopped waiting and runs its own fetch.
    var pushFetchFetching = false
    /// Push fetches that joined a running one (observable in tests).
    var pushFetchJoins = 0
    /// Push fetches an own engine run covered, so they sent no request of
    /// their own (observable in tests).
    var pushFetchesCoveredByEngine = 0
    /// Push fetches waiting on an own engine run (observable in tests).
    var engineRunWaiterCount: Int { engineRunStartWaiters.count + engineRunEndWaiters.count }

    public init(
        store: TransportStore,
        scope: CloudDatabaseScope,
        hubID: String,
        role: TransportRole,
        containerID: String = WatchtowerCloud.containerID,
        energy: EnergyCounter? = nil
    ) {
        precondition(role == .phone || scope == .private, "a hub syncs its own private database")
        let zones = HubZones(scope: scope, hubID: hubID)
        self.init(
            store: store,
            scope: scope,
            hubID: hubID,
            role: role,
            containerID: containerID,
            entitlementPresent: { CloudKitTransport.entitlementPresent(containerID: containerID) },
            zoneAdmin: CKDatabaseZoneAdmin(containerID: containerID, scope: scope),
            engineFactory: { state, delegate in
                CKSyncEngineDriver(containerID: containerID, zones: zones, stateSerialization: state, delegate: delegate)
            },
            now: { Date() },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
            energy: energy
        )
    }

    /// Test seam: a fake engine, a clock and a sleeper replace CloudKit.
    init(
        store: TransportStore,
        scope: CloudDatabaseScope,
        hubID: String,
        role: TransportRole,
        containerID: String = WatchtowerCloud.containerID,
        entitlementPresent: @escaping @Sendable () -> Bool,
        zoneAdmin: any CloudZoneAdministering,
        engineFactory: @escaping EngineFactory,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async -> Void,
        energy: EnergyCounter? = nil
    ) {
        self.store = store
        zones = HubZones(scope: scope, hubID: hubID)
        self.role = role
        self.containerID = containerID
        entitlementCheck = entitlementPresent
        self.zoneAdmin = zoneAdmin
        self.engineFactory = engineFactory
        self.now = now
        self.sleep = sleep
        self.energy = energy
    }

    /// In the phone role an account switch does NOT emit `.unlinked`: the
    /// transport wipes and relaunches on the new account's database with the
    /// same scope and hub. The phone decides (Task 12, spec §9) from
    /// this handler whether the old link still stands.
    public func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) {
        accountResetHandler = handler
    }

    /// Hub role: fired once per deletion batch that includes DataZone
    /// (`.encryptedDataReset`, the owner deleting iCloud data). Every
    /// published slice record is gone, so the owner (the desktop hub)
    /// forgets what it published and republishes into the recreated zone.
    /// Unlike an account reset the store is NOT wiped: the relay buffer and
    /// the owner's relay cursor still hold, and must not be rewound.
    /// The engine may report the same deletion more than once (a re-fetch, a
    /// relaunch before its state was persisted); each report fires again,
    /// which only costs a second wipe-and-republish — never wrong state.
    public func setDataZoneResetHandler(_ handler: (@Sendable () -> Void)?) {
        dataZoneResetHandler = handler
    }

    /// Phone role: fired after each of the engine's own fetch runs (the
    /// ones CKSyncEngine starts on a push) has buffered what it fetched, so
    /// the owner can apply it at once. Not fired for `pull()`,
    /// `fetchForPush`'s or an expired token's re-fetch. The hub sets none.
    public func setEngineFetchedHandler(_ handler: (@Sendable () -> Void)?) {
        engineFetchedHandler = handler
    }

    /// Receives `TransportEvent`s (unlinked, quota exceeded).
    public func setEventHandler(_ handler: (@Sendable (TransportEvent) -> Void)?) {
        eventHandler = handler
    }

    /// Called with a record CloudKit rejects even in a batch of one
    /// (`.limitExceeded`), or whose asset file is gone
    /// (`.assetFileNotFound`). The transport has dropped it from its send queue;
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
}

/// Forwards CKSyncEngineDelegate callbacks into the actor. Held strongly by
/// the transport; holds the transport weakly, so no retain cycle regardless
/// of how CKSyncEngine.Configuration retains its delegate.
final class DelegateBox: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    weak var transport: CloudKitTransport?
    let ownZoneIDs: [CKRecordZone.ID]

    init(ownZoneIDs: [CKRecordZone.ID]) {
        self.ownZoneIDs = ownZoneIDs
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await transport?.handleEngineEvent(event, from: self)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await transport?.nextEngineBatch()
    }

    /// The engine's own (push-driven) fetches read this hub's zones only
    /// (multi-hub spec §4.2): another hub's changes are never downloaded.
    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs(ownZoneIDs)
        return options
    }
}
