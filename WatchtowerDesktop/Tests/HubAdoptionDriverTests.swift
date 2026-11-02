import CryptoKit
import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The Desktop's hand-over of Mobile to the Go hub (go hub plan 3 Task 22,
/// spec §12.1–§12.2): state through `hub adopt --status`, then the settings,
/// then the keys on stdin, then the Desktop items deleted and confirmed.
@MainActor
final class HubAdoptionDriverTests: XCTestCase {
    private var log: AdoptionLog!
    private var hub: FakeAdoptHub!
    private var keys: FakeHubKeyStore!
    private var restartSettled = true
    private var restartWaiters: [CheckedContinuation<Void, Never>] = []
    private var settings = HubAdoptSettings(enabled: true, startSessionAllows: [:])
    private var delivered = 0

    override func setUp() async throws {
        log = AdoptionLog()
        hub = FakeAdoptHub(log: log)
        keys = FakeHubKeyStore(log: log)
        restartSettled = true
        restartWaiters = []
        delivered = 0
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
            stopSwiftHub: { [log] in
                log?.append("swift-hub-stop")
                await Task.yield()
                log?.append("swift-storage-closed")
            },
            cancelPhoneRecordings: { [log] names in
                log?.append("cancel:\(names.joined(separator: ","))")
                await cancel?(names)
            },
            runner: useRunner ? hub : nil,
            keyStore: keys,
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

    // MARK: - The whole hand-over

    func testHandOverRunsStateThenKeysThenCleanup() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present",
                          pending: [.init(uploadID: "u-1", audioName: "rec_1.m4a")])
        try keys.seed(hubID: "hub-acme")

        let result = await makeDriver().run()

