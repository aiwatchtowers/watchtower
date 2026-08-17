import Foundation
import CryptoKit

/// Owns the out-of-bundle CLI copy the daemon and all Desktop-spawned CLI
/// processes run from. Rebuilding or updating the app overwrites the bundle
/// binary, and macOS invalidates the code signature of any live process whose
/// backing file changed — so live processes must never run from the bundle.
/// The store copy is replaced only after the daemon is stopped, via an atomic
/// rename, so no process ever runs from a file that gets overwritten.
///
/// The store lives in a user-writable directory, so "a file exists there" is
/// not a reason to execute it: `installedPath` hands it out only when it is
/// byte-identical to the CLI inside the (signed) bundle.
package enum CLIBinaryStore {
    package enum Outcome: Equatable {
        case installed   // no copy existed; bundle CLI copied in
        case upToDate    // copy matches the bundle CLI byte-for-byte
        case replaced    // stale copy replaced (daemon stopped first)
        case failed(String)
    }

    /// Default on-disk location of the store copy.
    package nonisolated static var storeBinaryPath: String {
        NSString("~/Library/Application Support/Watchtower/bin/watchtower").expandingTildeInPath
    }

    private static let tmpPrefix = ".watchtower-"
    private static let tmpSuffix = ".tmp"

    /// The store copy if it is executable AND matches the bundled CLI, nil
    /// otherwise (callers fall back to the bundle / PATH lookup).
    ///
    /// Two rejections matter beyond the obvious tampering case:
    /// a copy left over from an older app version is rejected instead of being
    /// executed as if current, and with **no bundled CLI at all** (`swift run`,
    /// `swift test`) the store is ignored outright so a copy from a past
    /// `make app` cannot shadow the developer's PATH binary.
    package nonisolated static func installedPath(
        storeBinary: String = storeBinaryPath,
        bundleBinary: String? = Constants.bundledCLIPath()
    ) -> String? {
        let fm = FileManager.default
        guard let bundleBinary, fm.isExecutableFile(atPath: storeBinary) else { return nil }
        // Size first: a mismatched copy is usually a different build, and this
        // way the common mismatch costs a stat instead of two full hashes.
        guard let storeSize = fileSize(storeBinary), storeSize == fileSize(bundleBinary) else { return nil }
        guard let bundleHash = sha256(bundleBinary), sha256(storeBinary) == bundleHash else { return nil }
        return storeBinary
    }

    /// `installedPath()` for the real store and bundle, computed once per
    /// launch. `Constants.findCLIPath()` has ~50 call sites and must not hash a
    /// ~100 MB binary on each; the cache is dropped whenever `sync` changes the
    /// store, so a launch that replaces the copy still resolves it afterwards.
    package nonisolated static func resolvedInstalledPath() -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedInstalledPath { return cached }
        let resolved = installedPath()
        cachedInstalledPath = .some(resolved)
        return resolved
    }

    private static let cacheLock = NSLock()
    /// Outer nil: not computed yet. Inner nil: computed, no usable store copy.
    nonisolated(unsafe) private static var cachedInstalledPath: String??

    package nonisolated static func invalidateResolvedPath() {
        cacheLock.lock()
        cachedInstalledPath = nil
        cacheLock.unlock()
    }

    /// Bring the store copy in sync with the bundled CLI. `stopDaemon` runs
    /// only when an existing (possibly live) copy is about to be replaced.
    package nonisolated static func sync(
        bundleBinary: String,
        storeBinary: String = storeBinaryPath,
        stopDaemon: () async -> Void
    ) async -> Outcome {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bundleBinary) else {
            return .failed("bundled CLI missing or not executable at \(bundleBinary)")
        }
        guard let bundleSize = fileSize(bundleBinary) else {
            return .failed("cannot read bundled CLI at \(bundleBinary)")
        }
        let storeDir = (storeBinary as NSString).deletingLastPathComponent
        sweepTemporaries(in: storeDir)

        // Hash only when the sizes already agree (F10: a differing build is the
        // common case and needs no hash at all).
        var matches = false
        if fileSize(storeBinary) == bundleSize {
            guard let bundleHash = sha256(bundleBinary) else {
                return .failed("cannot read bundled CLI at \(bundleBinary)")
            }
            matches = sha256(storeBinary) == bundleHash
        }
        if matches {
            // Same bytes but no exec bit is not "up to date" — it is a copy
            // nothing can run. Repair rather than report a healthy store.
            if !fm.isExecutableFile(atPath: storeBinary) {
                do {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeBinary)
                } catch {
                    return .failed("cannot restore exec permission on \(storeBinary): \(error.localizedDescription)")
                }
                invalidateResolvedPath()
            }
            return .upToDate
        }

        let firstInstall = !fm.fileExists(atPath: storeBinary)
        if !firstInstall { await stopDaemon() }

        let tmp = storeDir + "/\(tmpPrefix)\(ProcessInfo.processInfo.processIdentifier)\(tmpSuffix)"
        do {
            try fm.createDirectory(atPath: storeDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: tmp) { try fm.removeItem(atPath: tmp) }
            try fm.copyItem(atPath: bundleBinary, toPath: tmp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        } catch {
            try? fm.removeItem(atPath: tmp)
            return .failed(error.localizedDescription)
        }
        // rename(2) is atomic and re-points the directory entry: even if a
        // straggler still runs from the old inode, that inode's bytes are
        // never modified, so its code signature stays intact.
        guard rename(tmp, storeBinary) == 0 else {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            return .failed("rename to \(storeBinary) failed: \(err)")
        }
        invalidateResolvedPath()
        return firstInstall ? .installed : .replaced
    }

    /// Remove `.watchtower-<pid>.tmp` leftovers: a crash between copy and
    /// rename strands one per attempt, and nothing else ever cleans them up.
    nonisolated private static func sweepTemporaries(in storeDir: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: storeDir) else { return }
        for name in entries where name.hasPrefix(tmpPrefix) && name.hasSuffix(tmpSuffix) {
            try? fm.removeItem(atPath: storeDir + "/" + name)
        }
    }

    nonisolated private static func fileSize(_ path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.size] as? Int
    }

    nonisolated private static func sha256(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
