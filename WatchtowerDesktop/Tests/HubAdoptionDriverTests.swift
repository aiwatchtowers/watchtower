import CryptoKit
import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The Desktop's hand-over of Mobile to the Go hub (go hub plan 3 Task 22,
/// spec §12.1–§12.2): state through `hub adopt --status`, the keys looked up
/// without creating any, the settings, the keys on stdin, then the Desktop
/// items deleted and confirmed.
@MainActor
final class HubAdoptionDriverTests: XCTestCase {
    private var log: AdoptionLog!
    private var hub: FakeAdoptHub!
    private var keys: FakeHubKeyStore!
    private var restartSettled = true
    private var restartWaiters: [CheckedContinuation<Void, Never>] = []
    private var settings = HubAdoptSettings(enabled: true, startSessionAllows: [:])
    private var delivered = 0
    private var storageCloses = true
    private var deadline: Duration = HubAdoptionDriver.stepDeadline

    override func setUp() async throws {
        log = AdoptionLog()
        hub = FakeAdoptHub(log: log)
        keys = FakeHubKeyStore(log: log)
        restartSettled = true
        restartWaiters = []
        delivered = 0
        storageCloses = true
        deadline = HubAdoptionDriver.stepDeadline
    }

    private func makeDriver(
        useRunner: Bool = true,
        cancel: (@MainActor ([String]) async -> Void)? = nil
    ) -> HubAdoptionDriver {
        HubAdoptionDriver(seams: .init(
            waitForHostRestart: { [weak self] in
                guard let self else { return }
                self.log.append("restart-wait")
                if !self.restartSettled { await withCheckedContinuation { self.restartWaiters.append($0) } }
                self.log.append("restart-settled")
            },
            policyOffWipe: { [log] in log?.append("policy-wipe") },
            stopSwiftHub: { [weak self, log] in
                log?.append("swift-hub-stop")
                await Task.yield()
                guard self?.storageCloses == true else { return false }
                log?.append("swift-storage-closed")
                return true
            },
            cancelPhoneRecordings: { [log] names in
                log?.append("cancel:\(names.joined(separator: ","))")
                await cancel?(names)
            },
            phoneRecordingsAdopted: { [log] in log?.append("adopted:\($0.joined(separator: ","))") },
            releasePhoneRecordings: { [log] in log?.append("released:\($0.joined(separator: ","))") },
            deps: HubAdoptionDeps(runner: useRunner ? hub : nil, keyStore: keys, stepDeadline: deadline),
            settings: { [weak self] in self?.settings ?? HubAdoptSettings(enabled: false, startSessionAllows: [:]) },
            settingsDelivered: { [weak self] in self?.delivered += 1 }
        ))
    }

    private func settleRestart() {
        restartSettled = true
        let waiters = restartWaiters
        restartWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func present(pending: Bool = false) {
        hub.state = .init(hubID: "hub-acme", swiftState: "present",
                          pending: pending ? [.init(uploadID: "u-1", audioName: "rec_1.m4a")] : [])
    }

    // MARK: - The whole hand-over

    func testHandOverRunsStateThenKeysThenCleanup() async throws {
        present(pending: true)
        try keys.seed(hubID: "hub-acme")

        let result = await makeDriver().run()

        XCTAssertEqual(result, .done)
        XCTAssertEqual(hub.state.identity, "confirmed")
        XCTAssertEqual(log.events, [
            "cli:--status", "policy-wipe", "restart-wait", "restart-settled",
            "cli:--status", "keychain:lookup:hub-acme", "swift-hub-stop", "swift-storage-closed",
            "cancel:rec_1.m4a", "cli:--settings-stdin", "adopted:rec_1.m4a",
            "cli:--status", "keychain:lookup:hub-acme", "cli:--keys-stdin",
            "keychain:delete:hub-acme", "cli:--confirm-deleted"
        ])
        XCTAssertGreaterThanOrEqual(delivered, 1, "the Desktop's copy of the toggle goes once the Go hub took it")
        XCTAssertFalse(keys.has("hub-acme"))
        XCTAssertEqual(keys.creations, 0, "the hand-over never creates keys")
    }

    func testAdoptionStopsTheSwiftHubBeforeHubAdopt() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        _ = await makeDriver().run()
        let events = log.events
        let stop = try XCTUnwrap(events.firstIndex(of: "swift-hub-stop"))
        let closed = try XCTUnwrap(events.firstIndex(of: "swift-storage-closed"))
        let adopt = try XCTUnwrap(events.firstIndex(of: "cli:--settings-stdin"))
        XCTAssertLessThan(stop, closed)
        XCTAssertLessThan(closed, adopt, "the storage is closed before the adopting hub adopt starts")
    }

