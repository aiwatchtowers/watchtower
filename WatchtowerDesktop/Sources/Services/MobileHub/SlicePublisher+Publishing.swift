import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

extension SlicePublisher {
    // MARK: - Publishing

    /// One push cycle over `kinds` (nil: every kind), the urgent kinds
    /// first (`publishOrder`). Oversized records are skipped WITHOUT
    /// recording their hash, so a later smaller version publishes normally.
    /// Without hub keys it reads and sends nothing.
    @discardableResult
    func publishOnce(kinds: Set<SliceKind>? = nil) async throws -> Outcome {
        var outcome = Outcome()
        guard let transport else {
            warnNoKeysOnce()
            return outcome
        }
        let startGen = try state.generation()
        for kind in Self.publishOrder where kinds?.contains(kind) ?? true {
            guard let current = try currentDiff(for: kind) else { continue }
            let diff = current.diff
            let saveable = splitOversized(diff.upserts, assets: current.assets, skipped: &outcome.skipped)
            outcome.skipped.append(contentsOf: diff.skipped)
            let before = outcome.pushed + outcome.deleted
            let pushed = try await pushKind(
                kind, saveable, current: current, startGen: startGen, transport: transport, into: &outcome
            )
            if Self.urgentKinds.contains(kind) { outcome.urgentChanges += outcome.pushed + outcome.deleted - before }
            guard pushed else {
                logger.warning("publish: generation changed mid-cycle; aborted to avoid recording stale hashes")
                return outcome
            }
            if let names = current.assetKindNames { assets?.sweep(kind: kind, keeping: names) }
        }
        let finishedAt = now()
        lastPublish.withLock { $0 = finishedAt }
        outcome.completed = true
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
