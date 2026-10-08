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
/// §4). One loop does both cadences, so two sends never interleave:
/// - the full diff tick (10 s) over every kind;
/// - the fast lane: `nudge(kinds:)` coalesces for 1 s, then diffs only the
///   nudged kinds, with at least 2 s between two fast sends.
///
/// A poll, not ValueObservation: the Go daemon writes through its own
/// connection, so observation never fires. Rows are diffed against the
/// `HubSyncState` hashes so only changed records reach the transport.
final class SlicePublisher: Sendable {
    struct Timing: Equatable, Sendable {
        let tick: Duration
        let fastWindow: Duration
        let fastSpacing: Duration

        static let standard = Self(tick: .seconds(10), fastWindow: .seconds(1), fastSpacing: .seconds(2))
    }

    struct Outcome: Equatable {
        var pushed = 0
        var deleted = 0
        var skipped: [String] = []
    }

    /// CloudKit's per-record cap is 1 MB. The 100 KB headroom covers system
    /// fields, `kind`/`modifiedAt`/`notifyLevel` and record-name overhead, so
    /// the check runs against the encoded payload alone. A safety net that
    /// hides a record, never a projection rule (spec §8, I-8).
    static let maxPayloadBytes = 900_000

    /// The SQL-window slices. Empty in the POC: every published kind is a
    /// capped projection behind a `SliceSource` (spec §4: never `SELECT *`).
    static let sliceSQL: [SliceKind: String] = [:]

    private struct Lane {
        var pendingKinds: Set<SliceKind> = []
        var firstNudgeAt: ContinuousClock.Instant?
        var lastFastSendAt: ContinuousClock.Instant?
        /// The loop's current sleep; a nudge cancels it so the loop
        /// recomputes its deadline. Under the same lock as the nudge state,
        /// so a nudge can never land between "deadline computed" and
        /// "sleep stored".
        var sleep: Task<Void, Never>?
    }

    private let dbPool: DatabasePool
    private let state: HubSyncState
    private let transport: any CloudSyncTransport & Sendable
    private let sources: [any SliceSource]
    private let timing: Timing
    /// The fast lane's clock; tests pass fabricated instants.
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let logger = Logger(subsystem: Constants.bundleID, category: "SlicePublisher")
    private let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let lane = OSAllocatedUnfairLock(initialState: Lane())
    /// recordName → payload hash of the last oversized payload warned about:
    /// an unchanged stuck record warns once, a changed one warns again.
    private let oversizedWarned = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private let warningCount = OSAllocatedUnfairLock(initialState: 0)

    init(
        dbPool: DatabasePool,
        state: HubSyncState,
        transport: any CloudSyncTransport & Sendable,
        sources: [any SliceSource],
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.dbPool = dbPool
        self.state = state
        self.transport = transport
        self.sources = sources
        self.timing = timing
        self.clock = clock
    }

    /// Oversized warnings actually emitted (the throttle's observable).
    var oversizedWarnings: Int { warningCount.withLock { $0 } }

    var isRunning: Bool { loopTask.withLock { $0 != nil } }

    // MARK: - Publishing

    /// One push cycle over `kinds` (nil: every kind). Oversized records are
    /// skipped WITHOUT recording their hash, so a later smaller version
    /// publishes normally.
    @discardableResult
    func publishOnce(kinds: Set<SliceKind>? = nil) async throws -> Outcome {
        var outcome = Outcome()
        let startGen = try state.generation()
        for kind in SliceKind.allCases where kinds?.contains(kind) ?? true {
            guard let diff = try currentDiff(for: kind) else { continue }
            let saveable = splitOversized(diff.upserts, skipped: &outcome.skipped)
            outcome.skipped.append(contentsOf: diff.skipped)
            guard try await pushKind(saveable, deletions: diff.deletions, startGen: startGen, into: &outcome) else {
                logger.warning("publish: generation changed mid-cycle; aborted to avoid recording stale hashes")
                return outcome
            }
        }
        return outcome
    }

