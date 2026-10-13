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
    /// The hub's sealing transport; nil without hub keys (nothing is published).
    private let transport: SecureTransport?
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
    /// The same throttle for records that could not be sealed.
    private let sealWarned = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private let sealWarningCount = OSAllocatedUnfairLock(initialState: 0)
    private let noKeysWarned = OSAllocatedUnfairLock(initialState: false)
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
        transport: SecureTransport?,
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

    /// Seal-failure warnings actually emitted (the throttle's observable).
    var sealWarnings: Int { sealWarningCount.withLock { $0 } }

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
    /// publishes normally. Without hub keys it reads and sends nothing.
    @discardableResult
    func publishOnce(kinds: Set<SliceKind>? = nil) async throws -> Outcome {
        var outcome = Outcome()
        guard let transport else {
            warnNoKeysOnce()
            return outcome
        }
        let startGen = try state.generation()
        for kind in SliceKind.allCases where kinds?.contains(kind) ?? true {
            guard let current = try currentDiff(for: kind) else { continue }
            let diff = current.diff
            let saveable = splitOversized(diff.upserts, assets: current.assets, skipped: &outcome.skipped)
            outcome.skipped.append(contentsOf: diff.skipped)
            let pushed = try await pushKind(
                kind, saveable, current: current, startGen: startGen, transport: transport, into: &outcome
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
        /// The records the zone held before this cycle (a hash recorded):
        /// an alert outside it reaches the zone now and gets its signal.
        var published: Set<String> = []
    }

    /// nil when the kind has neither a SQL window nor a source.
    private func currentDiff(for kind: SliceKind) throws -> KindDiff? {
        var known = try state.hashes(forKind: kind)
        let published = Set(known.keys)
        if let sql = Self.sliceSQL[kind] {
            let rows = try fetchRows(sql: sql).map { (id: Self.rowID($0), row: $0) }
            return KindDiff(
                diff: SliceDiff.compute(kind: kind, rows: rows, knownHashes: known, now: now()), published: published
            )
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
            assetKindNames: isAssetKind ? Set(fetched.map(\.record.recordName)) : nil,
            published: published
        )
    }

    /// Seals, saves and deletes one kind's changes and records the new
    /// hashes with the wire names. False when an account reset or an epoch
    /// rotation landed mid-cycle: nothing recorded, and nothing saved when it
    /// landed before the save (a save already in flight then still lands and
    /// is overwritten by the next cycle's reseal).
    private func pushKind(
        _ kind: SliceKind,
        _ upserts: [SliceRecord],
        current: KindDiff,
        startGen: Int,
        transport: SecureTransport,
        into outcome: inout Outcome
    ) async throws -> Bool {
        let kindAssets = current.assets
        let staged = stage(upserts, assets: kindAssets, skipped: &outcome.skipped)
        let sealed = try await seal(staged, transport: transport, skipped: &outcome.skipped)
        if !sealed.isEmpty {
            var batch = sealed.map(\.wire)
            if kind == .askAlert {
                batch += sealed.filter { !current.published.contains($0.record.recordName) }
                    .map { AskAlertSignal.record(forSealedAlert: $0.wire) }
            }
            // An epoch rotation (or an account reset) committed while this kind was sealed: what was sealed under
            // the old epoch, a fresh alert's signal included, is not saved; the next cycle reseals it (Task 14).
            guard try state.generation() == startGen else { return false }
            try await transport.saveSealed(batch)
            var hashes: [String: String] = [:]
            var wireNames: [String: String] = [:]
            for (record, wire) in sealed {
                hashes[record.recordName] = SliceDiff.recordHash(record, asset: kindAssets[record.recordName])
                wireNames[record.recordName] = wire.recordName
            }
            guard try state.setHashes(hashes, wireNames: wireNames, ifGeneration: startGen) else { return false }
            for (record, _) in sealed {
                let name = record.recordName
                oversizedWarned.withLock { _ = $0.removeValue(forKey: name) }
                sealWarned.withLock { _ = $0.removeValue(forKey: name) }
            }
            outcome.pushed += sealed.count
        }
        let deletions = current.diff.deletions
        if !deletions.isEmpty {
            var names = deletions
            if kind == .askAlert {
                names += try AskAlertSignal.signalNames(forDeletedAlerts: deletions, transport: transport)
            }
            try await transport.delete(recordNames: names, in: .data)
            guard try state.removeHashes(deletions, ifGeneration: startGen) else { return false }
            outcome.deleted += deletions.count
        }
        return true
    }

    /// Seals each staged record on its own: one the transport refuses (no
    /// keybox recipient, an unknown kind, a frame that does not encode) is
    /// skipped unhashed (warned once per payload) and retried next cycle,
    /// never failing the others. Any other error (keys that cannot be read:
    /// `keysUnavailable`, an unreadable sealed key) fails the cycle instead:
    /// no record is at fault, and every record would fail alike.
    private func seal(
        _ staged: [(record: SliceRecord, cloud: CloudRecord)],
        transport: SecureTransport,
        skipped: inout [String]
    ) async throws -> [(record: SliceRecord, wire: CloudRecord)] {
        var sealed: [(record: SliceRecord, wire: CloudRecord)] = []
        for (record, cloud) in staged {
            do {
                sealed.append((record, try await transport.seal(cloud)))
            } catch let error as SecureTransportError where error != .keysUnavailable {
                skipped.append(record.recordName)
                warnUnsealableIfNeeded(record, error: error)
            } catch let error as EnvelopeError {
                skipped.append(record.recordName)
                warnUnsealableIfNeeded(record, error: error)
            }
        }
        return sealed
    }

    private func warnUnsealableIfNeeded(_ record: SliceRecord, error: any Error) {
        let hash = SliceDiff.hashHex(record.payload)
        let firstSighting = sealWarned.withLock { warned in
            guard warned[record.recordName] != hash else { return false }
            warned[record.recordName] = hash
            return true
        }
        guard firstSighting else { return }
        sealWarningCount.withLock { $0 += 1 }
        // The error names a kind or a record name, never key material or the payload.
        logger.error("""
            slice record not sealed, skipped: \(record.recordName, privacy: .public): \
            \(String(describing: error), privacy: .public); retried next cycle
            """)
    }

    private func warnNoKeysOnce() {
        let first = noKeysWarned.withLock { warned in
            defer { warned = true }
            return !warned
        }
        guard first else { return }
        logger.warning("no hub keys: nothing is published")
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
                let staged = try stagedFile(asset, recordName: record.recordName)
                return (record, Self.cloudRecord(for: record, assetFileURL: staged.url, asset: staged.descriptor))
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

    /// The sealed staged file holding `asset` and its descriptor: the one
    /// already there when it seals the same plaintext (digest), else
    /// `asset.data` sealed and staged now.
    private func stagedFile(_ asset: SliceAsset, recordName: String) throws -> (url: URL, descriptor: AssetDescriptor) {
        guard let store = assets else { throw StagingError.noStore }
        if let staged = store.stagedDescriptor(recordName: recordName, fileName: asset.fileName),
           staged.plaintextDigest == asset.digest {
            return (store.fileURL(recordName: recordName, fileName: asset.fileName), staged)
        }
        guard let data = asset.data else { throw StagingError.notBuilt }
        return try store.stage(data, fileName: asset.fileName, recordName: recordName)
    }

    /// `CloudRecordFactory.record(for:)` plus the sealed asset file and its
    /// descriptor (`SecureTransport` puts the descriptor in the inner frame).
    private static func cloudRecord(for slice: SliceRecord, assetFileURL: URL, asset: AssetDescriptor) -> CloudRecord {
        CloudRecord(
            recordName: slice.recordName,
            zone: .data,
            kind: slice.kind.rawValue,
            modifiedAt: slice.modifiedAt,
            payload: slice.payload,
            notifyLevel: slice.notifyLevel,
            assetFileURL: assetFileURL,
            asset: asset
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

    private func splitOversized(
        _ upserts: [SliceRecord], assets kindAssets: [String: SliceAsset], skipped: inout [String]
    ) -> [SliceRecord] {
        upserts.filter { record in
            guard Self.isOversized(record, signed: true, hasAsset: kindAssets[record.recordName] != nil) else { return true }
            skipped.append(record.recordName)
            warnOversizedIfNeeded(record)
            return false
        }
    }

    /// True when the sealed envelope of `record` cannot fit under
    /// `maxPayloadBytes` even unpadded (D12): its inner frame (kind, plain
    /// name, notify level, the 101-byte asset descriptor when `hasAsset`,
    /// payload) exceeds `EnvelopeSealer.frameCap(signed:)`. A frame that fits
    /// pads only up to the cap, so the envelope never crosses it.
    static func isOversized(_ record: SliceRecord, signed: Bool, hasAsset: Bool = false) -> Bool {
        // The frame `SecureTransport.seal` builds (kind, plain name, level, payload) plus the descriptor it adds.
        let frame = InnerFrame(
            kind: record.kind.rawValue, id: record.recordName, notifyLevel: record.notifyLevel, payload: record.payload
        )
        let frameLength = frame.encodedLength + (hasAsset ? AssetDescriptor.encodedLength : 0)
        let cap = EnvelopeSealer.frameCap(signed: signed)
        guard let padded = Padding.paddedLength(frameLength, cap: cap) else { return true }
        return EnvelopeSealer.sealedLength(frameLength: padded, signed: signed) == nil
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
            payload \(record.payload.count) bytes does not seal under \(Self.maxPayloadBytes); \
            not published, retried when it shrinks
            """)
    }

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
