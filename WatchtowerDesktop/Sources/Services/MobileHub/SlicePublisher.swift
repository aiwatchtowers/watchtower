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
///   nudged kinds, with at least 2 s between two fast sends. A fast cycle
///   that saved or deleted something then asks the transport to send at
///   once (`sendNow`, spec §4.5); the tick leaves that to CKSyncEngine.
///
/// A poll, not ValueObservation: the Go daemon writes through its own
/// connection, so observation never fires. Rows are diffed against the
/// `HubSyncState` hashes so only changed records reach the transport.
///
/// Asset-backed records (`AssetSliceSource`): the asset is staged in the
/// `SliceAssetStore` and rides as the record's CKAsset; the hash covers the
/// payload plus the asset's content. A record whose staged file is missing
/// (the hub was off, a reset) is published again even when its hash matches.
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
    /// Wall-clock stamps (`lastPublishAt`), the hub's injected clock.
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: Constants.bundleID, category: "SlicePublisher")
    private let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let lane = OSAllocatedUnfairLock(initialState: Lane())
    /// recordName → payload hash of the last oversized payload warned about:
    /// an unchanged stuck record warns once, a changed one warns again.
    private let oversizedWarned = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private let warningCount = OSAllocatedUnfairLock(initialState: 0)
    private let lastPublish = OSAllocatedUnfairLock<Date?>(initialState: nil)
    /// The transport's immediate send (`HubTransport.sendNow`).
    private let sendNow: @Sendable () async -> Void
    private let fastCycles = OSAllocatedUnfairLock(initialState: 0)
    /// Where asset-backed records' files are staged; nil: such records are
    /// skipped (logged), never published without their asset.
    private let assets: SliceAssetStore?

    init(
        dbPool: DatabasePool,
        state: HubSyncState,
        transport: any CloudSyncTransport & Sendable,
        sources: [any SliceSource],
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        now: @escaping @Sendable () -> Date = { Date() },
        assets: SliceAssetStore? = nil,
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
    }

    /// Oversized warnings actually emitted (the throttle's observable).
    var oversizedWarnings: Int { warningCount.withLock { $0 } }

    var isRunning: Bool { loopTask.withLock { $0 != nil } }

    /// The end of the last publish cycle that completed (the heartbeat's
    /// `last_publish_at`); nil before the first.
    var lastPublishAt: Date? { lastPublish.withLock { $0 } }

    /// Test seams: the loop's stored sleep handle and the loop task.
    var currentSleepForTesting: Task<Void, Never>? { lane.withLock { $0.sleep } }
    var loopTaskForTesting: Task<Void, Never>? { loopTask.withLock { $0 } }
    /// Fast cycles that finished, the immediate send included (a test seam).
    var fastCyclesCompleted: Int { fastCycles.withLock { $0 } }

    // MARK: - Publishing

    /// One push cycle over `kinds` (nil: every kind). Oversized records are
    /// skipped WITHOUT recording their hash, so a later smaller version
    /// publishes normally.
    @discardableResult
    func publishOnce(kinds: Set<SliceKind>? = nil) async throws -> Outcome {
        var outcome = Outcome()
        let startGen = try state.generation()
        for kind in SliceKind.allCases where kinds?.contains(kind) ?? true {
            guard let current = try currentDiff(for: kind) else { continue }
            let diff = current.diff
            let saveable = splitOversized(diff.upserts, skipped: &outcome.skipped)
            outcome.skipped.append(contentsOf: diff.skipped)
            let pushed = try await pushKind(
                saveable, assets: current.assets, deletions: diff.deletions, startGen: startGen, into: &outcome
            )
            guard pushed else {
                logger.warning("publish: generation changed mid-cycle; aborted to avoid recording stale hashes")
                return outcome
            }
            if let names = current.assetKindNames { assets?.sweep(kind: kind, keeping: names) }
        }
        let finishedAt = now()
        lastPublish.withLock { $0 = finishedAt }
        return outcome
    }

    private struct KindDiff {
        let diff: SliceDiff.Result
        /// Record name → asset, for the asset-backed records.
        var assets: [String: SliceAsset] = [:]
        /// For a kind with an asset source: every current record name (the
        /// staged files to keep); nil otherwise.
        var assetKindNames: Set<String>?
    }

    /// nil when the kind has neither a SQL window nor a source.
    private func currentDiff(for kind: SliceKind) throws -> KindDiff? {
        var known = try state.hashes(forKind: kind)
        if let sql = Self.sliceSQL[kind] {
            let rows = try fetchRows(sql: sql).map { (id: Self.rowID($0), row: $0) }
            return KindDiff(diff: SliceDiff.compute(kind: kind, rows: rows, knownHashes: known, now: now()))
        }
        let kindSources = sources.filter { $0.kind == kind }
        guard !kindSources.isEmpty else { return nil }
        let fetched = try fetchRecords(kindSources)
        var assetsByName: [String: SliceAsset] = [:]
        var unstageable: [String] = []
        var records: [SliceRecord] = []
        for item in fetched {
            guard let asset = item.asset else {
                records.append(item.record)
                continue
            }
            let name = item.record.recordName
            guard let store = assets else {
                unstageable.append(name)
                continue
            }
            assetsByName[name] = asset
            records.append(item.record)
            // A published record whose staged file is gone (or holds other
            // content) is sent again.
            if store.stagedDigest(recordName: name, fileName: asset.fileName) != asset.digest {
                known.removeValue(forKey: name)
            }
        }
        if !unstageable.isEmpty {
            logger.warning("\(unstageable.count) asset-backed records skipped: no asset store")
        }
        let diff = SliceDiff.compute(kind: kind, records: records, knownHashes: known, assets: assetsByName)
        let isAssetKind = kindSources.contains { $0 is any AssetSliceSource }
        return KindDiff(
            diff: SliceDiff.Result(upserts: diff.upserts, deletions: diff.deletions, skipped: diff.skipped + unstageable),
            assets: assetsByName,
            assetKindNames: isAssetKind ? Set(fetched.map(\.record.recordName)) : nil
        )
    }

    /// Saves and deletes one kind's changes and records the new hashes.
    /// False when an account reset landed mid-cycle (nothing recorded).
    private func pushKind(
        _ upserts: [SliceRecord],
        assets kindAssets: [String: SliceAsset],
        deletions: [String],
        startGen: Int,
        into outcome: inout Outcome
    ) async throws -> Bool {
        let staged = stage(upserts, assets: kindAssets, skipped: &outcome.skipped)
        if !staged.isEmpty {
            try await transport.save(staged.map(\.cloud))
            let hashes = Dictionary(staged.map { record, _ in
                (record.recordName, SliceDiff.recordHash(record, asset: kindAssets[record.recordName]))
            }) { _, last in last }
            guard try state.setHashes(hashes, ifGeneration: startGen) else { return false }
            for (record, _) in staged {
                let name = record.recordName
                oversizedWarned.withLock { _ = $0.removeValue(forKey: name) }
            }
            outcome.pushed += staged.count
        }
        if !deletions.isEmpty {
            try await transport.delete(recordNames: deletions, in: .data)
            guard try state.removeHashes(deletions, ifGeneration: startGen) else { return false }
            outcome.deleted += deletions.count
        }
        return true
    }

    /// The cloud records to save. An asset-backed record's file is staged
    /// first; one that cannot be staged (disk full, the hub turned off) is
    /// skipped unhashed, so the next cycle retries it.
    private func stage(
        _ upserts: [SliceRecord],
        assets kindAssets: [String: SliceAsset],
        skipped: inout [String]
    ) -> [(record: SliceRecord, cloud: CloudRecord)] {
        upserts.compactMap { record in
            guard let asset = kindAssets[record.recordName] else {
                return (record, CloudRecordFactory.record(for: record))
            }
            do {
                return (record, Self.cloudRecord(for: record, assetFileURL: try stagedFile(asset, recordName: record.recordName)))
            } catch {
                skipped.append(record.recordName)
                logger.error("""
                    staging the asset of \(record.recordName, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                return nil
            }
        }
    }

    private enum StagingError: Error, LocalizedError {
        case noStore
        case notBuilt

        var errorDescription: String? {
            switch self {
            case .noStore: return "no asset store"
            case .notBuilt: return "the staged file changed since the source read it; rebuilt next cycle"
            }
        }
    }

    /// The staged file holding `asset`: the one already there when it holds
    /// the same digest, else `asset.data` written now.
    private func stagedFile(_ asset: SliceAsset, recordName: String) throws -> URL {
        guard let store = assets else { throw StagingError.noStore }
        if store.stagedDigest(recordName: recordName, fileName: asset.fileName) == asset.digest {
            return store.fileURL(recordName: recordName, fileName: asset.fileName)
        }
        guard let data = asset.data else { throw StagingError.notBuilt }
        return try store.stage(data, fileName: asset.fileName, recordName: recordName)
    }

    /// `CloudRecordFactory.record(for:)` plus the staged asset file.
    private static func cloudRecord(for slice: SliceRecord, assetFileURL: URL?) -> CloudRecord {
        CloudRecord(
            recordName: slice.recordName,
            zone: .data,
            kind: slice.kind.rawValue,
            modifiedAt: slice.modifiedAt,
            payload: slice.payload,
            notifyLevel: slice.notifyLevel,
            assetFileURL: assetFileURL
        )
    }

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

    /// The read, then the asset sources' builds after it ended (decoding
    /// and hashing stay out of the read transaction).
    private func fetchRecords(_ kindSources: [any SliceSource]) throws -> [AssetSliceRecord] {
        let store = assets
        let stagedDigest: (String, String) -> Data? = { name, file in store?.stagedDigest(recordName: name, fileName: file) }
        var builds: [() throws -> [AssetSliceRecord]] = []
        try dbPool.read { db in
            for source in kindSources {
                if let assetSource = source as? any AssetSliceSource {
                    builds.append(try assetSource.assetRecords(db, stagedDigest: stagedDigest))
                } else {
                    let records = try source.records(db).map { AssetSliceRecord(record: $0, asset: nil) }
                    builds.append { records }
                }
            }
        }
        return try builds.flatMap { try $0() }
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
        let sleep = beginSleep(tick: tick)
        // stop() may have cancelled the loop before this sleep existed.
        if Task.isCancelled { sleep.cancel() }
        await sleep.value
        endSleep(sleep)
    }

    /// Stores and returns the loop's sleep until the next deadline (the
    /// tick, or the fast lane's deadline when sooner). Under the nudge lock,
    /// so a nudge can never fall between "deadline computed" and "stored".
    func beginSleep(tick: ContinuousClock.Instant) -> Task<Void, Never> {
        lane.withLock { [timing] lane in
            let deadline = Self.fastDeadline(lane, timing: timing).map { min($0, tick) } ?? tick
            let task = Task<Void, Never> { _ = try? await Task.sleep(until: deadline, clock: .continuous) }
            lane.sleep = task
            return task
        }
    }

    /// Forgets `sleep` once it returned — only when it is still the stored
    /// handle: a restarted loop may have stored its own meanwhile.
    func endSleep(_ sleep: Task<Void, Never>) {
        lane.withLock { lane in
            if lane.sleep == sleep { lane.sleep = nil }
        }
    }

    // MARK: - Loop

    /// Starts the loop; the first full cycle runs at once.
    func start() {
        assets?.open()
        let task = Task { [weak self] in
            var nextTick = self?.clock() ?? .now
            while !Task.isCancelled {
                guard let self else { return }
                let now = self.clock()
                if now >= nextTick {
                    await self.runCycle(kinds: nil)
                    nextTick = self.clock() + self.timing.tick
                } else if let kinds = self.takeDueFastKinds(now: now) {
                    await self.runFastCycle(kinds: kinds)
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

    /// One cycle; nil when it failed.
    @discardableResult
    private func runCycle(kinds: Set<SliceKind>?) async -> Outcome? {
        do {
            let outcome = try await publishOnce(kinds: kinds)
            if !outcome.skipped.isEmpty {
                logger.debug("publish cycle skipped \(outcome.skipped.count) records")
            }
            return outcome
        } catch {
            logger.error("publish cycle failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A fast cycle, then the immediate send when it changed the zone. The
    /// lane's ≥ 2 s spacing bounds the send rate; the transport itself
    /// honours a throttle wait or a stop.
    private func runFastCycle(kinds: Set<SliceKind>) async {
        if let outcome = await runCycle(kinds: kinds), outcome.pushed + outcome.deleted > 0 {
            await sendNow()
        }
        fastCycles.withLock { $0 += 1 }
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