        XCTAssertEqual(result, .done)
        XCTAssertEqual(hub.state.identity, "confirmed")
        XCTAssertEqual(log.events, [
            "restart-wait", "restart-settled", "cli:--status", "swift-hub-stop", "swift-storage-closed",
            "cancel:rec_1.m4a", "cli:--settings-stdin", "cli:--status", "keychain:get:hub-acme", "cli:--keys-stdin",
            "keychain:delete:hub-acme", "cli:--confirm-deleted"
        ])
        XCTAssertEqual(delivered, 1, "the Desktop's copy of the toggle goes once the Go hub took it")
        XCTAssertFalse(keys.has("hub-acme"))
    }

    func testAdoptionStopsTheSwiftHubBeforeHubAdopt() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
        try keys.seed(hubID: "hub-acme")
        _ = await makeDriver().run()
        let events = log.events
        let stop = try XCTUnwrap(events.firstIndex(of: "swift-hub-stop"))
        let closed = try XCTUnwrap(events.firstIndex(of: "swift-storage-closed"))
        let adopt = try XCTUnwrap(events.firstIndex(of: "cli:--settings-stdin"))
        XCTAssertLessThan(stop, closed)
        XCTAssertLessThan(closed, adopt, "the storage is closed before the first adopting hub adopt starts")
    }

    func testAdoptionWaitsForTheHostRestartStep() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
        try keys.seed(hubID: "hub-acme")
        restartSettled = false
        let driver = makeDriver()
        let run = Task { await driver.run() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(log.events, ["restart-wait"], "nothing runs while the restart waits for Continue")
        XCTAssertEqual(driver.state, .checking)

        settleRestart()
        let result = await run.value
        XCTAssertEqual(result, .done)
        XCTAssertEqual(Array(log.events.prefix(3)), ["restart-wait", "restart-settled", "cli:--status"])
    }

    func testRunsAfterTheRestartStep() async throws {
        hub.state = .init(swiftState: "absent")
        _ = await makeDriver().run()
        XCTAssertEqual(Array(log.events.prefix(3)), ["restart-wait", "restart-settled", "cli:--status"])
    }

    func testNoSwiftStateSkips() async {
        for swift in ["absent", "ignored"] {
            setUpLog()
            hub.state = .init(hubID: "hub-acme", swiftState: swift)
            let result = await makeDriver().run()
            XCTAssertEqual(result, .notNeeded, swift)
            XCTAssertEqual(log.events, ["restart-wait", "restart-settled", "cli:--status"], swift)
        }
    }

    // MARK: - Stdin

    func testKeysOnlyOnStdin() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
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

    /// The driver writes no file of its own and passes no extra descriptor:
    /// the runner's whole surface is argv and stdin.
    func testDriverWritesNoFileAndNamesNoSwiftHubPath() throws {
        let source = try String(contentsOf: Self.sourceFile("Sources/Services/HubAdoptionDriver.swift"), encoding: .utf8)
        for banned in ["hubstate", "MobileHub", "write(to:", "createFile", "temporaryDirectory", "--keys-fd", "fileDescriptor"] {
            XCTAssertFalse(source.contains(banned), "the driver source contains \(banned)")
        }
    }

    func testStateReadOnlyThroughHubAdoptStatus() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
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
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
        try keys.seed(hubID: "hub-acme")
        _ = await makeDriver().run()
        let call = try XCTUnwrap(hub.calls.first { $0.args.contains("--settings-stdin") })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: call.stdin) as? [String: Any])
        XCTAssertEqual(object["enabled"] as? Bool, false)
        XCTAssertEqual(object["start_session_allows"] as? [String: Bool], ["dev-acme": true])
    }

    // MARK: - Keys

    func testAFreshlyCreatedIdentityIsNoKeys() async {
        hub.state = .init(hubID: "hub-acme", swiftState: "present") // no Keychain items seeded
        let driver = makeDriver()
        let result = await driver.run()
        XCTAssertEqual(result, .failed(reason: "no_keys"))
        XCTAssertEqual(driver.state.retryTitle, "Retry")
        XCTAssertFalse(keys.has("hub-acme"), "the fresh item is deleted again")
        XCTAssertFalse(hub.calls.contains { $0.args.contains("--keys-stdin") }, "never handed over")
        XCTAssertEqual(hub.state.identity, "none")
    }

    func testDesktopItemsDeletedOnlyAfterAdopted() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
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

    func testCrashBeforeConfirmRetriesTheDeleteNextLaunch() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
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
            "restart-wait", "restart-settled", "cli:--status", "keychain:delete:hub-acme", "cli:--confirm-deleted"
        ])
        XCTAssertEqual(hub.state.identity, "confirmed")
    }

    func testAMissingConfirmDeletesAgainAndConfirms() async throws {
        hub.state = .init(step: "done", hubID: "hub-acme", identity: "adopted", swiftState: "absent")
        let result = await makeDriver().run()
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.events.suffix(2), ["keychain:delete:hub-acme", "cli:--confirm-deleted"])
    }

    // MARK: - Failures

    func testFailureShowsRetryAndKeepsTheHubOff() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
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

    /// Every error class of the key hand-over and the confirm ends in
    /// `.failed(class)` with Retry; the Desktop items stay unless the Go hub
    /// adopted the identity.
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
            hub.keysError = nil
            hub.confirmError = errorClass
            let result = await makeDriver().run()
            XCTAssertEqual(result, .failed(reason: errorClass), "confirm: \(errorClass)")
        }
    }

    func testEveryAdoptFailureClass() async throws {
        for errorClass in ["swift_schema", "swift_corrupt", "swift_hub_id", "swift_busy", "locked", "failed"] {
            setUpLog()
            hub.state = .init(hubID: "hub-acme", swiftState: "present")
            hub.adoptError = errorClass
            let result = await makeDriver().run()
            XCTAssertEqual(result, .failed(reason: errorClass), errorClass)
            XCTAssertFalse(log.events.contains { $0.hasPrefix("keychain") }, errorClass)
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
        keys.readError = false
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

    // MARK: - Kills and cancels

    /// A kill at every point of the hand-over (the runner or the Keychain
    /// throws as a dying app would): the next launch reads the status and
    /// finishes, with one state adoption and one key hand-over in all.
    func testAKillBetweenEveryStepResumesAtTheNextLaunch() async throws {
        let points: [(String, @MainActor (FakeAdoptHub, FakeHubKeyStore) -> Void)] = [
            ("after the stop and the cancel", { hub, _ in hub.killBefore = ["--settings-stdin"] }),
            ("after the state adoption", { hub, _ in hub.killAfter = ["--settings-stdin"] }),
            ("after the Keychain read", { _, keys in keys.killAfter = ["keychain:get"] }),
            ("before the keys", { hub, _ in hub.killBefore = ["--keys-stdin"] }),
            ("after the keys", { hub, _ in hub.killAfter = ["--keys-stdin"] }),
            ("after the delete", { _, keys in keys.killAfter = ["keychain:delete"] }),
            ("before the confirm", { hub, _ in hub.killBefore = ["--confirm-deleted"] }),
            ("after the confirm", { hub, _ in hub.killAfter = ["--confirm-deleted"] })
        ]
        for (point, kill) in points {
            setUpLog()
            hub.state = .init(hubID: "hub-acme", swiftState: "present",
                              pending: [.init(uploadID: "u-1", audioName: "rec_1.m4a")])
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
        }
    }

    func testCancelRepeatsAfterAnInterruption() async throws {
        hub.state = .init(hubID: "hub-acme", swiftState: "present",
                          pending: [.init(uploadID: "u-1", audioName: "rec_1.m4a")])
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
        hub.state = .init(hubID: "hub-acme", swiftState: "present",
                          pending: [.init(uploadID: "u-1", audioName: "rec_1.m4a")])
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
        hub.state = .init(hubID: "hub-acme", swiftState: "present")
        try keys.seed(hubID: "hub-acme")
        let driver = makeDriver()
        async let one = driver.run()
        async let two = driver.run()
        let results = await [one, two]
        XCTAssertEqual(results, [.done, .done])
        XCTAssertEqual(hub.applied.filter { $0 == "--settings-stdin" }.count, 1)
    }

    // MARK: - AppState

    /// The live stop seam: the Swift hub an older launch left running stops,
    /// its storage closes, and nothing builds it again in this run.
    func testStopSwiftHubForAdoptionClosesTheStorageAndNeverRebuilds() async throws {
        let suite = "WatchtowerDesktopTests.hubAdoption"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let sidecar = try HubSyncState.inMemoryPerHub()
        let appState = AppState { [:] }
        appState.mobileSyncDefaults = defaults
        var closed = 0
        appState.makeMobileHubStorage = {
            var storage = try MobileHubStorage.stub(transport: StubHubTransport(), sidecar: sidecar)
            storage.close = { closed += 1 }
            return storage
        }
        appState.initMobileHub(dbPool: pool)
        let hub = try XCTUnwrap(appState.mobileHub)
        await awaitHubCondition("the Swift hub runs") { hub.status == .running }

        await appState.stopSwiftHubForAdoption()

        XCTAssertEqual(hub.status, .off)
        XCTAssertEqual(closed, 1, "its storage is closed before the stop returns")
        XCTAssertNil(appState.mobileHub)
        XCTAssertTrue(appState.swiftHubRetired)
        appState.setMobileSyncEnabled(true)
        appState.initMobileHub(dbPool: pool)
        XCTAssertNil(appState.mobileHub, "never two hubs: nothing builds the Swift hub again")
    }

    /// `isMobileSyncEnabled` reads `hub status --json` (through HubCenter):
    /// off for no reason or switched off is off; off for another reason is
    /// still the owner's on.
    func testMobileSyncEnabledReadsTheHubStatus() {
        let table: [(WatchtowerCore.HubStatus, Bool)] = [
            (.init(state: "running"), true),
            (.init(state: "starting"), true),
            (.init(state: "paused", reason: "needs_relay"), true),
            (.init(state: "off", reason: "locked"), true),
            (.init(state: "off"), false),
            (.init(state: "off", reason: "disabled"), false),
            (.init(state: "off", reason: "policy_off"), false)
        ]
        for (status, on) in table {
            XCTAssertEqual(AppState.hubIsOn(status), on, "\(status)")
        }
    }

    func testSettingsAreTheStoredToggleReadOnce() throws {
        let suite = "WatchtowerDesktopTests.hubAdoptionSettings"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let appState = AppState { [:] }
        appState.mobileSyncDefaults = defaults
        XCTAssertEqual(appState.hubAdoptSettings(), HubAdoptSettings(enabled: false, startSessionAllows: [:]))
        defaults.set(true, forKey: Constants.mobileSyncEnabledKey)
        XCTAssertEqual(appState.hubAdoptSettings(), HubAdoptSettings(enabled: true, startSessionAllows: [:]))
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
        (hub.killAfter, hub.killBefore, keys.killAfter) = ([], [], [])
        (keys.readError, keys.deleteError) = (false, false)
    }

    static func sourceFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}

// MARK: - Fakes

/// The order of everything the driver did, across its seams.
final class AdoptionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ event: String) { lock.withLock { storage.append(event) } }
    func reset() { lock.withLock { storage = [] } }
    var events: [String] { lock.withLock { storage } }
}

