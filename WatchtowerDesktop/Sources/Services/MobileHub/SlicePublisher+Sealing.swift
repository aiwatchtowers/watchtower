import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

extension SlicePublisher {
    // MARK: - Sealing and staging

    /// Seals each staged record on its own: one the transport refuses (no
    /// keybox recipient, an unknown kind, a frame that does not encode) is
    /// skipped unhashed (warned once per payload) and retried next cycle,
    /// never failing the others. Any other error (keys that cannot be read:
    /// `keysUnavailable`, an unreadable sealed key) fails the cycle instead:
    /// no record is at fault, and every record would fail alike.
    func seal(
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

    func warnNoKeysOnce() {
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
    func stage(
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

    func splitOversized(
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
}
