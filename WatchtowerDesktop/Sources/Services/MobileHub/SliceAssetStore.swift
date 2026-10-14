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
/// is the SHA-256 of the PLAINTEXT the record's staged file seals (nil:
/// none); a record whose staged file already holds its asset may come back
/// without `data`.
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
/// per record, replaced when the record changes, removed when the record
/// leaves the zone, on an account reset and when the hub is turned off. The
/// transport's pending save points at the staged file until it is sent, so
/// the file stays while its record is published.
///
/// Mobile E2E spec §2.5: the staged file is the asset sealed with
/// `ChunkedAssetCipher` under a fresh `K_asset` (header-less chunks), never
/// the plaintext; `<fileName>.desc` beside it holds its `AssetDescriptor`
/// (key, header, SHA-256 of the plaintext), which the record's envelope
/// carries. The Mac keeps `K_asset` next to the file: it holds the plaintext
/// anyway, and FileVault is the at-rest story (spec §2.6). The digest index
/// is the descriptor's plaintext digest, so an unchanged record is neither
/// rebuilt nor re-sealed (a re-seal under a fresh key changes every byte).
///
/// A restage removes the old descriptor first, then writes the sealed file,
/// then the new descriptor (each atomically): a crash in between leaves a
/// file without a descriptor, which reads as not staged and is staged again,
/// so a descriptor never describes another file. A descriptor whose sealed
/// length is not its file's reads as not staged too.
///
/// `close()` removes every file and refuses new ones until `open()`: a
/// publish cycle still running after the hub was turned off cannot leave a
/// file behind.
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
    /// Staged file path → its descriptor (a `.desc` found at launch is read once).
    private var descriptors: [String: AssetDescriptor] = [:]
    private let logger = Logger(subsystem: Constants.bundleID, category: "SliceAssetStore")

    init(directory: URL) {
        self.directory = directory
    }

    func fileURL(recordName: String, fileName: String) -> URL {
        recordDirectory(recordName).appendingPathComponent(fileName)
    }

    /// `<fileName>.desc` beside the staged file.
    func descriptorURL(recordName: String, fileName: String) -> URL {
        fileURL(recordName: recordName, fileName: fileName).appendingPathExtension("desc")
    }

    /// Seals `data` under a fresh `K_asset` (in memory: the 20 MB clip bounds
    /// it), stages the sealed file for `recordName` in place of an earlier
    /// version, writes its descriptor, and returns both.
    func stage(_ data: Data, fileName: String, recordName: String) throws -> (url: URL, descriptor: AssetDescriptor) {
        try lock.withLock {
            guard isOpen else { throw StoreError.closed }
            let url = fileURL(recordName: recordName, fileName: fileName)
            let descriptorURL = descriptorURL(recordName: recordName, fileName: fileName)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let sealed = try ChunkedAssetCipher.encrypt(data)
            descriptors.removeValue(forKey: url.path)
            do {
                try FileManager.default.removeItem(at: descriptorURL)
            } catch CocoaError.fileNoSuchFile {
                // Nothing was staged before.
            }
            try sealed.sealed.write(to: url, options: .atomic)
            try sealed.descriptor.encoded().write(to: descriptorURL, options: .atomic)
            descriptors[url.path] = sealed.descriptor
            return (url, sealed.descriptor)
        }
    }

    /// The descriptor of the staged file (from `<fileName>.desc`); nil when
    /// the file or its descriptor is missing, the descriptor does not parse,
    /// or its sealed length is not the file's.
    func stagedDescriptor(recordName: String, fileName: String) -> AssetDescriptor? {
        lock.withLock {
            let url = fileURL(recordName: recordName, fileName: fileName)
            let descriptorURL = descriptorURL(recordName: recordName, fileName: fileName)
            let manager = FileManager.default
            guard manager.fileExists(atPath: url.path), manager.fileExists(atPath: descriptorURL.path) else {
                descriptors.removeValue(forKey: url.path)
                return nil
            }
            if let known = descriptors[url.path] { return known }
            // Staged by an earlier run: read once.
            guard let descriptor = readDescriptor(descriptorURL, sealedFile: url) else { return nil }
            descriptors[url.path] = descriptor
            return descriptor
        }
    }

    /// The SHA-256 of the plaintext the staged file seals; nil when nothing
    /// usable is staged.
    func stagedDigest(recordName: String, fileName: String) -> Data? {
        stagedDescriptor(recordName: recordName, fileName: fileName)?.plaintextDigest
    }

    func isStaged(recordName: String, fileName: String) -> Bool {
        stagedDescriptor(recordName: recordName, fileName: fileName) != nil
    }

    /// Under `lock`. nil (logged) for an unreadable or malformed descriptor
    /// and for one whose sealed length is not the file's.
    private func readDescriptor(_ descriptorURL: URL, sealedFile url: URL) -> AssetDescriptor? {
        do {
            let descriptor = try AssetDescriptor.parse(try Data(contentsOf: descriptorURL))
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            let expected = ChunkedAssetCipher.sealedLength(
                forPlaintext: Int64(clamping: descriptor.header.totalLength), chunkSize: descriptor.header.chunkSize
            )
            guard size?.int64Value == expected else {
                logger.warning("staged asset \(url.lastPathComponent, privacy: .public) does not match its descriptor; restaged")
                return nil
            }
            return descriptor
        } catch {
            logger.warning("""
                staged asset descriptor \(descriptorURL.lastPathComponent, privacy: .public) unreadable, restaged: \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
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

    /// Under `lock`; forgets the descriptors below `url`. A missing file is
    /// fine; any other failure is logged (the next sweep retries).
    private func remove(_ url: URL) {
        let prefix = url.path + "/"
        descriptors = descriptors.filter { !$0.key.hasPrefix(prefix) }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.error("removing staged asset \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
