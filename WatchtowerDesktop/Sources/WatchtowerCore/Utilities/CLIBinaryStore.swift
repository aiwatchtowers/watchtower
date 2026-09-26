import Foundation
import CryptoKit
import Security

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

    /// The store path handed to callers that will EXEC it (`Constants.
    /// findCLIPath`'s ~50 sites). Byte-identity to the bundle is necessary but
    /// not sufficient: the store lives in a user-writable directory, so a
    /// same-uid attacker could overwrite `.../bin/watchtower` AFTER launch and,
    /// with a cached verdict, hijack every subsequent CLI spawn in the app's
    /// TCC context (a check≠use TOCTOU). So there is deliberately **no
    /// launch-long cache** — the code-signature check re-runs on every
    /// resolution, keeping check and use close: a binary swapped after launch
    /// is rejected at the next spawn.
    ///
    /// The gate is the on-disk file's own code signature, validated against a
    /// Team-ID designated requirement pinned to the *running* app's Team ID
    /// (the `UpdateService` mechanism, in-process here). Fail safe: a store
    /// binary that is unsigned, ad-hoc, or signed by another team — or a dev
    /// build that can't establish its own Team ID — resolves to nil, so the
    /// caller falls back to the signed bundle / PATH and never execs an
    /// unverified store binary. With no bundled CLI (`swift run`/`swift test`)
    /// `installedPath()` already returns nil, so resolution falls through to
    /// PATH exactly as before.
    package nonisolated static func resolvedInstalledPath() -> String? {
        guard let path = installedPath() else { return nil }
        guard signatureIsValid(path: path, teamID: runningTeamIdentifier()) else { return nil }
        return path
    }

    /// Retained as a no-op: there is no longer a cached verdict to drop.
    /// `sync()` still calls it at its mutation points; keeping the call sites
    /// documents "the store just changed" without reintroducing a cache.
    package nonisolated static func invalidateResolvedPath() {}

    // MARK: - Code-signature validation

    /// True iff the file at `path` carries a valid code signature satisfying a
    /// Team-ID designated requirement for `teamID`. Pure over its inputs so it
    /// is unit-testable; `resolvedInstalledPath()` passes the running app's
    /// Team ID. A nil/empty `teamID`, an unsigned/ad-hoc/foreign binary, or a
    /// missing file all yield false (fail safe).
    package nonisolated static func signatureIsValid(path: String, teamID: String?) -> Bool {
        guard let teamID, !teamID.isEmpty else { return false }
        // Same requirement string as UpdateService.designatedRequirement.
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    /// Team Identifier of the currently running code, read in-process from its
    /// own signature (no `codesign` subprocess — this sits on a hot path). Nil
    /// for ad-hoc/unsigned builds, which fail the signature gate safely.
    nonisolated static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
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