/// The app was killed at this point: what ran before it stays done.
struct FakeKill: Error {}

/// A Go hub behind `watchtower hub adopt`: answers each verb from its state,
/// as cmd/hub_adopt.go does (JSON on stdout even on a refusal, exit 1).
final class FakeAdoptHub: HubAdoptRunning, @unchecked Sendable {
    struct State {
        var step = ""
        var hubID = ""
        var identity = "none"
        var swiftState = "absent"
        var pending: [HubAdoptStatus.PendingRecording] = []
    }

    struct Call {
        let args: [String]
        let stdin: Data
    }

    private let lock = NSLock()
    private let log: AdoptionLog
    var state = State()
    var calls: [Call] = []
    /// Verbs whose change was applied (not just called).
    var applied: [String] = []
    var adoptError: String?
    var keysError: String?
    var confirmError: String?
    var garbleStatus = false
    /// Verbs after whose change the app dies (the runner throws).
    var killAfter: Set<String> = []
    /// Verbs the app dies before starting.
    var killBefore: Set<String> = []
    var onAdopt: (@MainActor () -> Void)?

    init(log: AdoptionLog) { self.log = log }

    func run(_ args: [String], stdin: Data) async throws -> HubAdoptOutput {
        let verb = args.first { $0.hasPrefix("--") && $0 != "--json" } ?? ""
        if killBefore.contains(verb) { throw FakeKill() }
        if verb == "--settings-stdin", let onAdopt { await onAdopt() }
        lock.withLock { calls.append(Call(args: args, stdin: stdin)) }
        log.append("cli:\(verb)")
        let (object, code) = answer(verb)
        if killAfter.contains(verb) { throw FakeKill() }
        let data = garbleStatus && verb == "--status" ? Data("not json".utf8)
            : try JSONSerialization.data(withJSONObject: object)
        return HubAdoptOutput(stdout: data, exitCode: code)
    }

