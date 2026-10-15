import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// A DataZone slice computed in Swift rather than by one SQL window (a
/// projection over several tables, CLI JSON, …). B and C add their kinds as
/// sources. `records` runs inside a read of the main DB and returns the
/// kind's whole current window: a record missing from it is deleted from
/// the zone.
protocol SliceSource: Sendable {
    var kind: SliceKind { get }
    func records(_ db: Database) throws -> [SliceRecord]
}

/// Pushes the DataZone slices to the cloud transport (mobile POC spec §3,
/// §4). Every DataZone save becomes a silent push to the phone, so the
/// cadences are what the phone's battery pays for (board #724, owner
/// decision Q3). One loop runs them all, so two sends never interleave:
/// - the full diff tick (30 s) over every kind: the only cycle that
///   publishes the normal kinds, so they cost at most one save batch per
///   30 s, sent when CKSyncEngine schedules it;
/// - the urgent kinds (`urgentKinds`: asks, ask alerts, link grants) are
///   also diffed every 10 s on their own (Go's writes, which no nudge
///   sees), and the fast lane: `nudge(kinds:)` keeps only urgent kinds,
///   coalesces them for 1 s, then diffs only them, with at least 2 s
///   between two fast sends. Any cycle that saved or deleted an urgent
///   record asks the transport to send at once (`sendNow`, spec §4.5);
///   the pending normal records go with that send.
/// - every cycle diffs the urgent kinds before the others, so a save
///   batch carries them first (the transport sends oldest first);
/// - without a linked phone only `device_grant` (the link flow's answer)
///   is published. The first cycle that sees a phone linked first diffs
///   the urgent kinds alone and sends them at once, so the new phone's
///   grant goes out ahead of the backlog, then diffs every kind; until
///   such a full cycle runs to its end, the next cycle does it again.
///
/// A poll, not ValueObservation: the Go daemon writes through its own
/// connection, so observation never fires. Rows are diffed against the
/// `HubSyncState` hashes so only changed records reach the transport.
///
/// Asset-backed records (`AssetSliceSource`): the asset is staged sealed in
/// the `SliceAssetStore` and rides as the record's CKAsset, its descriptor
/// inside the record's envelope; the hash covers the payload plus the
/// asset's plaintext digest. A record whose staged file is missing (the hub
/// was off, a reset) is published again even when its hash matches.
///
/// Mobile E2E (spec §2.4, §2.7): every record is sealed by the hub's
/// `SecureTransport` into a signed envelope under an opaque name, one record
/// at a time, so one record that cannot be sealed (a keybox without a
/// recipient key) is skipped alone, unhashed, and never blocks its batch. The
/// hashes stay of the plaintext (random nonces make every envelope differ),
/// and `slice_state.wire_name` keeps the opaque name each record went out
/// under (F19). Without hub keys (`transport` nil) nothing is published at
/// all, never in the clear.
final class SlicePublisher: Sendable {
    struct Timing: Equatable, Sendable {
        /// The full diff over every kind (the normal kinds' only cycle).
        let tick: Duration
        /// The diff over the urgent kinds alone.
        let urgentTick: Duration
        let fastWindow: Duration
        let fastSpacing: Duration

        /// `urgentTick` defaults to `tick` (one cadence).
        init(tick: Duration, urgentTick: Duration? = nil, fastWindow: Duration, fastSpacing: Duration) {
            self.tick = tick
            self.urgentTick = urgentTick ?? tick
            self.fastWindow = fastWindow
            self.fastSpacing = fastSpacing
        }

        static let standard = Self(tick: .seconds(30), urgentTick: .seconds(10), fastWindow: .seconds(1), fastSpacing: .seconds(2))
    }

    struct Outcome: Equatable {
        var pushed = 0
        var deleted = 0
        var skipped: [String] = []
        /// Records of `urgentKinds` saved or deleted (the immediate send).
        var urgentChanges = 0
        /// The cycle ran to its end (no mid-cycle account reset).
        var completed = false

        mutating func absorb(_ other: Self) {
            pushed += other.pushed
            deleted += other.deleted
            skipped += other.skipped
            urgentChanges += other.urgentChanges
        }
    }

    /// What the owner waits for at once (owner decision Q3): an ask, its
    /// alert, and a phone's link grant (the phone waits 60 s for it). Every
    /// other kind rides the 30 s full tick.
    static let urgentKinds: Set<SliceKind> = [.ownerAsk, .askAlert, .deviceGrant]

    /// The order a cycle diffs the kinds in: the urgent ones first.
    static let publishOrder: [SliceKind] =
        SliceKind.allCases.filter { urgentKinds.contains($0) } + SliceKind.allCases.filter { !urgentKinds.contains($0) }

    /// What is published while no phone is linked: the link flow's answer.
    static let unlinkedKinds: Set<SliceKind> = [.deviceGrant]

    /// One loop cycle: every kind, or the urgent kinds named.
    enum Cycle: Equatable {
        case full
        case urgent(Set<SliceKind>)
    }

    /// CloudKit's per-record cap is 1 MB. The 100 KB headroom covers system
    /// fields, `kind`/`modifiedAt` and record-name overhead, so the check runs
    /// against the sealed envelope alone (`isOversized`). A safety net that
    /// hides a record, never a projection rule (spec §8, I-8). F33: the one
    /// value is the Kit's.
    static let maxPayloadBytes = Envelope.maxBytes

    enum KeysError: Error, LocalizedError {
        /// No hub keys (no CloudKit entitlement): nothing is sealed, so nothing is sent.
        case unavailable

        var errorDescription: String? { "this Mac has no hub keys" }
    }

    /// The SQL-window slices. Empty in the POC: every published kind is a
    /// capped projection behind a `SliceSource` (spec §4: never `SELECT *`).
    static let sliceSQL: [SliceKind: String] = [:]

