import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

final class CLIBinaryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func write(_ name: String, _ content: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func storePath() -> String {
        // Nested dir that does not exist yet — sync must create it.
        dir.appendingPathComponent("store/bin/watchtower").path
    }

    private func makeStoreDir(for store: String) throws {
        try FileManager.default.createDirectory(
            atPath: (store as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
    }

    // MARK: sync

    func testFirstInstallCopiesWithoutStoppingDaemon() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store) { stopped = true }
        XCTAssertEqual(outcome, .installed)
        XCTAssertFalse(stopped, "no store file existed, nothing could be running from it")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v1")
    }

    func testMatchingHashIsNoOp() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store) { stopped = true }
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertFalse(stopped)
    }

    func testStaleCopyStopsDaemonAndReplaces() async throws {
        let bundle = try write("bundle-cli", "v2")
        let store = storePath()
        try makeStoreDir(for: store)
        try Data("v1".utf8).write(to: URL(fileURLWithPath: store))
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store) { stopped = true }
        XCTAssertEqual(outcome, .replaced)
        XCTAssertTrue(stopped, "a stale store copy may back a live daemon — must stop before replacing")
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v2")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
    }

    /// The ordering is the whole point of the daemon stop: replacing the file
    /// first and stopping afterwards would leave a live process backed by a
    /// swapped inode. Read the store from inside the stop closure — it must
    /// still hold the old bytes there.
    func testDaemonIsStoppedBeforeTheFileIsSwapped() async throws {
        let bundle = try write("bundle-cli", "v2")
        let store = storePath()
        try makeStoreDir(for: store)
        try Data("v1".utf8).write(to: URL(fileURLWithPath: store))
        var contentSeenByStop: String?
        let outcome = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {
            contentSeenByStop = try? String(contentsOfFile: store, encoding: .utf8)
        }
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(contentSeenByStop, "v1", "the swap must happen strictly after the daemon stop")
    }

    func testMissingBundleBinaryFailsAndLeavesStoreUntouched() async throws {
        let store = storePath()
        try makeStoreDir(for: store)
        try Data("v1".utf8).write(to: URL(fileURLWithPath: store))
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: dir.appendingPathComponent("nope").path,
            storeBinary: store) {}
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v1")
    }

    /// Copy failure (here: the store's parent directory is a regular file, so
    /// neither createDirectory nor copyItem can succeed) must report `.failed`
    /// and leave whatever was there alone.
    func testCopyFailureReportsFailedAndLeavesStoreIntact() async throws {
        let bundle = try write("bundle-cli", "v2")
        let blockingFile = try write("blocked", "not a directory")
        let store = blockingFile + "/bin/watchtower"
        let outcome = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOfFile: blockingFile, encoding: .utf8), "not a directory")
    }

    /// Same bytes, lost exec bit: reporting `.upToDate` would leave a store
    /// copy nothing can run. Repair it instead.
    func testExecBitIsRepairedInsteadOfReportedUpToDate() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store)
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: store), "precondition")

        let outcome = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {
            XCTFail("nothing is being replaced — the daemon must not be stopped")
        }
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
    }

    /// A crash between copy and rename strands a `.watchtower-<pid>.tmp` file
    /// that nothing else ever removes.
    func testSyncSweepsStaleTemporaries() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        try makeStoreDir(for: store)
        let storeDir = (store as NSString).deletingLastPathComponent
        let litter = storeDir + "/.watchtower-99999.tmp"
        try Data("half-copied".utf8).write(to: URL(fileURLWithPath: litter))

        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: litter))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
    }

    // MARK: installedPath

    func testInstalledPathNilWhenMissing() throws {
        let bundle = try write("bundle-cli", "v1")
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: storePath(), bundleBinary: bundle))
    }

    func testInstalledPathReturnsValidatedCopy() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        XCTAssertEqual(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle), store)
    }

    /// The store lives in a user-writable directory: a copy that does not match
    /// the bundled CLI must never be executed, whatever put it there. Callers
    /// fall back to the bundle.
    func testInstalledPathRejectsCopyThatDoesNotMatchTheBundle() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        // Same length as "v1", so this is caught by the hash, not the size.
        try Data("XX".utf8).write(to: URL(fileURLWithPath: store))
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle))
    }

    func testInstalledPathRejectsCopyOfADifferentSize() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        try Data("a much longer build".utf8).write(to: URL(fileURLWithPath: store))
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle))
    }

    func testInstalledPathRejectsNonExecutableCopy() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store)
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle))
    }

    /// `swift run` / `swift test` have no bundled CLI. A store copy left by a
    /// past `make app` must not shadow the developer's PATH binary — there is
    /// nothing to validate it against.
    func testInstalledPathIgnoresStoreWhenThereIsNoBundledCLI() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store), "precondition")
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: nil))
    }

    // MARK: OCR helper (watchtower-ocr, copied next to the stored CLI)

    private func storeHelperPath(forCLI store: String) -> String {
        ((store as NSString).deletingLastPathComponent as NSString).appendingPathComponent("watchtower-ocr")
    }

    func testOCRHelperPathSitsNextToTheStoredCLI() {
        XCTAssertEqual(
            (CLIBinaryStore.storeOCRHelperPath as NSString).deletingLastPathComponent,
            (CLIBinaryStore.storeBinaryPath as NSString).deletingLastPathComponent)
        XCTAssertEqual((CLIBinaryStore.storeOCRHelperPath as NSString).lastPathComponent, "watchtower-ocr")
    }

    func testOCRHelperCopiedThenUpToDate() throws {
        let bundleHelper = try write("bundle-ocr", "ocr-v1")
        let helper = storeHelperPath(forCLI: storePath())
        XCTAssertEqual(CLIBinaryStore.syncOCRHelper(bundleHelper: bundleHelper, storeHelper: helper), .installed)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper))
        XCTAssertEqual(try String(contentsOfFile: helper, encoding: .utf8), "ocr-v1")
        XCTAssertEqual(CLIBinaryStore.syncOCRHelper(bundleHelper: bundleHelper, storeHelper: helper), .upToDate)
        XCTAssertEqual(CLIBinaryStore.installedPath(storeBinary: helper, bundleBinary: bundleHelper), helper)
    }

    /// Same size, different bytes: caught by the hash and replaced.
    func testOCRHelperMismatchIsReplaced() throws {
        let bundleHelper = try write("bundle-ocr", "ocr-v2")
        let helper = storeHelperPath(forCLI: storePath())
        try makeStoreDir(for: helper)
        try Data("ocr-XX".utf8).write(to: URL(fileURLWithPath: helper))
        XCTAssertEqual(CLIBinaryStore.syncOCRHelper(bundleHelper: bundleHelper, storeHelper: helper), .replaced)
        XCTAssertEqual(try String(contentsOfFile: helper, encoding: .utf8), "ocr-v2")
    }

    /// No helper in the bundle (an older build): a store copy can no longer be
    /// validated, so it is removed — the CLI then reports OCR unavailable
    /// rather than running a helper nothing vouches for.
    func testOCRHelperMissingFromBundleRemovesStoreCopy() throws {
        let helper = storeHelperPath(forCLI: storePath())
        try makeStoreDir(for: helper)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: helper))
        let outcome = CLIBinaryStore.syncOCRHelper(bundleHelper: nil, storeHelper: helper)
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper))
    }

    /// A helper that cannot be synced leaves no mismatched copy behind.
    func testOCRHelperCopyFailureRemovesMismatchedCopy() throws {
        let bundleHelper = try write("bundle-ocr", "ocr-v2")
        let helper = storeHelperPath(forCLI: storePath())
        try makeStoreDir(for: helper)
        try Data("ocr-v1-old".utf8).write(to: URL(fileURLWithPath: helper))
        let storeDir = (helper as NSString).deletingLastPathComponent
        // A read-only store dir: the temp copy cannot be created.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storeDir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeDir) }
        let outcome = CLIBinaryStore.syncOCRHelper(bundleHelper: bundleHelper, storeHelper: helper)
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: helper, bundleBinary: bundleHelper),
                     "whatever is left is not a validated helper")
    }

    /// The CLI and the helper are validated independently: a helper that is
    /// missing, mismatched or failed to sync never blocks CLI resolution.
    func testOCRHelperMismatchLeavesCLIResolutionIntact() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        let helper = storeHelperPath(forCLI: store)
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: helper))
        XCTAssertEqual(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle), store)

        let outcome = CLIBinaryStore.syncOCRHelper(bundleHelper: nil, storeHelper: helper)
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertEqual(CLIBinaryStore.installedPath(storeBinary: store, bundleBinary: bundle), store)
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v1", "the CLI copy is untouched")
    }

    // MARK: signature gate (resolvedInstalledPath's TOCTOU guard)

    /// No running Team ID (ad-hoc/unsigned build) → refuse to validate,
    /// falling back to bundle/PATH instead of exec'ing an unverified binary.
    func testSignatureIsValidRejectsMissingTeamID() throws {
        let file = try write("some-binary", "v1")
        XCTAssertFalse(CLIBinaryStore.signatureIsValid(path: file, teamID: nil))
        XCTAssertFalse(CLIBinaryStore.signatureIsValid(path: file, teamID: ""))
    }

    /// A byte-blob that happens to sit in the store is not code-signed by our
    /// team, so it never satisfies the Team-ID designated requirement — the
    /// whole point of the check beyond the hash match.
    func testSignatureIsValidRejectsUnsignedFile() throws {
        let file = try write("unsigned-binary", "not a signed mach-o")
        XCTAssertFalse(CLIBinaryStore.signatureIsValid(path: file, teamID: "ABCDE12345"))
    }

    func testSignatureIsValidRejectsMissingFile() {
        let missing = dir.appendingPathComponent("does-not-exist").path
        XCTAssertFalse(CLIBinaryStore.signatureIsValid(path: missing, teamID: "ABCDE12345"))
    }

    // MARK: resolver verdict cache

    /// A store matching the bundle, plus a counter of signature checks — each
    /// check stands for a full re-verification (hash + codesign).
    private func makeValidatedStore(_ content: String = "v1") async throws -> (bundle: String, store: String) {
        let bundle = try write("bundle-cli", content)
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store) {}
        CLIBinaryStore.invalidateResolvedPath()
        return (bundle, store)
    }

    func testResolverReusesVerdictWhileFilesAreUnchanged() async throws {
        let (bundle, store) = try await makeValidatedStore()
        var checks = 0
        for _ in 0..<3 {
            let path = CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle) { _ in
                checks += 1
                return true
            }
            XCTAssertEqual(path, store)
        }
        XCTAssertEqual(checks, 1, "an unchanged store must not be re-hashed and re-verified per call")
    }

    /// The TOCTOU guard: a same-size, same-bytes rewrite in place keeps the
    /// inode and size but bumps ctime, so it must be re-verified.
    func testResolverReverifiesAfterInPlaceRewrite() async throws {
        let (bundle, store) = try await makeValidatedStore()
        var checks = 0
        let check: (String) -> Bool = { _ in checks += 1; return true }
        XCTAssertEqual(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle, signatureCheck: check), store)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: store))
        try handle.write(contentsOf: Data("v1".utf8))
        try handle.close()
        XCTAssertEqual(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle, signatureCheck: check), store)
        XCTAssertEqual(checks, 2)
    }

    func testResolverRejectsBinaryRenamedOverAfterVerification() async throws {
        let (bundle, store) = try await makeValidatedStore()
        XCTAssertEqual(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle) { _ in true }, store)
        let swapped = try write("swapped", "v1")
        XCTAssertEqual(rename(swapped, store), 0)
        // Same bytes, but the new file fails the signature gate: the cached
        // verdict for the old inode must not be handed out.
        XCTAssertNil(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle) { _ in false })
    }

    func testResolverCachesARejectionUntilTheStoreChanges() async throws {
        let (bundle, store) = try await makeValidatedStore()
        var checks = 0
        let reject: (String) -> Bool = { _ in checks += 1; return false }
        XCTAssertNil(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle, signatureCheck: reject))
        XCTAssertNil(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle, signatureCheck: reject))
        XCTAssertEqual(checks, 1)
        CLIBinaryStore.invalidateResolvedPath()
        XCTAssertEqual(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle) { _ in true }, store)
    }

    /// A store rewritten while it is being verified is not the file that
    /// passed: it is neither handed out nor cached.
    func testResolverRejectsStoreChangedDuringVerification() async throws {
        let (bundle, store) = try await makeValidatedStore()
        let rewriteDuringCheck: (String) -> Bool = { path in
            let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try? handle?.write(contentsOf: Data("v1".utf8))
            try? handle?.close()
            return true
        }
        XCTAssertNil(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle,
                                                          signatureCheck: rewriteDuringCheck))
        var checks = 0
        XCTAssertEqual(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle) { _ in
            checks += 1
            return true
        }, store)
        XCTAssertEqual(checks, 1, "the mid-check verdict must not have been cached")
    }

    func testResolverNilWithoutBundleOrStore() async throws {
        let (bundle, store) = try await makeValidatedStore()
        XCTAssertNil(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: nil) { _ in true })
        try FileManager.default.removeItem(atPath: store)
        XCTAssertNil(CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle) { _ in true })
    }

    /// A cache hit costs two stats, not two SHA-256 passes over the binary
    /// (8 MB here; the shipped CLI is ~35 MB).
    func testResolverCacheHitIsCheaperThanVerification() async throws {
        let payload = String(repeating: "x", count: 8 * 1024 * 1024)
        let (bundle, store) = try await makeValidatedStore(payload)
        let clock = ContinuousClock()
        let cold = clock.measure {
            _ = CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle) { _ in true }
        }
        let warm = clock.measure {
            for _ in 0..<100 {
                _ = CLIBinaryStore.resolvedInstalledPath(storeBinary: store, bundleBinary: bundle) { _ in true }
            }
        }
        print("CLIBinaryStore resolve 8 MB: cold \(cold), warm \(warm / 100) per call")
        XCTAssertLessThan(warm / 100, cold / 10)
    }
}
