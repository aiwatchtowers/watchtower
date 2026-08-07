import Foundation
import CryptoKit

/// Owns the out-of-bundle CLI copy the daemon and all Desktop-spawned CLI
/// processes run from. Rebuilding or updating the app overwrites the bundle
/// binary, and macOS invalidates the code signature of any live process whose
/// backing file changed — so live processes must never run from the bundle.
/// The store copy is replaced only after the daemon is stopped, via an atomic
/// rename, so no process ever runs from a file that gets overwritten.
enum CLIBinaryStore {
    enum Outcome: Equatable {
        case installed   // no copy existed; bundle CLI copied in
        case upToDate    // copy matches the bundle CLI byte-for-byte
        case replaced    // stale copy replaced (daemon stopped first)
        case failed(String)
    }

    /// Default on-disk location of the store copy.
    nonisolated static var storeBinaryPath: String {
        NSString("~/Library/Application Support/Watchtower/bin/watchtower").expandingTildeInPath
    }

    /// The store copy if present and executable, nil otherwise (callers fall
    /// back to the bundle / PATH lookup).
    nonisolated static func installedPath(storeBinary: String = storeBinaryPath) -> String? {
        FileManager.default.isExecutableFile(atPath: storeBinary) ? storeBinary : nil
    }

    /// Bring the store copy in sync with the bundled CLI. `stopDaemon` runs
    /// only when an existing (possibly live) copy is about to be replaced.
    nonisolated static func sync(
        bundleBinary: String,
        storeBinary: String = storeBinaryPath,
        stopDaemon: () async -> Void
    ) async -> Outcome {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bundleBinary) else {
            return .failed("bundled CLI missing or not executable at \(bundleBinary)")
        }
        guard let bundleHash = sha256(bundleBinary) else {
            return .failed("cannot read bundled CLI at \(bundleBinary)")
        }
        let existing = sha256(storeBinary)
        if existing == bundleHash { return .upToDate }

        let firstInstall = !fm.fileExists(atPath: storeBinary)
        if !firstInstall { await stopDaemon() }

        let storeDir = (storeBinary as NSString).deletingLastPathComponent
        let tmp = storeDir + "/.watchtower-\(ProcessInfo.processInfo.processIdentifier).tmp"
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
        return firstInstall ? .installed : .replaced
    }

    nonisolated private static func sha256(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