    struct Lane {
        /// Nudged urgent kinds.
        var pendingKinds: Set<SliceKind> = []
        var firstNudgeAt: ContinuousClock.Instant?
        var lastFastSendAt: ContinuousClock.Instant?
        /// The next full and urgent ticks; nil: due now (before the first).
        /// Taking a tick sets it from the take; the cycle's end resets it
        /// from the end, so a slow cycle never runs back to back.
        var nextTick: ContinuousClock.Instant?
        var nextUrgentTick: ContinuousClock.Instant?
        /// Which ticks the cycle being run took (reset by its end).
        var tookTick = false
        var tookUrgentTick = false
        /// The loop's current sleep; a nudge cancels it so the loop
        /// recomputes its deadline. Under the same lock as the nudge state,
        /// so a nudge can never land between "deadline computed" and
        /// "sleep stored".
        var sleep: Task<Void, Never>?
    }

    let dbPool: DatabasePool
    let state: HubSyncState
    /// The hub's sealing transport; nil without hub keys (nothing is published).
    let transport: SecureTransport?
    let sources: [any SliceSource]
    let timing: Timing
    /// The fast lane's clock; tests pass fabricated instants.
    let clock: @Sendable () -> ContinuousClock.Instant
    /// Wall-clock stamps (`lastPublishAt`), the hub's injected clock.
    let now: @Sendable () -> Date
    let logger = Logger(subsystem: Constants.bundleID, category: "SlicePublisher")
    let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    let lane = OSAllocatedUnfairLock(initialState: Lane())
    /// recordName → payload hash of the last oversized payload warned about:
    /// an unchanged stuck record warns once, a changed one warns again.
    let oversizedWarned = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    let warningCount = OSAllocatedUnfairLock(initialState: 0)
    /// The same throttle for records that could not be sealed.
    let sealWarned = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    let sealWarningCount = OSAllocatedUnfairLock(initialState: 0)
    let noKeysWarned = OSAllocatedUnfairLock(initialState: false)
    let lastPublish = OSAllocatedUnfairLock<Date?>(initialState: nil)
    /// The transport's immediate send (`HubTransport.sendNow`).
    let sendNow: @Sendable () async -> Void
    let fastCycles = OSAllocatedUnfairLock(initialState: 0)
    /// Where asset-backed records' files are staged; nil: such records are
    /// skipped (logged), never published without their asset.
    let assets: SliceAssetStore?
    /// Whether a phone is linked (`HubSyncState.hasLinkedDevice`).
    let isLinked: @Sendable () -> Bool
    /// A cycle saw no phone linked, and no full cycle has run to its end
    /// since one is (false before the first cycle).
    let unlinkedAtLastCycle = OSAllocatedUnfairLock(initialState: false)

    init(
        dbPool: DatabasePool,
        state: HubSyncState,
        transport: SecureTransport?,
        sources: [any SliceSource],
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        now: @escaping @Sendable () -> Date = { Date() },
        assets: SliceAssetStore? = nil,
        isLinked: @escaping @Sendable () -> Bool = { true },
        sendNow: @escaping @Sendable () async -> Void = {}
    ) {
        self.dbPool = dbPool
        self.state = state
        self.transport = transport
        self.sources = sources
        self.timing = timing
        self.clock = clock
        self.now = now
        self.sendNow = sendNow
        self.assets = assets
        self.isLinked = isLinked
    }

    /// Oversized warnings actually emitted (the throttle's observable).
    var oversizedWarnings: Int { warningCount.withLock { $0 } }

    /// Seal-failure warnings actually emitted (the throttle's observable).
    var sealWarnings: Int { sealWarningCount.withLock { $0 } }

    var isRunning: Bool { loopTask.withLock { $0 != nil } }

    /// The end of the last publish cycle that completed (the heartbeat's
    /// `last_publish_at`); nil before the first.
    var lastPublishAt: Date? { lastPublish.withLock { $0 } }

    /// Test seams: the loop's stored sleep handle and the loop task.
    var currentSleepForTesting: Task<Void, Never>? { lane.withLock { $0.sleep } }
    var loopTaskForTesting: Task<Void, Never>? { loopTask.withLock { $0 } }
    /// Urgent cycles (fast lane and urgent tick) that finished, the
    /// immediate send included (a test seam).
    var fastCyclesCompleted: Int { fastCycles.withLock { $0 } }

    // MARK: - Staged assets

    /// Removes every staged asset file; publishing goes on and restages
    /// them (the account-change reset).
    func removeStagedAssets() {
        assets?.removeAll()
    }

    /// Removes every staged asset file and stops staging until the next
    /// `start()` (the hub was turned off).
    func closeStagedAssets() {
        assets?.close()
    }

    // MARK: - Rejections and heartbeat

    /// CloudKit rejected this record even alone (spec §9), named by its wire
    /// name: map it back to the plain name (the transport's index, backed by
    /// `slice_state.wire_name`, F19) and forget that hash, so it is not
    /// believed published and the next cycle offers it again.
    func recordRejected(wireName: String) async {
        guard let transport else { return }
        guard let plain = await transport.plainName(forWire: wireName) else {
            logger.error("rejected record \(wireName, privacy: .public) maps to no published record; nothing cleared")
            return
        }
        do {
            try state.removeHashes([plain])
        } catch {
            logger.error("clearing the hash of rejected \(plain, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the hub's heartbeat (its fixed name `heartbeat`) sealed like
    /// every DataZone record; `KeysError.unavailable` without hub keys.
    func saveHeartbeat(_ record: CloudRecord) async throws {
        guard let transport else { throw KeysError.unavailable }
        try await transport.save([record])
    }
}
