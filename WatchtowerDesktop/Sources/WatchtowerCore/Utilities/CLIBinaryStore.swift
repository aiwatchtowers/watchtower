import Foundation
import CryptoKit
import Security
import os

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
        guard let bundleBinary, storeMatches(storeBinary, bundleBinary) == .match else { return nil }
        return storeBinary
    }

    /// `unreadable` is not a verdict: a file could not be read right now, so
    /// the resolver must not cache it as a rejection.
    private enum StoreMatch { case match, mismatch, unreadable }

    /// Whether `store` is executable and byte-identical to `bundle`.
    nonisolated private static func storeMatches(_ store: String, _ bundle: String) -> StoreMatch {
        guard FileManager.default.isExecutableFile(atPath: store) else { return .mismatch }
        guard let storeSize = fileSize(store), let bundleSize = fileSize(bundle) else { return .unreadable }
        // Size first: a mismatched copy is usually a different build, and this
        // way the common mismatch costs a stat instead of two full hashes.
        guard storeSize == bundleSize else { return .mismatch }
        guard let bundleHash = sha256(bundle), let storeHash = sha256(store) else { return .unreadable }
        return storeHash == bundleHash ? .match : .mismatch
    }

    /// The store path handed to callers that will EXEC it (`Constants.
    /// findCLIPath`'s ~50 sites). Byte-identity to the bundle is necessary but
    /// not sufficient: the store lives in a user-writable directory, so a
    /// same-uid attacker could overwrite `.../bin/watchtower` AFTER launch and,
    /// with a launch-long verdict, hijack every subsequent CLI spawn in the
    /// app's TCC context (a check≠use TOCTOU).
    ///
    /// So the verdict is cached only against the on-disk identity of both
    /// files — device, inode, size, mtime and ctime, re-read with `stat` on
    /// every call. A write(2)/truncate to the store file bumps its ctime
    /// (which a same-uid process cannot set back), and a rename-over gives it
    /// a new inode, so a binary swapped after launch still misses the cache
    /// and is re-verified at the next spawn, while an unchanged one costs two
    /// `stat` calls instead of two 35 MB SHA-256 passes plus a signature
    /// check. (Pages patched through a shared writable mapping may reach exec
    /// before the timestamps move; the kernel's code-signing page validation
    /// of the Team-signed binary is the backstop there.) A file that changes
    /// while it is being verified is neither cached nor handed out.
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
        // A build with no Team ID can never validate the store: skip the hashing.
        guard let teamID = cachedRunningTeamID() else { return nil }
        return resolvedInstalledPath(
            storeBinary: storeBinaryPath,
            bundleBinary: Constants.bundledCLIPath()
        ) { signatureIsValid(path: $0, teamID: teamID) }
    }

    /// `resolvedInstalledPath()` over explicit inputs, so tests can drive the
    /// identity cache with unsigned fixtures. `signatureCheck` runs only on a
    /// cache miss, after the byte-identity check passed.
    package nonisolated static func resolvedInstalledPath(
        storeBinary: String,
        bundleBinary: String?,
        signatureCheck: (String) -> Bool
    ) -> String? {
        guard let bundleBinary,
              let storeID = FileIdentity(path: storeBinary),
              let bundleID = FileIdentity(path: bundleBinary) else { return nil }
        let key = VerdictKey(storePath: storeBinary, store: storeID, bundlePath: bundleBinary, bundle: bundleID)
        if let cached = verdictCache.withLock({ $0 }), cached.key == key {
            return cached.path
        }
        let path: String?
        switch storeMatches(storeBinary, bundleBinary) {
        case .unreadable: return nil // fall back for this call, cache nothing
        case .mismatch: path = nil
        case .match: path = signatureCheck(storeBinary) ? storeBinary : nil
        }
        // Re-stat after verifying: a file that changed while it was being
        // hashed or checked is not the file that passed — never hand it out.
        guard FileIdentity(path: storeBinary) == storeID, FileIdentity(path: bundleBinary) == bundleID else {
            return nil
        }
        let previous = verdictCache.withLock { state -> Verdict? in
            defer { state = Verdict(key: key, path: path) }
            return state
        }
        if path == nil, let previous, previous.key.storePath == storeBinary, previous.path != nil {
            NSLog("CLIBinaryStore: the store CLI at %@ changed and failed verification; CLI spawns fall back to the bundle",
                  storeBinary)
        }
        return path
    }

    /// Drops the cached verdict. The identity key already catches every
    /// change `sync()` makes; the explicit drop at its mutation points (and
    /// in tests, between fixtures) keeps a verdict from outliving a store the
    /// app itself just rewrote.
    package nonisolated static func invalidateResolvedPath() {
        verdictCache.withLock { $0 = nil }
    }

    /// The on-disk identity a cached verdict is valid for. ctime is the
    /// load-bearing field: unlike mtime it cannot be set back by a same-uid
    /// process, so any in-place write is visible here.
    private struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mtime: timespec
        let ctime: timespec

        init?(path: String) {
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            device = st.st_dev
            inode = st.st_ino
            size = st.st_size
            mtime = st.st_mtimespec
            ctime = st.st_ctimespec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.mtime.tv_sec == rhs.mtime.tv_sec && lhs.mtime.tv_nsec == rhs.mtime.tv_nsec
                && lhs.ctime.tv_sec == rhs.ctime.tv_sec && lhs.ctime.tv_nsec == rhs.ctime.tv_nsec
        }
    }

    private struct VerdictKey: Equatable, Sendable {
        let storePath: String
        let store: FileIdentity
        let bundlePath: String
        let bundle: FileIdentity
    }

    private struct Verdict: Sendable {
        let key: VerdictKey
        let path: String?
    }

    nonisolated private static let verdictCache = OSAllocatedUnfairLock<Verdict?>(initialState: nil)

    nonisolated private static let teamIDCache = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The running app's Team ID never changes during a launch, so it is read
    /// once — but a nil (an ad-hoc build, or a failed read) is re-read rather
    /// than pinned for the whole launch.
    nonisolated private static func cachedRunningTeamID() -> String? {
        if let cached = teamIDCache.withLock({ $0 }) { return cached }
        let teamID = runningTeamIdentifier()
        if let teamID { teamIDCache.withLock { $0 = teamID } }
        return teamID
    }

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
    package nonisolated static func runningTeamIdentifier() -> String? {
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

        if let failure = copyIn(from: bundleBinary, to: storeBinary, tag: "") {
            return .failed(failure)
        }
        invalidateResolvedPath()
        return firstInstall ? .installed : .replaced
    }

    /// Copies `source` over `destination` through a temp file in the same
    /// directory and an atomic rename. Returns the failure, nil on success.
    nonisolated private static func copyIn(from source: String, to destination: String, tag: String) -> String? {
        let fm = FileManager.default
        let dir = (destination as NSString).deletingLastPathComponent
        let tmp = dir + "/\(tmpPrefix)\(tag)\(ProcessInfo.processInfo.processIdentifier)\(tmpSuffix)"
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: tmp) { try fm.removeItem(atPath: tmp) }
            try fm.copyItem(atPath: source, toPath: tmp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        } catch {
            try? fm.removeItem(atPath: tmp)
            return error.localizedDescription
        }
        // rename(2) is atomic and re-points the directory entry: even if a
        // straggler still runs from the old inode, that inode's bytes are
        // never modified, so its code signature stays intact.
        guard rename(tmp, destination) == 0 else {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            return "rename to \(destination) failed: \(err)"
        }
        return nil
    }

    // MARK: - OCR helper

    /// The `watchtower-ocr` helper's store location: next to the stored CLI,
    /// where the Go side looks for it (`extract.ResolveHelperPath`: next to
    /// its own executable).
    package nonisolated static var storeOCRHelperPath: String {
        ((storeBinaryPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("watchtower-ocr")
    }

    /// Bring the store's OCR helper in sync with the bundled one, validated
    /// on its own (size, then SHA256) — independent of the CLI: nothing here
    /// can fail or change the CLI copy, so a helper problem never blocks CLI
    /// resolution; the CLI just reports OCR as unavailable. No daemon stop:
    /// the daemon spawns the helper per attachment, and the atomic rename
    /// never modifies a running helper's inode. When the bundle has no helper
    /// or the copy fails, any store copy is removed rather than left
    /// unvalidated.
    package nonisolated static func syncOCRHelper(
        bundleHelper: String?,
        storeHelper: String = storeOCRHelperPath
    ) -> Outcome {
        let fm = FileManager.default
        guard let bundleHelper, fm.isExecutableFile(atPath: bundleHelper) else {
            try? fm.removeItem(atPath: storeHelper)
            return .failed("bundled OCR helper missing or not executable")
        }
        if installedPath(storeBinary: storeHelper, bundleBinary: bundleHelper) != nil {
            return .upToDate
        }
        let firstInstall = !fm.fileExists(atPath: storeHelper)
        if let failure = copyIn(from: bundleHelper, to: storeHelper, tag: "ocr-") {
            try? fm.removeItem(atPath: storeHelper)
            return .failed(failure)
        }
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
