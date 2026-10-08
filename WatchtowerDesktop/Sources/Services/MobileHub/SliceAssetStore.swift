import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// A file riding next to a slice record's payload as the record's CKAsset
/// (spec §2.2 `asset`), past the payload's 900 KB budget: the
/// `meeting_transcript` segments (§4.11).
struct SliceAsset: Equatable, Sendable {
    /// The staged file's name, e.g. `segments.json`.
    let fileName: String
    let data: Data
}

/// One record of an `AssetSliceSource`; `asset` nil means a record without
/// one.
struct AssetSliceRecord {
    let record: SliceRecord
    let asset: SliceAsset?
}

/// A `SliceSource` whose records carry an asset. The publisher reads
/// `assetRecords`; `records` is derived from it.
protocol AssetSliceSource: SliceSource {
    func assetRecords(_ db: Database) throws -> [AssetSliceRecord]
}

extension AssetSliceSource {
    func records(_ db: Database) throws -> [SliceRecord] {
        try assetRecords(db).map(\.record)
    }
}

/// The hub's staged asset files, `<directory>/<recordName>/<fileName>`: one
/// per record, replaced atomically when the record changes, removed when the
/// record leaves the zone, on an account reset and when the hub is turned
/// off. The transport's pending save points at the staged file until it is
/// sent, so the file stays while its record is published.
///
/// `close()` removes every file and refuses new ones until `open()`: a
/// publish cycle still running after the hub was turned off cannot leave a
/// file behind.
final class SliceAssetStore: Sendable {
    enum StoreError: Error, LocalizedError {
        case closed

        var errorDescription: String? { "the hub is off; slice assets are not staged" }
    }

    let directory: URL
    /// Whether staging is allowed. Held over every file write and removal,
    /// so a close never interleaves with a stage.
    private let isOpen = OSAllocatedUnfairLock(initialState: true)
    private let logger = Logger(subsystem: Constants.bundleID, category: "SliceAssetStore")

    init(directory: URL) {
        self.directory = directory
    }

    func fileURL(recordName: String, fileName: String) -> URL {
        recordDirectory(recordName).appendingPathComponent(fileName)
    }

    /// Writes `asset` for `recordName` (atomically replacing an earlier
    /// version) and returns the staged file.
    func stage(_ asset: SliceAsset, recordName: String) throws -> URL {
        try isOpen.withLock { isOpen in
            guard isOpen else { throw StoreError.closed }
            let url = fileURL(recordName: recordName, fileName: asset.fileName)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try asset.data.write(to: url, options: .atomic)
            return url
        }
    }

    func isStaged(recordName: String, fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(recordName: recordName, fileName: fileName).path)
    }

    /// Removes the files of `kind`'s records not in `keeping` (records that
    /// left the zone, or leftovers of an aborted cycle).
    func sweep(kind: SliceKind, keeping: Set<String>) {
        isOpen.withLock { _ in
            let prefix = kind.recordName(id: "")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasPrefix(prefix) && !keeping.contains(name) {
                remove(directory.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    /// Removes every staged file; staging goes on (an account reset).
    func removeAll() {
        isOpen.withLock { _ in remove(directory) }
    }

    /// Removes every staged file and refuses new ones until `open()` (the
    /// hub was turned off).
    func close() {
        isOpen.withLock { isOpen in
            isOpen = false
            remove(directory)
        }
    }

    func open() {
        isOpen.withLock { $0 = true }
    }

    /// Record names are `<kind>-<id>`; a path separator in an id must not
    /// escape the directory.
    private func recordDirectory(_ recordName: String) -> URL {
        directory.appendingPathComponent(recordName.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    /// Under the `isOpen` lock. A missing file is fine; any other failure is logged
    /// (the next sweep retries).
    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.error("removing staged asset \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