    private func answer(_ verb: String) -> ([String: Any], Int32) {
        switch verb {
        case "--status":
            return ([
                "step": state.step, "imported": ["devices": 0, "jobs": 0, "skipped": 0, "audio_left": 0],
                "error": "", "hub_id": state.hubID, "identity": state.identity, "swift_state": state.swiftState,
                "pending_recordings": state.pending.map { ["upload_id": $0.uploadID, "audio_name": $0.audioName] }
            ], 0)
        case "--settings-stdin":
            if let adoptError { return (["step": "verify", "error": adoptError], 1) }
            if state.step == "done" { return (["step": "done", "error": "already_adopted"], 1) }
            (state.step, state.swiftState, state.pending) = ("done", "absent", [])
            applied.append(verb)
            return (["step": "done", "error": ""], 0)
        case "--keys-stdin":
            if let keysError { return (["identity": keysError], 1) }
            guard state.step == "done" else { return (["identity": "adoption_unfinished"], 1) }
            if state.identity != "adopted", state.identity != "confirmed" { applied.append(verb) }
            if state.identity != "confirmed" { state.identity = "adopted" }
            return (["identity": "adopted"], 0)
        case "--confirm-deleted":
            if let confirmError { return (["identity": confirmError], 1) }
            guard state.identity == "adopted" || state.identity == "confirmed" else { return (["identity": "not_adopted"], 1) }
            state.identity = "confirmed"
            return (["identity": "confirmed"], 0)
        default:
            return (["error": "usage"], 1)
        }
    }
}

/// The Kit key store over an in-memory keychain, with its calls logged.
final class FakeHubKeyStore: HubKeyStore, @unchecked Sendable {
    private let inner = InMemoryHubKeyStore()
    private let log: AdoptionLog
    private let lock = NSLock()
    private var present: Set<String> = []
    var readError = false
    var deleteError = false
    var killAfter: Set<String> = []

    init(log: AdoptionLog) { self.log = log }

    @discardableResult
    func seed(hubID: String) throws -> HubIdentityKeys {
        let keys = try inner.hubIdentity(hubID: hubID).keys
        lock.withLock { _ = present.insert(hubID) }
        return keys
    }

    func has(_ hubID: String) -> Bool { lock.withLock { present.contains(hubID) } }

    func hubIdentity(hubID: String) throws -> (keys: HubIdentityKeys, created: Bool) {
        log.append("keychain:get:\(hubID)")
        if readError { throw KeyStoreError.locked }
        let loaded = try inner.hubIdentity(hubID: hubID)
        lock.withLock { _ = present.insert(hubID) }
        if killAfter.contains("keychain:get") { throw FakeKill() }
        return loaded
    }

    func deleteHubIdentity(hubID: String) throws {
        log.append("keychain:delete:\(hubID)")
        if deleteError { throw KeyStoreError.locked }
        try inner.deleteHubIdentity(hubID: hubID)
        lock.withLock { _ = present.remove(hubID) }
        if killAfter.contains("keychain:delete") { throw FakeKill() }
    }
}
