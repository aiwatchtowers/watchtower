import CryptoKit
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
    /// SHA-256 of the content; part of the record's hash.
    let digest: Data
    /// The content; nil when the staged file already holds `digest` (the
    /// source skipped the build).
    let data: Data?

    init(fileName: String, digest: Data, data: Data?) {
        self.fileName = fileName
        self.digest = digest
        self.data = data
    }

    init(fileName: String, data: Data) {
        self.init(fileName: fileName, digest: Self.digest(of: data), data: data)
    }

    static func digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

/// One record of an `AssetSliceSource`; `asset` nil means a record without
/// one.
struct AssetSliceRecord {
    let record: SliceRecord
    let asset: SliceAsset?
}

/// A `SliceSource` whose records carry an asset, read in two phases so the
/// expensive part stays out of the publisher's read transaction:
/// `assetRecords` runs inside the read and returns the build, which the
/// publisher runs after the read ended. `stagedDigest(recordName, fileName)`
/// is the SHA-256 of the record's staged file (nil: none); a record whose
/// staged file already holds its asset may come back without `data`.
protocol AssetSliceSource: SliceSource {
    func assetRecords(
        _ db: Database,
        stagedDigest: @escaping (_ recordName: String, _ fileName: String) -> Data?
    ) throws -> () throws -> [AssetSliceRecord]
}

extension AssetSliceSource {
    /// Both phases at once, every asset built.
    func records(_ db: Database) throws -> [SliceRecord] {
        try assetRecords(db) { _, _ in nil }().map(\.record)
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
/// file behind. The staged files' digests are remembered (a file found on
/// disk at launch is hashed once), so an unchanged record is neither
/// rebuilt nor rewritten.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`, an
/// `NSLock` because the critical sections span disk I/O (a 20 MB write).
final class SliceAssetStore: @unchecked Sendable {
    enum StoreError: Error, LocalizedError {
        case closed

        var errorDescription: String? { "the hub is off; slice assets are not staged" }
    }

    let directory: URL
    private let lock = NSLock()
    private var isOpen = true
    /// Staged file path → SHA-256 of its content.
    private var digests: [String: Data] = [:]
    private let logger = Logger(subsystem: Constants.bundleID, category: "SliceAssetStore")

    init(directory: URL) {
        self.directory = directory
    }

    func fileURL(recordName: String, fileName: String) -> URL {
        recordDirectory(recordName).appendingPathComponent(fileName)
    }

    /// Writes `data` for `recordName` (atomically replacing an earlier
    /// version) and returns the staged file.
    func stage(_ data: Data, fileName: String, recordName: String) throws -> URL {
        try lock.withLock {
            guard isOpen else { throw StoreError.closed }
            let url = fileURL(recordName: recordName, fileName: fileName)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            digests[url.path] = SliceAsset.digest(of: data)
            return url
        }
    }

    /// The SHA-256 of the staged file; nil when there is none.
    func stagedDigest(recordName: String, fileName: String) -> Data? {
        lock.withLock {
            let url = fileURL(recordName: recordName, fileName: fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                digests.removeValue(forKey: url.path)
                return nil
            }
            if let known = digests[url.path] { return known }
            // A file staged by an earlier run: hashed once.
            guard let data = try? Data(contentsOf: url) else { return nil }
            let digest = SliceAsset.digest(of: data)
            digests[url.path] = digest
            return digest
        }
    }

    func isStaged(recordName: String, fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(recordName: recordName, fileName: fileName).path)
    }

    /// Removes the files of `kind`'s records not in `keeping` (records that
    /// left the zone, or leftovers of an aborted cycle).
    func sweep(kind: SliceKind, keeping: Set<String>) {
        lock.withLock {
            let prefix = kind.recordName(id: "")
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch CocoaError.fileReadNoSuchFile {
                return
            } catch {
                logger.error("listing staged assets failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            for name in names where name.hasPrefix(prefix) && !keeping.contains(name) {
                remove(directory.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    /// Removes every staged file; staging goes on (an account reset).
    func removeAll() {
        lock.withLock { remove(directory) }
    }

    /// Removes every staged file and refuses new ones until `open()` (the
    /// hub was turned off).
    func close() {
        lock.withLock {
            isOpen = false
            remove(directory)
        }
    }

    func open() {
        lock.withLock { isOpen = true }
    }

    /// Record names are `<kind>-<id>`; a path separator in an id must not
    /// escape the directory.
    private func recordDirectory(_ recordName: String) -> URL {
        directory.appendingPathComponent(recordName.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    /// Under `lock`; forgets the digests below `url`. A missing file is
    /// fine; any other failure is logged (the next sweep retries).
    private func remove(_ url: URL) {
        let prefix = url.path + "/"
        digests = digests.filter { !$0.key.hasPrefix(prefix) }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.error("removing staged asset \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