    func testAStorageThatDoesNotCloseFailsSwiftBusyBeforeHubAdopt() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        storageCloses = false
        let result = await makeDriver().run()
        XCTAssertEqual(result, .failed(reason: "swift_busy"))
        XCTAssertFalse(log.events.contains("cli:--settings-stdin"))
    }

    /// While the restart step waits for Continue nothing shows: the status
    /// read is unseen and the state stays idle (no spinner).
    func testAdoptionWaitsForTheHostRestartStepUnseen() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        restartSettled = false
        let driver = makeDriver()
        let run = Task { await driver.run() }
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(log.events, ["cli:--status", "policy-wipe", "restart-wait"],
                       "nothing but the unseen read and the POLICY-03 check runs before Continue")
        XCTAssertEqual(driver.state, .idle)
        XCTAssertFalse(driver.state.isShown, "Settings → Mobile is no spinner while Continue waits")

        settleRestart()
        let result = await run.value
        XCTAssertEqual(result, .done)
    }

    func testRunsAfterTheRestartStep() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        _ = await makeDriver().run()
        let events = log.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "restart-settled")),
                          try XCTUnwrap(events.firstIndex(of: "swift-hub-stop")))
    }

    func testNoSwiftStateSkips() async {
        for swift in ["absent", "ignored"] {
            setUpLog()
            hub.state = .init(hubID: "hub-acme", swiftState: swift)
            let driver = makeDriver()
            let result = await driver.run()
            XCTAssertEqual(result, .notNeeded, swift)
            XCTAssertEqual(log.events, ["cli:--status"], "no wait, no wipe, nothing shown: \(swift)")
            XCTAssertFalse(driver.state.isShown)
        }
    }

    // MARK: - Stdin

    func testKeysOnlyOnStdin() async throws {
        present()
        let identity = try keys.seed(hubID: "hub-acme")
        _ = await makeDriver().run()

        let keyCalls = hub.calls.filter { $0.args.contains("--keys-stdin") }
        let call = try XCTUnwrap(keyCalls.first)
        XCTAssertEqual(keyCalls.count, 1)
        XCTAssertEqual(call.args, ["hub", "adopt", "--keys-stdin", "--json"], "nothing but the verb on argv")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: call.stdin) as? [String: String])
        XCTAssertEqual(Set(payload.keys), ["hub_sig", "hub_kx", "wrap"])
        XCTAssertEqual(payload["hub_sig"], identity.signing.rawRepresentation.base64EncodedString())
        XCTAssertEqual(payload["hub_kx"], identity.agreement.rawRepresentation.base64EncodedString())
        XCTAssertEqual(payload["wrap"], identity.wrapKey.withUnsafeBytes { Data($0) }.base64EncodedString())

        let secrets = payload.values
        for other in hub.calls {
            for secret in secrets {
                XCTAssertFalse(other.args.joined(separator: " ").contains(secret), "argv never carries a key")
                if other.args != call.args {
                    XCTAssertFalse((String(bytes: other.stdin, encoding: .utf8) ?? "").contains(secret),
                                   "only the keys call carries keys: \(other.args)")
                }
            }
        }
        let settingsCall = try XCTUnwrap(hub.calls.first { $0.args.contains("--settings-stdin") })
        XCTAssertEqual(settingsCall.args, ["hub", "adopt", "--settings-stdin", "--json"], "settings and keys: two calls")
    }

    func testKeysPayloadIsTheThreeKeysInStandardBase64() throws {
        let keys = HubIdentityKeys(signing: .init(), agreement: .init(), wrapKey: SymmetricKey(size: .bits256))
        let payload = try HubAdoptionDriver.keysPayload(keys)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: String])
        XCTAssertEqual(object["hub_sig"].flatMap { Data(base64Encoded: $0) }, keys.signing.rawRepresentation)
        XCTAssertEqual(object["hub_kx"].flatMap { Data(base64Encoded: $0) }, keys.agreement.rawRepresentation)
        XCTAssertEqual(object["wrap"].flatMap { Data(base64Encoded: $0) }, keys.wrapKey.withUnsafeBytes { Data($0) })
    }

    /// The driver writes no file of its own and passes no extra descriptor:
    /// the runner's whole surface is argv and stdin.
    func testDriverWritesNoFileAndNamesNoSwiftHubPath() throws {
        let source = try String(contentsOf: Self.sourceFile("Sources/Services/HubAdoptionDriver.swift"), encoding: .utf8)
        for banned in ["hubstate", "MobileHub", "write(to:", "createFile", "temporaryDirectory", "--keys-fd", "fileDescriptor"] {
            XCTAssertFalse(source.contains(banned), "the driver source contains \(banned)")
        }
    }

    func testStateReadOnlyThroughHubAdoptStatus() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        _ = await makeDriver().run()
        for call in hub.calls {
            XCTAssertEqual(Array(call.args.prefix(2)), ["hub", "adopt"])
            XCTAssertFalse(call.args.contains("--mobile-hub"), "Go derives the Swift dir itself")
        }
        XCTAssertEqual(hub.calls.first?.args, ["hub", "adopt", "--status", "--json"])
    }

    func testSettingsCarryEnabledAndAllows() async throws {
        settings = HubAdoptSettings(enabled: false, startSessionAllows: ["dev-acme": true])
        present()
        try keys.seed(hubID: "hub-acme")
        _ = await makeDriver().run()
        let call = try XCTUnwrap(hub.calls.first { $0.args.contains("--settings-stdin") })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: call.stdin) as? [String: Any])
        XCTAssertEqual(object["enabled"] as? Bool, false)
        XCTAssertEqual(object["start_session_allows"] as? [String: Bool], ["dev-acme": true])
    }

    func testSettingsDeliveredAlsoWhenResumingAtTheKeys() async throws {
        hub.state = .init(step: "done", hubID: "hub-acme", swiftState: "absent")
        try keys.seed(hubID: "hub-acme")
        _ = await makeDriver().run()
        XCTAssertGreaterThanOrEqual(delivered, 1, "a kill after the state adoption still removes the old toggle")
    }

    // MARK: - Keys

    func testNoKeysFailsBeforeAnythingIsImportedAndCreatesNothing() async {
        present(pending: true) // no Keychain items seeded
        let driver = makeDriver()
        let result = await driver.run()
        XCTAssertEqual(result, .failed(reason: "no_keys"))
        XCTAssertEqual(driver.state.retryTitle, "Retry")
        XCTAssertEqual(driver.state.setUpAgainTitle, "Set up Mobile again")
        XCTAssertEqual(keys.creations, 0, "the lookup never creates an identity")
        XCTAssertFalse(keys.has("hub-acme"))
        XCTAssertFalse(log.events.contains("swift-hub-stop"))
        XCTAssertFalse(log.events.contains { $0.hasPrefix("cancel:") }, "the recordings stay Desktop's")
        XCTAssertFalse(hub.calls.contains { $0.args.contains("--settings-stdin") || $0.args.contains("--keys-stdin") })
    }

    func testAPartialIdentityIsKeysPartial() async {
        present()
        keys.partial = true
        let result = await makeDriver().run()
        XCTAssertEqual(result, .failed(reason: "keys_partial"))
        XCTAssertNil(result.setUpAgainTitle)
        XCTAssertEqual(keys.creations, 0)
        XCTAssertFalse(hub.calls.contains { $0.args.contains("--settings-stdin") })
    }

    /// No keys, the owner confirms: Go sets the Swift state aside and the
    /// next pass finds nothing to hand over (the Go hub starts fresh).
    func testSetUpAgainSetsTheSwiftStateAsideAndEnds() async {
        present()
        let driver = makeDriver()
        _ = await driver.run()
        let result = await driver.setUpAgain()
        XCTAssertEqual(result, .notNeeded)
        XCTAssertEqual(hub.applied, ["--set-aside"])
        XCTAssertEqual(hub.calls.first { $0.args.contains("--set-aside") }?.args, ["hub", "adopt", "--set-aside", "--json"])
        XCTAssertEqual(keys.creations, 0)

        setUpLog()
        hub.state.step = "verify"
        hub.state.swiftState = "present"
        let refused = await driver.setUpAgain()
        XCTAssertEqual(refused, .failed(reason: "adoption_started"))
    }

    /// A kill right after the read-only lookup: nothing was created, the next
    /// launch looks up again and finishes.
    func testAKillAroundTheKeyLookupResumes() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        keys.killAfter = ["keychain:lookup"]
        _ = await makeDriver().run()
        keys.killAfter = []
        let result = await makeDriver().run()
        XCTAssertEqual(result, .done)
        XCTAssertEqual(keys.creations, 0)
    }

    func testDesktopItemsDeletedOnlyAfterAdopted() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        hub.keysError = "wrong_keys"
        let refused = await makeDriver().run()
        XCTAssertEqual(refused, .failed(reason: "wrong_keys"))
        XCTAssertTrue(keys.has("hub-acme"), "a refused hand-over keeps the Desktop items")
        XCTAssertFalse(log.events.contains { $0.hasPrefix("keychain:delete") })

        hub.keysError = nil
        let result = await makeDriver().run()
        XCTAssertEqual(result, .done)
        let events = log.events
        let adopted = try XCTUnwrap(events.lastIndex(of: "cli:--keys-stdin"))
        let delete = try XCTUnwrap(events.firstIndex(of: "keychain:delete:hub-acme"))
        let confirm = try XCTUnwrap(events.firstIndex(of: "cli:--confirm-deleted"))
        XCTAssertLessThan(adopted, delete)
        XCTAssertLessThan(delete, confirm)
    }

    /// `adopted` / `confirmed` count only with exit 0.
    func testANonZeroExitIsNeverAdopted() async throws {
        hub.state = .init(step: "done", hubID: "hub-acme", swiftState: "absent")
        try keys.seed(hubID: "hub-acme")
        hub.exitOne = ["--keys-stdin"]
        let result = await makeDriver().run()
        XCTAssertEqual(result, .failed(reason: "failed"))
        XCTAssertTrue(keys.has("hub-acme"), "no delete without exit 0")

        setUpLog()
        hub.state = .init(step: "done", hubID: "hub-acme", identity: "adopted", swiftState: "absent")
        hub.exitOne = ["--confirm-deleted"]
        let confirm = await makeDriver().run()
        XCTAssertEqual(confirm, .failed(reason: "failed"))
    }

    func testCrashBeforeConfirmRetriesTheDeleteNextLaunch() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        hub.killAfter = ["--keys-stdin"] // the app dies right after the Go hub adopted
        _ = await makeDriver().run()
        XCTAssertEqual(hub.state.identity, "adopted")
        XCTAssertTrue(keys.has("hub-acme"), "killed before the delete")

        hub.killAfter = []
        setUpLog()
        let result = await makeDriver().run()
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.events, [
            "cli:--status", "restart-wait", "restart-settled", "cli:--status", "keychain:delete:hub-acme", "cli:--confirm-deleted"
        ])
        XCTAssertEqual(hub.state.identity, "confirmed")
    }

    func testAnEmptyHubIDOnTheDeletePathNeverConfirms() async {
        hub.state = .init(step: "done", hubID: "", identity: "adopted", swiftState: "absent")
        let result = await makeDriver().run()
        XCTAssertEqual(result, .failed(reason: "no_hub_id"))
        XCTAssertFalse(hub.calls.contains { $0.args.contains("--confirm-deleted") })
        XCTAssertFalse(log.events.contains { $0.hasPrefix("keychain:delete") })
    }

    // MARK: - Failures

    func testFailureShowsRetryAndKeepsTheHubOff() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        hub.adoptError = "swift_schema"
        let driver = makeDriver()
        let result = await driver.run()
        XCTAssertEqual(result, .failed(reason: "swift_schema"))
        XCTAssertEqual(driver.state, result)
        XCTAssertEqual(driver.state.retryTitle, "Retry")
        XCTAssertTrue(log.events.contains("swift-hub-stop"), "the Swift hub was stopped and nothing started it again")
        XCTAssertEqual(delivered, 0)

        hub.adoptError = nil
        let retried = await driver.retry()
        XCTAssertEqual(retried, .done)
        XCTAssertEqual(log.events.filter { $0 == "restart-wait" }.count, 1, "Retry does not wait for the restart again")
    }

    /// A permanent adoption failure gives the cancelled phone recordings back
    /// to Desktop; a transient one keeps them for Retry.
    func testAPermanentFailureReleasesThePhoneRecordings() async throws {
        present(pending: true)
        try keys.seed(hubID: "hub-acme")
        hub.adoptError = "swift_schema"
        _ = await makeDriver().run()
        XCTAssertTrue(log.events.contains("released:rec_1.m4a"))
        XCTAssertFalse(log.events.contains { $0.hasPrefix("adopted:") })

        setUpLog()
        present(pending: true)
        hub.adoptError = "locked"
        _ = await makeDriver().run()
        XCTAssertFalse(log.events.contains { $0.hasPrefix("released:") }, "Retry will take them")
    }

    func testEveryHandOverFailureClass() async throws {
        let classes = ["wrong_keys", "bad_keys", "no_sidecar", "adoption_unfinished", "cleanup_failed",
                       "keychain_refused", "locked", "failed"]
        for errorClass in classes {
            setUpLog()
            hub.state = .init(step: "done", hubID: "hub-acme", swiftState: "absent")
            try keys.seed(hubID: "hub-acme")
            hub.keysError = errorClass
            let driver = makeDriver()
            let result = await driver.run()
            XCTAssertEqual(result, .failed(reason: errorClass), errorClass)
            XCTAssertEqual(driver.state.retryTitle, "Retry", errorClass)
            XCTAssertTrue(keys.has("hub-acme"), errorClass)
            XCTAssertFalse(log.events.contains("cli:--confirm-deleted"), errorClass)
        }
        for errorClass in ["not_adopted", "locked", "failed"] {
            setUpLog()
            hub.state = .init(step: "done", hubID: "hub-acme", identity: "adopted", swiftState: "absent")
            hub.confirmError = errorClass
            let result = await makeDriver().run()
            XCTAssertEqual(result, .failed(reason: errorClass), "confirm: \(errorClass)")
        }
    }

    func testEveryAdoptFailureClass() async throws {
        for errorClass in ["swift_schema", "swift_corrupt", "swift_hub_id", "swift_busy", "locked", "failed"] {
            setUpLog()
            present()
            try keys.seed(hubID: "hub-acme")
            hub.adoptError = errorClass
            let result = await makeDriver().run()
            XCTAssertEqual(result, .failed(reason: errorClass), errorClass)
            XCTAssertFalse(log.events.contains("cli:--keys-stdin"), errorClass)
        }
    }

    func testKeychainErrorsFail() async throws {
        hub.state = .init(step: "done", hubID: "hub-acme", swiftState: "absent")
        keys.readError = true
        let result = await makeDriver().run()
        XCTAssertEqual(result, .failed(reason: "keychain_unavailable"))
        XCTAssertFalse(hub.calls.contains { $0.args.contains("--keys-stdin") })

        setUpLog()
        hub.state = .init(step: "done", hubID: "hub-acme", identity: "adopted", swiftState: "absent")
        keys.deleteError = true
        let cleanup = await makeDriver().run()
        XCTAssertEqual(cleanup, .failed(reason: "keychain_unavailable"))
        XCTAssertFalse(hub.calls.contains { $0.args.contains("--confirm-deleted") }, "never confirmed while the items stay")
    }

    func testNoCLIOrUnreadableStatusFails() async {
        let none = await makeDriver(useRunner: false).run()
        XCTAssertEqual(none, .failed(reason: "no_cli"))
        hub.garbleStatus = true
        let garbled = await makeDriver().run()
        XCTAssertEqual(garbled, .failed(reason: "failed"))
    }

    func testAMissingHubIDFails() async {
        hub.state = .init(step: "done", hubID: "", swiftState: "absent")
        let result = await makeDriver().run()
        XCTAssertEqual(result, .failed(reason: "no_hub_id"))
    }

    /// A `hub adopt` child that hangs past the step deadline is cancelled
    /// (the live runner terminates its group) and the step fails `timeout`;
    /// Retry starts a fresh pass.
    func testAHangingCallTimesOutAndRetryStartsFresh() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        deadline = .milliseconds(100)
        hub.hangOn = ["--settings-stdin"]
        let driver = makeDriver()
        let result = await driver.run()
        XCTAssertEqual(result, .failed(reason: "timeout"))
        XCTAssertEqual(hub.cancelled, ["--settings-stdin"], "the stuck call was cancelled, not left running")

        hub.hangOn = []
        let statusReads = hub.calls.filter { $0.args.contains("--status") }.count
        let retried = await driver.retry()
        XCTAssertEqual(retried, .done)
        XCTAssertGreaterThan(hub.calls.filter { $0.args.contains("--status") }.count, statusReads, "a fresh pass reads again")
    }

    // MARK: - The live runner

    private func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watchtower")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// stdout and the exit code reach the driver even on a refusal, and
    /// stdin arrives whole.
    func testTheLiveRunnerReadsStdoutOnANonZeroExit() async throws {
        let url = try script(#"read -r line; printf '{"identity":"%s"}' "$line"; exit 1"#)
        let out = try await ProcessHubAdoptRunner(binaryPath: url.path).run(["hub", "adopt"], stdin: Data("wrong_keys\n".utf8))
        XCTAssertEqual(out.exitCode, 1)
        XCTAssertEqual(String(bytes: out.stdout, encoding: .utf8), #"{"identity":"wrong_keys"}"#)
    }

    /// A cancelled run (the step deadline) terminates the child's whole
    /// process group at once, its own children included.
    func testTheLiveRunnerTerminatesAHangingChildGroup() async throws {
        let url = try script("sleep 60 & wait")
        let runner = ProcessHubAdoptRunner(binaryPath: url.path)
        let run = Task { try await runner.run(["hub", "adopt", "--status", "--json"], stdin: Data()) }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        run.cancel()
        let out = try await run.value
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "terminated, not waited out")
        XCTAssertNotEqual(out.exitCode, 0)
    }

    // MARK: - Kills and cancels

    /// A kill at every point of the hand-over (the runner or the Keychain
    /// throws as a dying app would): the next launch reads the status and
    /// finishes, with one state adoption and one key hand-over in all.
    func testAKillBetweenEveryStepResumesAtTheNextLaunch() async throws {
        let points: [(String, @MainActor (FakeAdoptHub, FakeHubKeyStore) -> Void)] = [
            ("after the key lookup", { _, keys in keys.killAfter = ["keychain:lookup"] }),
            ("after the stop and the cancel", { hub, _ in hub.killBefore = ["--settings-stdin"] }),
            ("after the state adoption", { hub, _ in hub.killAfter = ["--settings-stdin"] }),
            ("before the keys", { hub, _ in hub.killBefore = ["--keys-stdin"] }),
            ("after the keys", { hub, _ in hub.killAfter = ["--keys-stdin"] }),
            ("after the delete", { _, keys in keys.killAfter = ["keychain:delete"] }),
            ("before the confirm", { hub, _ in hub.killBefore = ["--confirm-deleted"] }),
            ("after the confirm", { hub, _ in hub.killAfter = ["--confirm-deleted"] })
        ]
        for (point, kill) in points {
            setUpLog()
            present(pending: true)
            try keys.seed(hubID: "hub-acme")
            kill(hub, keys)
            let first = await makeDriver().run()
            XCTAssertNotEqual(first, .notNeeded, point)

            (hub.killAfter, hub.killBefore, keys.killAfter) = ([], [], [])
            let result = await makeDriver().run()
            XCTAssertEqual(result, .done, "killed \(point)")
            XCTAssertEqual(hub.state.identity, "confirmed", point)
            XCTAssertEqual(hub.applied.filter { $0 == "--settings-stdin" }.count, 1, "one state adoption: \(point)")
            XCTAssertEqual(hub.applied.filter { $0 == "--keys-stdin" }.count, 1, "one hand-over: \(point)")
            XCTAssertFalse(keys.has("hub-acme"), point)
            XCTAssertEqual(keys.creations, 0, point)
        }
    }

    func testCancelRepeatsAfterAnInterruption() async throws {
        present(pending: true)
        try keys.seed(hubID: "hub-acme")
        hub.killBefore = ["--settings-stdin"] // the app dies after the cancel, before hub adopt ran
        _ = await makeDriver().run()
        XCTAssertEqual(log.events.filter { $0.hasPrefix("cancel:") }, ["cancel:rec_1.m4a"])

        hub.killBefore = []
        setUpLog()
        _ = await makeDriver().run()
        let events = log.events
        let cancel = try XCTUnwrap(events.firstIndex(of: "cancel:rec_1.m4a"), "the next launch cancels again")
        let adopt = try XCTUnwrap(events.firstIndex(of: "cli:--settings-stdin"))
        XCTAssertLessThan(cancel, adopt)
    }

    func testInFlightTranscriptionIsCancelledBeforeAdopt() async throws {
        present(pending: true)
        try keys.seed(hubID: "hub-acme")
        var running = true
        let driver = makeDriver { [log] _ in
            await Task.yield()
            running = false
            log?.append("transcription-ended")
        }
        hub.onAdopt = { XCTAssertFalse(running, "hub adopt spawned while a job of a listed file still ran") }
        _ = await driver.run()
        let events = log.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "transcription-ended")),
                          try XCTUnwrap(events.firstIndex(of: "cli:--settings-stdin")))
    }

    func testAJoinedRunIsNeverDoubled() async throws {
        present()
        try keys.seed(hubID: "hub-acme")
        let driver = makeDriver()
        async let one = driver.run()
        async let two = driver.run()
        let results = await [one, two]
        XCTAssertEqual(results, [.done, .done])
        XCTAssertEqual(hub.applied.filter { $0 == "--settings-stdin" }.count, 1)
    }

    // MARK: - Helpers

    private func setUpLog() {
        log.reset()
        hub.calls = []
        hub.adoptError = nil
        hub.keysError = nil
        hub.confirmError = nil
        hub.garbleStatus = false
        hub.applied = []
        hub.exitOne = []
        (hub.killAfter, hub.killBefore, keys.killAfter) = ([], [], [])
        (keys.readError, keys.deleteError, keys.partial) = (false, false, false)
    }

    static func sourceFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