    /// nil when the kind has neither a SQL window nor a source.
    private func currentDiff(for kind: SliceKind) throws -> SliceDiff.Result? {
        let known = try state.hashes(forKind: kind)
        if let sql = Self.sliceSQL[kind] {
            let rows = try fetchRows(sql: sql).map { (id: Self.rowID($0), row: $0) }
            return SliceDiff.compute(kind: kind, rows: rows, knownHashes: known, now: Date())
        }
        let kindSources = sources.filter { $0.kind == kind }
        guard !kindSources.isEmpty else { return nil }
        let records = try fetchRecords(kindSources)
        return SliceDiff.compute(kind: kind, records: records, knownHashes: known)
    }

    /// Saves and deletes one kind's changes and records the new hashes.
    /// False when an account reset landed mid-cycle (nothing recorded).
    private func pushKind(
        _ saveable: [SliceRecord],
        deletions: [String],
        startGen: Int,
        into outcome: inout Outcome
    ) async throws -> Bool {
        if !saveable.isEmpty {
            try await transport.save(saveable.map { CloudRecordFactory.record(for: $0) })
            guard try state.generation() == startGen else { return false }
            for record in saveable {
                try state.setHash(SliceDiff.hashHex(record.payload), for: record.recordName)
                oversizedWarned.withLock { _ = $0.removeValue(forKey: record.recordName) }
            }
            outcome.pushed += saveable.count
        }
        if !deletions.isEmpty {
            try await transport.delete(recordNames: deletions, in: .data)
            guard try state.generation() == startGen else { return false }
            try state.removeHashes(deletions)
            outcome.deleted += deletions.count
        }
        return true
    }

    private func splitOversized(_ upserts: [SliceRecord], skipped: inout [String]) -> [SliceRecord] {
        upserts.filter { record in
            guard Self.isOversized(record.payload) else { return true }
            skipped.append(record.recordName)
            warnOversizedIfNeeded(record)
            return false
        }
    }

    /// True when `payload` exceeds the publishable budget; exactly
    /// `maxPayloadBytes` still fits.
    static func isOversized(_ payload: Data) -> Bool {
        payload.count > maxPayloadBytes
    }

    private func warnOversizedIfNeeded(_ record: SliceRecord) {
        let hash = SliceDiff.hashHex(record.payload)
        let firstSighting = oversizedWarned.withLock { warned in
            guard warned[record.recordName] != hash else { return false }
            warned[record.recordName] = hash
            return true
        }
        guard firstSighting else { return }
        warningCount.withLock { $0 += 1 }
        logger.warning("""
            oversized slice record skipped: \(record.recordName, privacy: .public) \
            payload \(record.payload.count) bytes exceeds \(Self.maxPayloadBytes); \
            not published, retried when it shrinks
            """)
    }

    /// CloudKit rejected this record even alone (spec §9): forget its hash
    /// so it is not believed published and the next cycle offers it again.
    func recordRejected(_ recordName: String) {
        do {
            try state.removeHashes([recordName])
        } catch {
            logger.error("clearing the hash of rejected \(recordName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Synchronous on purpose: GRDB's async `read` requires `T: Sendable`,
    /// and neither `Row` nor `SliceRecord` is; only the sync overload exists
    /// in a non-async function.
    private func fetchRows(sql: String) throws -> [Row] {
        try dbPool.read { db in try Row.fetchAll(db, sql: sql) }
    }

    private func fetchRecords(_ kindSources: [any SliceSource]) throws -> [SliceRecord] {
        try dbPool.read { db in try kindSources.flatMap { try $0.records(db) } }
    }

    // MARK: - Fast lane

    /// Asks for `kinds` to be published soon: after the 1 s coalescing
    /// window, and at least 2 s after the previous fast send.
    func nudge(kinds: Set<SliceKind>) {
        guard !kinds.isEmpty else { return }
        lane.withLock { lane in
            if lane.pendingKinds.isEmpty { lane.firstNudgeAt = clock() }
            lane.pendingKinds.formUnion(kinds)
            lane.sleep?.cancel()
        }
    }

    /// When the pending nudges may be sent: the end of the 1 s window, but
    /// no sooner than 2 s after the previous fast send. nil with nothing
    /// pending.
    var fastDeadline: ContinuousClock.Instant? {
        lane.withLock { [timing] in Self.fastDeadline($0, timing: timing) }
    }

    private static func fastDeadline(_ lane: Lane, timing: Timing) -> ContinuousClock.Instant? {
        guard !lane.pendingKinds.isEmpty, let first = lane.firstNudgeAt else { return nil }
        let windowEnd = first + timing.fastWindow
        guard let last = lane.lastFastSendAt else { return windowEnd }
        return max(windowEnd, last + timing.fastSpacing)
    }

    /// The nudged kinds when their deadline has passed (taken, and the send
    /// stamped now); nil otherwise.
    func takeDueFastKinds(now: ContinuousClock.Instant) -> Set<SliceKind>? {
        lane.withLock { [timing] lane in
            guard let deadline = Self.fastDeadline(lane, timing: timing), now >= deadline else { return nil }
            let kinds = lane.pendingKinds
            lane.pendingKinds = []
            lane.firstNudgeAt = nil
            lane.lastFastSendAt = now
            return kinds
        }
    }

    private func sleepUntilNextDeadline(tick: ContinuousClock.Instant) async {
        let sleep = lane.withLock { [timing] lane in
            let deadline = Self.fastDeadline(lane, timing: timing).map { min($0, tick) } ?? tick
            let task = Task<Void, Never> { _ = try? await Task.sleep(until: deadline, clock: .continuous) }
            lane.sleep = task
            return task
        }
        // stop() may have cancelled the loop before this sleep existed.
        if Task.isCancelled { sleep.cancel() }
        await sleep.value
        // Only our own handle: a restarted loop may have stored its own.
        lane.withLock { lane in
            if lane.sleep == sleep { lane.sleep = nil }
        }
    }

    // MARK: - Loop

    /// Starts the loop; the first full cycle runs at once.
    func start() {
        let task = Task { [weak self] in
            var nextTick = self?.clock() ?? .now
            while !Task.isCancelled {
                guard let self else { return }
                let now = self.clock()
                if now >= nextTick {
                    await self.runCycle(kinds: nil)
                    nextTick = self.clock() + self.timing.tick
                } else if let kinds = self.takeDueFastKinds(now: now) {
                    await self.runCycle(kinds: kinds)
                } else {
                    await self.sleepUntilNextDeadline(tick: nextTick)
                }
            }
        }
        loopTask.withLock { current in
            current?.cancel()
            current = task
        }
        // A start() without stop(): the old loop's sleep must not outlive it.
        lane.withLock { $0.sleep?.cancel() }
    }

    private func runCycle(kinds: Set<SliceKind>?) async {
        do {
            let outcome = try await publishOnce(kinds: kinds)
            if !outcome.skipped.isEmpty {
                logger.debug("publish cycle skipped \(outcome.skipped.count) records")
            }
        } catch {
            logger.error("publish cycle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        loopTask.withLock { current in
            current?.cancel()
            current = nil
        }
        // The sleep sub-task does not observe the loop's cancellation.
        lane.withLock { $0.sleep?.cancel() }
    }

    // MARK: - Helpers

    /// Slice ids are INTEGER for most tables but TEXT for some, so read the
    /// raw storage instead of forcing an Int64 conversion.
    private static func rowID(_ row: Row) -> String {
        let dbValue: DatabaseValue = row["id"] ?? .null
        switch dbValue.storage {
        case .int64(let value): return String(value)
        case .string(let value): return value
        default: return "0"
        }
    }
}
