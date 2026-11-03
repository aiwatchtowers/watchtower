import Foundation
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Settings → Mobile over `watchtower hub …` (go hub plan 3 Task 23). The
/// behaviours of the deleted `MobileSettingsViewModelTests` /
/// `MobileSettingsViewTests` that still hold are pinned here, on the CLI.
@MainActor
final class MobileSettingsModelTests: XCTestCase {
    typealias Model = MobileSettingsModel
    private var cli: ScriptedHubCLI!
    private var defaults: UserDefaults!
    private let suite = "WatchtowerDesktopTests.mobileSettingsModel"

    override func setUp() async throws {
        cli = ScriptedHubCLI()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private final class Adoption: MobileAdoptionSource {
        var adoptionState: HubAdoptionState
        var retries = 0
        init(_ state: HubAdoptionState) { adoptionState = state }
        func retryHandOver() async {
            retries += 1
            adoptionState = .done
        }

        func setUpHandOverAgain() async {}
    }

    private func makeModel(
        adoption: (any MobileAdoptionSource)? = nil,
        streamer: (any HubPairStreaming)? = nil,
        corp: Bool = false,
        opened: ((URL) -> Void)? = nil,
        now: Date = Date(),
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in }
    ) -> Model {
        Model(
            cli: cli, adoption: adoption, pairStreamer: streamer, showsCorpNotice: corp, defaults: defaults,
            openInFinder: { opened?($0) }, now: { now }, sleep: sleep
        )
    }

    // MARK: - Today's iCloud lines (the Swift hub's tab, now from `hub status` `cloudkit`)

    func testICloudLinesAsToday() async throws {
        XCTAssertEqual(Model.needsSignedBuild, "Needs a signed build")
        XCTAssertEqual(Model.slowingLine, "iCloud is slowing sync down")
        XCTAssertEqual(Model.accountLine("no_account"), "Mobile isn't available on this Mac: iCloud is off.")
        XCTAssertEqual(Model.accountLine("restricted"),
                       "Mobile isn't available on this Mac: iCloud is restricted by your organization.")
        XCTAssertEqual(Model.accountLine("temporarily_unavailable"),
                       "Mobile isn't available on this Mac: iCloud account temporarily unavailable")
        XCTAssertNil(Model.accountLine("available"))
        XCTAssertNil(Model.accountLine(""))
        XCTAssertNil(Model.accountLine("no_entitlement"), "Needs a signed build says it")

        let now = try XCTUnwrap(MobileHubCLI.date("2026-11-02T10:01:01Z"))
        cli.phones("[]")
        cli.status(#"{"state":"running","bridge":"running","cloudkit":"#
            + #"{"account":"no_account","throttled_since":"2026-11-02T10:00:00Z","signed":true}}"#)
        let model = makeModel(now: now)
        await model.load()
        XCTAssertFalse(model.showsNeedsSignedBuild)
        XCTAssertEqual(model.accountLine, "Mobile isn't available on this Mac: iCloud is off.")
        XCTAssertTrue(model.showsSlowingLine, "61 s of throttling")

        let early = makeModel(now: try XCTUnwrap(MobileHubCLI.date("2026-11-02T10:00:59Z")))
        await early.load()
        XCTAssertFalse(early.showsSlowingLine, "59 s is not yet")

        // Off: an unsigned build still says so; the account and the throttle are a running hub's.
        cli.status(#"{"state":"off","reason":"disabled","bridge":"unavailable","cloudkit":"#
            + #"{"account":"no_account","throttled_since":"2026-11-02T10:00:00Z","signed":false}}"#)
        await model.load()
        XCTAssertTrue(model.showsNeedsSignedBuild)
        XCTAssertNil(model.accountLine)
        XCTAssertFalse(model.showsSlowingLine)

        // A bridge that reports the entitlement missing says it too.
        cli.status(#"{"state":"running","bridge":"running","cloudkit":{"account":"no_entitlement","throttled_since":"","signed":false}}"#)
        await model.load()
        XCTAssertTrue(model.showsNeedsSignedBuild)

        // No status file yet (no daemon wrote one): signed false is not a fact, so no line.
        cli.status(#"{"state":"off","reason":"disabled","bridge":"","cloudkit":{"account":"","throttled_since":"","signed":false}}"#)
        await model.load()
        XCTAssertFalse(model.showsNeedsSignedBuild)

        // An older CLI without the block shows none of them.
        cli.status(#"{"state":"running"}"#)
        await model.load()
        XCTAssertFalse(model.showsNeedsSignedBuild)
        XCTAssertNil(model.accountLine)
    }

    /// A Go hub ran first and a Swift hub's state appeared beside it (ask
    /// #949): off with its own sentence and no action.
    func testSwiftBesideGoIsItsOwnState() async {
        cli.status(#"{"state":"off","reason":"swift_beside_go"}"#)
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.state, .off(reason: "swift_beside_go"))
        XCTAssertEqual(Model.offCopy("swift_beside_go"), Model.OffCopy(
            title: "Mobile is off",
            detail: "This Mac has phone data from two Watchtower setups. Remove one of them to turn Mobile back on.",
            showsToggle: false, toggleOn: false, managed: false
        ))
        XCTAssertFalse(model.canLink)
    }

    /// Retry goes through Desktop's phone recording queue, which claims and
    /// transcribes; no CLI claim of its own.
    func testRetryGoesThroughTheRecordingQueue() async {
        runningWith()
        var queued: [String] = []
        var busyWhileQueued = false
        var model: Model!
        model = Model(cli: cli, retryRecording: { id in
            queued.append(id)
            busyWhileQueued = model.busy.contains(.recording(id))
        }, defaults: defaults)
        await model.load()
        await model.retryRecording("u-7")
        XCTAssertEqual(queued, ["u-7"])
        XCTAssertTrue(busyWhileQueued, "the row is busy while it goes")
        XCTAssertTrue(model.busy.isEmpty)
        XCTAssertTrue(cli.writes.isEmpty)
    }

    /// Every status reason reads as an owner's sentence, never its
    /// identifier; a starting hub with a reason shows the reason, not
    /// "Starting…" forever; start-type failures are errors (red).
    func testEveryReasonHasOwnerCopy() async {
        let errors = ["start_failed", "sidecar_unreadable", "run_dir_unusable", "bridge_unavailable"]
        let warnings = ["locked", "relay_unreachable", "not_vouched", "not_admitted", "vouch_revoked", "needs_relay",
                        "no_relay_origin", "not_test_workspace", "something_newer"]
        for reason in errors + warnings {
            let line = Model.reasonLine(reason)
            XCTAssertNotNil(line, reason)
            XCTAssertFalse(line?.text.contains("_") ?? true, "\(reason) shows an identifier")
            XCTAssertEqual(line?.tone, errors.contains(reason) ? .error : .warning, reason)
            XCTAssertEqual(Model.hubLine(state: "starting", reason: reason), line, "starting with \(reason)")
            XCTAssertFalse(Model.offCopy(reason).detail?.contains("_") ?? false, reason)
        }
        XCTAssertEqual(Model.reasonLine("start_failed")?.text, "Mobile couldn't start. It tries again in a moment.")
        XCTAssertEqual(Model.reasonLine("locked")?.text, "Another Watchtower process runs Mobile on this Mac.")
        XCTAssertEqual(Model.reasonLine("relay_unreachable")?.text, "Relay can't be reached right now. Phones on Relay wait.")
        XCTAssertEqual(Model.reasonLine("not_vouched")?.text, "Relay is waiting for a linked phone to vouch for this Mac.")
        XCTAssertEqual(Model.reasonLine("not_admitted")?.text,
                       "Relay hasn't admitted this Mac yet: a phone with a Relay subscription has to link it.")
        XCTAssertEqual(Model.reasonLine("vouch_revoked")?.text,
                       "The phone that vouched for this Mac on Relay took it back. Link a phone with Relay again.")
        XCTAssertEqual(Model.reasonLine("bridge_unavailable")?.text,
                       "Mobile can't run: this build can't use iCloud and has no Relay set up.")
        XCTAssertEqual(Model.reasonLine("something_newer")?.text, Model.unknownReason)
        XCTAssertNil(Model.reasonLine(""))
        XCTAssertEqual(Model.hubLine(state: "starting", reason: ""), Model.HubLine(text: "Starting…", tone: .neutral))

        cli.status(#"{"state":"starting","reason":"start_failed"}"#)
        cli.phones("[]")
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.hubLine, Model.HubLine(text: "Mobile couldn't start. It tries again in a moment.", tone: .error))
        XCTAssertFalse(model.canLink)
    }

    /// The owner's off deletes what the hub published: today's off-delete
    /// line while it is pending or failed, none once done or while on.
    func testOffDeleteLine() async {
        XCTAssertEqual(Model.offDeleteLine("pending"), "Deleting what this Mac synced to iCloud…")
        XCTAssertEqual(Model.offDeleteLine("failed"),
                       "This Mac's synced data was only partly deleted. That finishes while Mobile stays off.")
        XCTAssertNil(Model.offDeleteLine("ok"))
        XCTAssertNil(Model.offDeleteLine(nil))
        cli.status(#"{"state":"off","reason":"disabled","off_delete":{"state":"failed","at":"2026-11-02T10:00:00Z"}}"#)
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.offDeleteLine, Model.offDeleteLine("failed"))
        cli.status(#"{"state":"off","reason":"disabled","off_delete":{"state":"ok","at":"2026-11-02T10:00:00Z"}}"#)
        await model.load()
        XCTAssertNil(model.offDeleteLine)
    }

    /// Link a phone needs a usable iCloud account while CloudKit carries the
    /// hub: no account or a restricted one hides it, as today; Relay links without it.
    func testLinkNeedsAUsableAccountOnCloudKit() async {
        XCTAssertTrue(Model.accountAllowsLinking(transport: "cloudkit", account: "available"))
        XCTAssertFalse(Model.accountAllowsLinking(transport: "cloudkit", account: "no_account"))
        XCTAssertFalse(Model.accountAllowsLinking(transport: "cloudkit", account: "restricted"))
        XCTAssertFalse(Model.accountAllowsLinking(transport: "cloudkit", account: "temporarily_unavailable"))
        XCTAssertTrue(Model.accountAllowsLinking(transport: "cloudkit", account: ""), "not read yet")
        XCTAssertTrue(Model.accountAllowsLinking(transport: "relay", account: "no_account"))
        cli.status(#"{"state":"running","transport":"cloudkit","cloudkit":{"account":"no_account","throttled_since":"","signed":true}}"#)
        cli.phones("[]")
        let model = makeModel()
        await model.load()
        XCTAssertFalse(model.canLink, "no account: no code")
        model.linkPhone()
        XCTAssertNil(model.pairing)
    }

    /// Reads give up after 15 s and writes after 30 s, so a hung call never
    /// leaves the tab loading or a row busy.
    func testEveryCallHasATimeout() async {
        runningWith()
        let model = makeModel()
        await model.load()
        await model.rename("Studio")
        XCTAssertEqual(MobileHubCLI.readTimeout, 15)
        XCTAssertEqual(MobileHubCLI.writeTimeout, 30)
        XCTAssertEqual(cli.timeout(for: MobileHubCLI.statusArgs), 15)
        XCTAssertEqual(cli.timeout(for: MobileHubCLI.phonesArgs), 15)
        XCTAssertEqual(cli.timeout(for: MobileHubCLI.nameArgs("Studio")), 30)
        XCTAssertTrue(cli.untimed.isEmpty, "a call without a timeout: \(cli.untimed)")

        cli.fail(MobileHubCLI.statusArgs, stderr: "")
        cli.failAsTimeout(MobileHubCLI.nameArgs("Late"))
        await model.rename("Late")
        XCTAssertTrue(model.busy.isEmpty, "a timed-out write leaves nothing busy")
        XCTAssertNotNil(model.notice)
        if case .loading = model.state { XCTFail("a timed-out read left the tab loading") }
    }

    /// Go's RFC 3339 with nanoseconds (`time.Time` JSON) decodes for
    /// throttled_since and phone_contact_at.
    func testRFC3339NanoDecodes() throws {
        let nano = "2026-11-02T10:42:00.123456789Z"
        let date = try XCTUnwrap(MobileHubCLI.date(nano))
        XCTAssertEqual(date.timeIntervalSince1970, 1_793_616_120.123, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(HubControlAnswer.rfc3339(nano)).timeIntervalSince1970, 1_793_616_120.123, accuracy: 0.001)
        XCTAssertNotNil(MobileHubCLI.date("2026-11-02T10:42:00+01:00"))
    }

    private func runningWith(_ phones: String...) {
        cli.status(MobileHubFixture.running)
        cli.phones("[" + phones.joined(separator: ",") + "]")
    }

    private func rows(_ model: Model) -> [Model.PhoneRow] {
        guard case .phones(let rows) = model.state else { return [] }
        return rows
    }

    // MARK: - States

    func testStatesFromHubJSON() async {
        let cases: [(json: String, state: Model.State, copy: Model.OffCopy?)] = [
            (#"{"state":"off","reason":"disabled"}"#, .off(reason: "disabled"),
             Model.OffCopy(title: "Mobile sync",
                           detail: "Off. Turning Mobile off unlinks your phones: link them again after you turn it on.",
                           showsToggle: true, toggleOn: false, managed: false)),
            (#"{"state":"off","reason":"policy_off"}"#, .off(reason: "policy_off"),
             Model.OffCopy(title: "Mobile is turned off by your organization",
                           detail: "Managed by your organization. Linked phones are kept and work again when it is allowed.",
                           showsToggle: false, toggleOn: false, managed: true)),
            (#"{"state":"off","reason":"session_host_v1"}"#, .off(reason: "session_host_v1"),
             Model.OffCopy(title: "Mobile sync", detail: "Waiting for running sessions to restart once with this update.",
                           showsToggle: true, toggleOn: true, managed: false)),
            (#"{"state":"off","reason":"awaiting_adoption"}"#, .off(reason: "awaiting_adoption"),
             Model.OffCopy(title: "Mobile sync", detail: "Waiting for Mobile to move to the new version.",
                           showsToggle: true, toggleOn: true, managed: false)),
            (#"{"state":"off","reason":""}"#, .off(reason: ""),
             Model.OffCopy(title: "Mobile sync", detail: "Mobile is not running. It starts with the next sync.",
                           showsToggle: true, toggleOn: true, managed: false)),
            (#"{"state":"running","reason":""}"#, .noPhones, nil)
        ]
        for c in cases {
            cli.status(c.json)
            cli.phones("[]")
            let model = makeModel()
            XCTAssertEqual(model.state, .loading, "before the first read")
            await model.load()
            XCTAssertEqual(model.state, c.state, c.json)
            if let copy = c.copy, case .off(let reason) = c.state {
                XCTAssertEqual(Model.offCopy(reason), copy, c.json)
                XCTAssertEqual(model.isOn, copy.toggleOn, c.json)
            }
        }
        XCTAssertEqual(Model.offCopy("vouch_revoked").detail,
                       "The phone that vouched for this Mac on Relay took it back. Link a phone with Relay again.")
        XCTAssertEqual(Model.offCopy("something_newer").detail, Model.unknownReason)

        runningWith(MobileHubFixture.phoneA)
        let model = makeModel()
        await model.load()
        XCTAssertEqual(rows(model).map(\.name), ["Phone A"])
        XCTAssertTrue(model.canLink)
        XCTAssertEqual(model.macName, "Work Mac")
        XCTAssertTrue(model.recordingsOn)
        XCTAssertNil(model.hubLine)
        XCTAssertEqual(Model.emptyText, "No phones linked")
        XCTAssertEqual(Model.emptyDetail, "Link one to see this Mac's board and sessions on your phone.")
        XCTAssertEqual(Model.hubLine(state: "starting", reason: nil)?.text, "Starting…")
        XCTAssertEqual(Model.hubLine(state: "running", reason: "no_relay_origin")?.text,
                       "Relay is not set up on this Mac: phones link over iCloud only.")
    }

    /// A failed read shows the CLI's sentence with Retry; Retry reads again.
    func testAFailedReadShowsTheErrorAndRetryReadsAgain() async {
        cli.fail(MobileHubCLI.statusArgs, stderr: "Error: the hub state dir is locked")
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.state, .error("Couldn't read Mobile's state. The hub state dir is locked."))
        XCTAssertFalse(model.canLink)
        XCTAssertEqual(Model.retryTitle, "Retry")

        runningWith()
        await model.load()
        XCTAssertEqual(model.state, .noPhones)

        // A read cut short because the tab went away is no error: what it shows stays.
        cli.cancel(MobileHubCLI.statusArgs)
        await model.load()
        XCTAssertEqual(model.state, .noPhones)

        let noBinary = Model(cli: nil, defaults: defaults)
        await noBinary.load()
        XCTAssertEqual(noBinary.state, .error(Model.loadFailed(CLIRunnerError.binaryNotFound.localizedDescription)))
    }

    func testAdoptionHoldsTheTabUntilItEnds() async throws {
        runningWith()
        let adoption = Adoption(.checking)
        let model = makeModel(adoption: adoption)
        await model.load()
        XCTAssertEqual(model.state, .adoption(.checking))
        adoption.adoptionState = .inProgress(step: "copy")
        await model.load()
        XCTAssertEqual(model.state, .adoption(.inProgress(step: "copy")))
        XCTAssertTrue(cli.invocations.isEmpty, "no hub read while it moves")

        adoption.adoptionState = .failed(reason: "no_keys")
        await model.load()
        XCTAssertEqual(model.state, .adoption(.failed(reason: "no_keys")))
        XCTAssertEqual(HubAdoptionState.failed(reason: "no_keys").retryTitle, "Retry")

        await model.retryAdoption()
        XCTAssertEqual(adoption.retries, 1)
        XCTAssertEqual(model.state, .noPhones, "done: the hub's own state")
    }

    /// Pinned keys of `hub status --json` the tab reads, RFC 3339 with and without fractions.
    func testDecodesPinnedStatusKeys() async throws {
        cli.status("""
        {"state":"running","reason":"","hub_id":"h","relay_device_id":"","transport":"relay","impl":"go","dir":"/x",\
        "phones":1,"host":"desktop","mode":"live","recordings":"off","name":"Work Mac","bridge":"unavailable",\
        "transcriber":true,"off_delete":{"state":"","at":""},\
        "cloudkit":{"account":"restricted","throttled_since":"2026-11-02T10:00:00Z","signed":false},\
        "adoption":"done","identity":"keychain","switched_at":"2026-11-02T10:42:00.123Z","switched_by":"AAAA0001",\
        "kept_recordings":{"count":2,"remove_at":"2026-11-14T08:00:00Z","dir":"/tmp/acme-recordings"}}
        """)
        cli.phones(MobileHubFixture.list(MobileHubFixture.phoneA))
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.hubTransport, "relay")
        XCTAssertFalse(model.recordingsOn)
        XCTAssertTrue(model.showsNeedsSignedBuild)
        XCTAssertTrue(model.recordingsAvailable)
        XCTAssertNil(model.offDeleteLine)
        XCTAssertEqual(model.accountLine, "Mobile isn't available on this Mac: iCloud is restricted by your organization.")
        XCTAssertEqual(model.throttledSince, MobileHubCLI.date("2026-11-02T10:00:00Z"))
        XCTAssertEqual(model.keptRecordings?.count, 2)
        XCTAssertNotNil(model.hubSwitchedLine)
    }

    // MARK: - Transport

    func testTransportLabelPerPhone() async throws {
        XCTAssertEqual(Model.transportLabel("cloudkit"), "iCloud")
        XCTAssertEqual(Model.transportLabel("relay"), "Relay")
        XCTAssertEqual(Model.transportLabel("pending"), "Waiting for Relay")

        let now = try XCTUnwrap(MobileHubCLI.date("2026-11-02T12:00:00Z"))
        let at = try XCTUnwrap(MobileHubCLI.date("2026-11-02T10:42:00Z"))
        cli.status(#"{"state":"running","transport":"relay","switched_at":"2026-11-02T10:42:00Z","switched_by":"aaaa0001"}"#)
        cli.phones(MobileHubFixture.list(
            MobileHubFixture.phoneA, MobileHubFixture.phoneB,
            MobileHubFixture.phone(id: "CCCC0003", name: "Phone C", transport: "pending")
        ))
        let model = makeModel(now: now)
        await model.load()
        let byID = Dictionary(uniqueKeysWithValues: rows(model).map { ($0.id, $0) })
        let time = at.formatted(date: .omitted, time: .shortened)
        let linked = Model.linkedText(try XCTUnwrap(MobileHubCLI.date("2026-10-12T09:00:00Z")))

        XCTAssertEqual(byID["AAAA0001"]?.transportLabel, "Relay")
        XCTAssertEqual(byID["AAAA0001"]?.switchedLine, "switched by Phone A today \(time)")
        XCTAssertEqual(byID["AAAA0001"]?.detailLine, "Shared · \(linked) · Relay · switched by Phone A today \(time)")
        XCTAssertEqual(byID["BBBB0002"]?.transportLabel, "iCloud")
        XCTAssertNil(byID["BBBB0002"]?.switchedLine, "not on the transport the switch chose")
        XCTAssertEqual(byID["BBBB0002"]?.detailLine, "Same Apple ID · \(linked) · iCloud")
        // Today's scope label on the row (the deleted view test's assertion).
        XCTAssertEqual(Model.scopeLabel("private"), "Same Apple ID")
        XCTAssertEqual(Model.scopeLabel("shared"), "Shared")
        XCTAssertNil(Model.scopeLabel("weird"))
        XCTAssertEqual(byID["CCCC0003"]?.transportLabel, "Waiting for Relay")
        XCTAssertEqual(model.hubSwitchedLine, "Switched to Relay by Phone A · today \(time)")

        XCTAssertEqual(Model.hubSwitchedLine(to: "cloudkit", by: "entitlement_expired", at: at, now: now, names: [:]),
                       "Switched to iCloud when the Relay subscription ended · today \(time)")
        XCTAssertEqual(Model.phoneSwitchedLine(by: "DDDD0004", at: at, now: now, names: [:]),
                       "switched by a phone no longer linked today \(time)", "never a raw device id")
        let yesterday = now.addingTimeInterval(-86_400)
        XCTAssertEqual(Model.whenText(yesterday, now: now), "yesterday \(yesterday.formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(Model.TransportKind("cloudkit"), .iCloud)
        XCTAssertEqual(Model.TransportKind("relay"), .relay)
        XCTAssertEqual(Model.TransportKind("pending"), .pending)
    }

    // MARK: - Writes

    func testToggleCallsEnableDisable() async {
        cli.status(#"{"state":"off","reason":"disabled"}"#)
        let model = makeModel()
        await model.load()
        XCTAssertFalse(model.isOn)

        let busySeen = BusyProbe()
        cli.onRun = { [weak model] args in
            guard args == MobileHubCLI.enabledArgs(true) else { return }
            await MainActor.run { busySeen.value = model?.busy.contains(.toggle) ?? false }
        }
        runningWith()
        await model.setEnabled(true)
        XCTAssertEqual(cli.writes, [["hub", "enable", "--json"]])
        XCTAssertTrue(busySeen.value, "the switch is busy while the write runs")
        XCTAssertTrue(model.busy.isEmpty)
        XCTAssertEqual(model.state, .noPhones)

        cli.fail(MobileHubCLI.enabledArgs(false), stderr: "Error: the hub is not running")
        await model.setEnabled(false)
        XCTAssertEqual(cli.writes.last, ["hub", "disable", "--json"])
        XCTAssertEqual(model.notice, "Couldn't turn Mobile off. The hub is not running.")
    }

    func testRecordingsSwitchCallsHubRecordings() async {
        runningWith()
        let model = makeModel()
        await model.load()
        cli.answer(MobileHubCLI.recordingsArgs(false), #"{"recordings":"off","stored":true}"#)
        await model.setRecordings(false)
        XCTAssertEqual(cli.writes, [["hub", "recordings", "off", "--json"]])

        // The refusal is the structured class on stdout (exit 0, stored false).
        cli.answer(MobileHubCLI.recordingsArgs(true), #"{"recordings":"off","stored":false,"error":"no_transcriber"}"#)
        cli.status(#"{"state":"running","recordings":"off","transcriber":false}"#)
        await model.setRecordings(true)
        XCTAssertEqual(cli.writes.last, ["hub", "recordings", "on", "--json"])
        XCTAssertEqual(model.recordingsError, "This host has no transcriber.")
        XCTAssertEqual(Model.noTranscriber, "This host has no transcriber.")
        XCTAssertFalse(model.recordingsAvailable, "off-only while no transcriber was seen")
        XCTAssertFalse(model.recordingsOn)

        // A Desktop heartbeat arrived since: the next read makes it available again.
        cli.status(#"{"state":"running","recordings":"off","transcriber":true}"#)
        await model.load()
        XCTAssertTrue(model.recordingsAvailable)

        cli.fail(MobileHubCLI.recordingsArgs(true), stderr: "Error: the hub did not answer")
        await model.setRecordings(true)
        XCTAssertEqual(model.recordingsError, "The hub did not answer.")
        XCTAssertEqual(Model.recordingsTitle, "Transcribe phone recordings on this Mac")
        XCTAssertEqual(Model.turningOn, "Turning on…")
    }

    func testAllowAndUnlinkCallTheCLI() async throws {
        runningWith(
            MobileHubFixture.phone(id: "AAAA0001", name: "Phone A", transport: "relay", typingRequested: true),
            MobileHubFixture.phone(id: "BBBB0002", name: "Phone B", transport: "cloudkit", scope: "private", typing: true)
        )
        let model = makeModel()
        await model.load()
        let phoneA = try XCTUnwrap(rows(model).first { $0.id == "AAAA0001" })
        let phoneB = try XCTUnwrap(rows(model).first { $0.id == "BBBB0002" })
        XCTAssertEqual(phoneA.requests, ["typing"])

        // Allow… asks first, naming the phone; nothing is written until it is confirmed.
        model.requestAllow(phoneA)
        XCTAssertEqual(Model.allowQuestion(name: try XCTUnwrap(model.pendingAllow).name),
                       "Allow \"Phone A\" to type into Claude Code sessions?")
        XCTAssertTrue(cli.writes.isEmpty)
        await model.confirmAllow()
        XCTAssertNil(model.pendingAllow)
        model.requestPermissionsAllow(phoneA)
        await model.confirmPermissionsAllow()
        model.requestStartSessionsAllow(phoneB)
        await model.confirmStartSessionsAllow()
        await model.allow("BBBB0002", Model.typingGrant, false)
        XCTAssertEqual(cli.writes, [
            ["hub", "allow", "AAAA0001", "typing", "--json"],
            ["hub", "allow", "AAAA0001", "permissions", "--json"],
            ["hub", "allow", "BBBB0002", "start_sessions", "--json"],
            ["hub", "allow", "BBBB0002", "typing", "--json", "--revoke"]
        ])

        cli.fail(MobileHubCLI.allowArgs("AAAA0001", "typing", false), stderr: "Error: no such phone")
        await model.allow("AAAA0001", Model.typingGrant, false)
        XCTAssertEqual(model.notice, "Couldn't change typing for Phone A. No such phone.")

        // Remove asks first; Cancel keeps the phone.
        model.requestRemove(phoneB)
        model.pendingRemove = nil
        XCTAssertEqual(model.removeSubject?.name, "Phone B", "the dialog keeps its phone while it dismisses")
        await model.confirmRemove()
        XCTAssertFalse(cli.writes.contains(MobileHubCLI.unlinkArgs("BBBB0002")))

        model.requestRemove(phoneB)
        await model.confirmRemove()
        XCTAssertEqual(cli.writes.last, ["hub", "unlink", "BBBB0002", "--json"])
        XCTAssertEqual(model.notice, "Removed Phone B. It can no longer read anything new from this Mac.")
        model.requestRemove(phoneA)
        await model.confirmRemove()
        XCTAssertEqual(model.notice, "Removed Phone A.")

        cli.fail(MobileHubCLI.unlinkArgs("AAAA0001"), stderr: "Error: the hub did not answer")
        model.requestRemove(phoneA)
        await model.confirmRemove()
        XCTAssertEqual(model.notice, "Couldn't remove Phone A. The hub did not answer.")
    }

    func testRenameCallsHubName() async {
        runningWith()
        let model = makeModel()
        await model.load()
        await model.rename("  Work Mac  ")
        XCTAssertTrue(cli.writes.isEmpty, "the same name, trimmed, writes nothing")
        await model.rename("   ")
        XCTAssertTrue(cli.writes.isEmpty)
        await model.rename(" Studio ")
        XCTAssertEqual(cli.writes, [["hub", "name", "Studio", "--json"]])
        cli.fail(MobileHubCLI.nameArgs("x"), stderr: "Error: the hub name must be 1 to 64 characters")
        await model.rename("x")
        XCTAssertEqual(model.notice, "Couldn't rename this Mac. The hub name must be 1 to 64 characters.")
    }

    // MARK: - Recordings

    func testKeptRecordingsLine() async throws {
        let removeAt = try XCTUnwrap(MobileHubCLI.date("2026-11-14T08:00:00Z"))
        let one = Model.KeptRecordings(count: 1, removeAt: removeAt, dir: URL(fileURLWithPath: "/tmp/acme"))
        let three = Model.KeptRecordings(count: 3, removeAt: removeAt, dir: URL(fileURLWithPath: "/tmp/acme"))
        XCTAssertEqual(Model.keptLine(one), "1 phone recording was not transcribed during the update")
        XCTAssertEqual(Model.keptLine(three), "3 phone recordings were not transcribed during the update")
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        XCTAssertEqual(Model.keptRemovalLine(three), "Removed from this Mac on \(formatter.string(from: removeAt))")
        XCTAssertEqual(Model.showInFinderTitle, "Show in Finder")

        cli.status(#"{"state":"running","kept_recordings":{"count":3,"remove_at":"2026-11-14T08:00:00Z","dir":"/tmp/acme"}}"#)
        cli.phones("[]")
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.keptRecordings, three)

        cli.status(#"{"state":"off","reason":"disabled","kept_recordings":{"count":3,"remove_at":"2026-11-14T08:00:00Z","dir":"/tmp/acme"}}"#)
        await model.load()
        XCTAssertEqual(model.keptRecordings, three, "the line shows while Mobile is off too")

        cli.status(MobileHubFixture.running)
        await model.load()
        XCTAssertNil(model.keptRecordings, "absent kept_recordings hides the line")
        cli.status(#"{"state":"running","kept_recordings":{"count":0,"remove_at":"2026-11-14T08:00:00Z","dir":"/tmp/acme"}}"#)
        await model.load()
        XCTAssertNil(model.keptRecordings)
    }

    func testShowInFinderOpensTheHubsRecordingsDir() async {
        cli.status(#"{"state":"running","kept_recordings":{"count":1,"remove_at":"2026-11-14T08:00:00Z","dir":"/tmp/acme-hub/recordings"}}"#)
        cli.phones("[]")
        var opened: [URL] = []
        let open: (URL) -> Void = { opened.append($0) }
        let model = makeModel(opened: open)
        model.showKeptRecordingsInFinder()
        XCTAssertTrue(opened.isEmpty, "nothing kept, nothing opened")
        await model.load()
        model.showKeptRecordingsInFinder()
        XCTAssertEqual(opened, [URL(fileURLWithPath: "/tmp/acme-hub/recordings")])
    }

    func testFailedRecordingsRetryAndDiscard() async throws {
        runningWith()
        cli.answer(MobileHubCLI.recordingJobsArgs, """
        {"ready":true,"jobs":[\
        {"upload_id":"u-1","status":"failed","error_class":"not_audio"},\
        {"upload_id":"u-2","status":"failed","error_class":"missing_audio"},\
        {"upload_id":"u-3","status":"failed","error_class":"hub_moved"},\
        {"upload_id":"u-4","status":"queued","error_class":""},\
        {"upload_id":"u-5","status":"failed","error_class":"transcription_failed"}]}
        """)
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.failedRecordings, [
            .init(id: "u-1", line: "A phone recording is not audio this Mac can read", retryable: true),
            .init(id: "u-2", line: "A phone recording's audio is missing", retryable: false),
            .init(id: "u-5", line: "A phone recording could not be transcribed", retryable: true)
        ])

        await model.retryRecording("u-5")
        XCTAssertEqual(cli.writes, [["hub", "recording", "claim", "--upload", "u-5", "--json"]])

        model.requestDiscard(model.failedRecordings[0])
        XCTAssertEqual(Model.discardQuestion, "Discard this phone recording?")
        XCTAssertEqual(Model.discardMessage, "Its audio is deleted from this Mac. This can't be undone.")
        model.pendingDiscard = nil
        await model.confirmDiscard()
        XCTAssertEqual(cli.writes.count, 1, "no discard without the confirmation")
        model.requestDiscard(model.failedRecordings[0])
        await model.confirmDiscard()
        XCTAssertEqual(cli.writes.last, ["hub", "recording", "discard", "--upload", "u-1", "--json"])

        cli.fail(MobileHubCLI.discardArgs("u-2"), stderr: "Error: the recording job is not in a state that allows this")
        model.requestDiscard(model.failedRecordings[1])
        await model.confirmDiscard()
        XCTAssertEqual(model.notice, "Couldn't discard the recording. The recording job is not in a state that allows this.")

        // An older CLI or a hub with no queue yet: the rows hide, nothing else changes.
        cli.fail(MobileHubCLI.recordingJobsArgs, stderr: "Error: unknown command \"list\"")
        await model.load()
        XCTAssertEqual(model.failedRecordings, [])
        XCTAssertEqual(model.state, .noPhones)
    }

    // MARK: - The rest of today's tab

    func testGrantLabelsAndQuestions() {
        func row(
            typing: Bool = false,
            typingRequested: Bool = false,
            permissions: Bool = false,
            permissionsRequested: Bool = false,
            start: Bool = false,
            granted: Bool = false
        ) -> Model.PhoneRow {
            Model.PhoneRow(id: "A", name: "Phone A", transportLabel: "iCloud", transport: "cloudkit", scope: "shared",
                           detailLine: "", switchedLine: nil, typing: typing, permissions: permissions, startSessions: start,
                           typingRequested: typingRequested, permissionsRequested: permissionsRequested,
                           startSessionsGranted: granted, requests: [])
        }
        XCTAssertEqual(Model.typingLabel(row()), "Typing off")
        XCTAssertEqual(Model.typingLabel(row(typingRequested: true)), "Asks to type into sessions")
        XCTAssertEqual(Model.typingLabel(row(typing: true)), "Typing allowed")
        XCTAssertEqual(Model.startSessionsLabel(row()), "Starting sessions needs typing")
        XCTAssertEqual(Model.startSessionsLabel(row(typing: true)), "Starting sessions off")
        XCTAssertEqual(Model.startSessionsLabel(row(typing: true, granted: true)),
                       "Starting sessions allowed on the Mac — off on the phone")
        XCTAssertEqual(Model.startSessionsLabel(row(typing: true, start: true, granted: true)), "Starting sessions allowed")
        XCTAssertEqual(Model.permissionsLabel(row()), "Permission prompts off")
        XCTAssertEqual(Model.permissionsLabel(row(permissionsRequested: true)), "Asks to answer permission prompts")
        XCTAssertEqual(Model.permissionsLabel(row(permissions: true)), "Permission prompts allowed")
        XCTAssertEqual(Model.permissionsQuestion(name: "Phone A"), "Allow \"Phone A\" to approve commands in Claude Code sessions?")
        XCTAssertEqual(Model.startSessionsQuestion(name: "Phone A"), "Allow \"Phone A\" to start Claude Code sessions on this Mac?")
        XCTAssertEqual(Model.removeQuestion(name: "Phone A"), "Remove \"Phone A\"?")
        XCTAssertEqual(Model.allowMessage(row()),
                       "The phone can then send text to sessions running on this Mac. Revoke turns it off again.")
        XCTAssertTrue(Model.allowMessage(row(granted: true))
            .hasSuffix(" Starting sessions, allowed earlier for this phone, comes back with it."))
        XCTAssertTrue(Model.removeConsequence(scope: "private").contains("this Mac changes its keys"))
        XCTAssertEqual(Model.removeConsequence(scope: "shared"),
                       "It leaves this Mac at once and loses its data. Linking it again needs a new code.")
    }

    func testCorpNoticeAndKeepAwake() {
        XCTAssertTrue(makeModel(corp: true).showsCorpNotice)
        XCTAssertFalse(makeModel().showsCorpNotice)
        XCTAssertTrue(AppState.isCorpBuild("corp"))
        XCTAssertFalse(AppState.isCorpBuild("dev"))
        XCTAssertFalse(AppState.isCorpBuild(nil))
        XCTAssertEqual(Model.corpNotice, "Work data from this Mac will be stored in your personal iCloud account.")

        let model = makeModel()
        XCTAssertTrue(model.keepAwake, "on unless the owner turned it off")
        model.setKeepAwake(false)
        XCTAssertFalse(model.keepAwake)
        XCTAssertEqual(defaults.object(forKey: Constants.mobileKeepAwakeKey) as? Bool, false)
        XCTAssertFalse(makeModel().keepAwake)
    }

    func testPollingRunsUntilItsTaskIsCancelled() async {
        runningWith()
        let sleeps = SleepLog()
        let twice: @Sendable (Duration) async -> Void = { duration in
            await sleeps.add(duration)
            if await sleeps.count >= 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let model = makeModel(sleep: twice)
        await Task { await model.windowVisibility(true) }.value
        let recorded = await sleeps.all
        XCTAssertEqual(recorded, [Model.refreshInterval, Model.refreshInterval])
        XCTAssertEqual(cli.invocations.filter { $0 == MobileHubCLI.statusArgs }.count, 2)

        cli.status(#"{"state":"starting"}"#)
        let fast = SleepLog()
        let once: @Sendable (Duration) async -> Void = { duration in
            await fast.add(duration)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let starting = makeModel(sleep: once)
        await Task { await starting.windowVisibility(true) }.value
        let first = await fast.all
        XCTAssertEqual(first, [Model.startingRefreshInterval], "5 s while the hub starts")
    }

    func testLinkAPhoneNeedsARunningHubAndClosesWithTheWindow() async {
        let streamer = FakePairStreamer()
        cli.status(#"{"state":"off","reason":"disabled"}"#)
        let model = makeModel(streamer: streamer)
        await model.load()
        model.linkPhone()
        XCTAssertNil(model.pairing, "no pairing while the hub is off")

        runningWith()
        await model.load()
        model.linkPhone()
        let sheet = try? XCTUnwrap(model.pairing)
        await sheet?.start()
        XCTAssertEqual(streamer.sessions.count, 1)

        await model.windowVisibility(false)
        XCTAssertNil(model.pairing, "a hidden window closes the pairing")
        XCTAssertTrue(streamer.sessions[0].stopped)

        model.linkPhone()
        await model.pairing?.start()
        await model.setEnabled(false)
        XCTAssertNil(model.pairing, "turning Mobile off closes the pairing")
        XCTAssertTrue(streamer.sessions[1].stopped)
        XCTAssertEqual(Model.linkTitle, "Link a phone…")
    }

    // MARK: - Relay indicators (go hub plan 4 Task 8)

    private let t0 = Date(timeIntervalSince1970: 1_793_620_800)
    private func rfc(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func relayPhone(
        _ id: String,
        _ name: String,
        paying: String = "true",
        undelivered: String = "0",
        mailboxFull: String = "false",
        alerts: String = #""""#
    ) -> String {
        MobileHubFixture.phone(id: id, name: name, transport: "relay", indicators: MobileHubFixture.indicators(
            paying: paying, undelivered: undelivered, mailboxFull: mailboxFull, alerts: alerts
        ))
    }

    private func loaded(_ status: String, _ phones: String...) async -> Model {
        cli.status(status)
        cli.phones("[" + phones.joined(separator: ",") + "]")
        let model = makeModel(now: t0)
        await model.load()
        return model
    }

    private var connected: String {
        MobileHubFixture.relayStatus(state: "connected", since: rfc(t0.addingTimeInterval(-600)), lastSavedAt: rfc(t0.addingTimeInterval(-120)))
    }

    func testDecodesRelayHealthAndPayingPhones() async throws {
        let hub = MobileHubCLI(runner: cli)
        cli.status(MobileHubFixture.relayStatus(
            state: "connected", since: rfc(t0.addingTimeInterval(-600)), quotaHub: true, pushOff: true,
            lastSavedAt: rfc(t0.addingTimeInterval(-120)), paying: #"["AAAA0001"]"#, mailboxFull: #"["BBBB0002"]"#
        ))
        let status = try await hub.status()
        XCTAssertEqual(status.relay, MobileHubCLI.RelayHealth(
            state: "connected", since: t0.addingTimeInterval(-600), quotaHub: true, pushOff: true, lastSavedAt: t0.addingTimeInterval(-120)
        ))
        XCTAssertEqual(status.payingPhones, ["AAAA0001"])
        XCTAssertEqual(status.mailboxFullPhones, ["BBBB0002"])

        // `last_saved_at` "" = no save yet; `paying_phones` null = unknown, never "nobody pays".
        cli.status(MobileHubFixture.relayStatus(state: "connecting", since: rfc(t0), paying: "null"))
        let unknown = try await hub.status()
        XCTAssertNil(unknown.relay?.lastSavedAt)
        XCTAssertEqual(unknown.relay?.state, "connecting")
        XCTAssertNil(unknown.payingPhones)
        // No relay origin: no `relay` block.
        cli.status(MobileHubFixture.running)
        let plain = try await hub.status()
        XCTAssertNil(plain.relay)
        XCTAssertNil(plain.payingPhones)
        XCTAssertEqual(plain.mailboxFullPhones, [])

        cli.phones(MobileHubFixture.list(
            relayPhone("AAAA0001", "Phone A", paying: "false", undelivered: "2", mailboxFull: "true", alerts: #""accepted""#),
            relayPhone("BBBB0002", "Phone B", paying: "null", undelivered: "null", mailboxFull: "null", alerts: "null"),
            MobileHubFixture.phoneB
        ))
        let phones = try await hub.phones()
        XCTAssertEqual(phones[0].paying, false)
        XCTAssertEqual(phones[0].undelivered, 2)
        XCTAssertEqual(phones[0].mailboxFull, true)
        XCTAssertEqual(phones[0].alerts, "accepted")
        for phone in phones.dropFirst() {
            XCTAssertNil(phone.paying, phone.name)
            XCTAssertNil(phone.undelivered, phone.name)
            XCTAssertNil(phone.mailboxFull, phone.name)
            XCTAssertNil(phone.alerts, phone.name)
        }
    }

    func testFreePhoneOnRelayLine() async {
        let model = await loaded(connected, relayPhone("AAAA0001", "Phone A", paying: "false"),
                                 relayPhone("BBBB0002", "Phone B", paying: "true"),
                                 relayPhone("CCCC0003", "Phone C", paying: "null"))
        let lines = rows(model).map(\.updatesLine)
        XCTAssertEqual(lines[0], Model.HubLine(
            text: "Doesn't get updates: this Mac runs over Relay. Switch this Mac to iCloud from a subscribed phone, "
                + "or subscribe on Phone A.",
            tone: .warning
        ))
        XCTAssertNil(lines[1], "a paying phone")
        XCTAssertNil(lines[2], "null is unknown, never free")

        // On CloudKit the hub does not run over Relay: no line.
        let onCloud = await loaded(MobileHubFixture.running, relayPhone("AAAA0001", "Phone A", paying: "false"))
        XCTAssertNil(rows(onCloud).first?.updatesLine)
    }

    func testUndeliveredSingularPlural() async {
        XCTAssertEqual(Model.undeliveredLine(1)?.text, "On this Mac's side, 1 action from this phone is not applied yet.")
        XCTAssertEqual(Model.undeliveredLine(3)?.text, "On this Mac's side, 3 actions from this phone are not applied yet.")
        XCTAssertNil(Model.undeliveredLine(0))
        let model = await loaded(connected, relayPhone("AAAA0001", "Phone A", undelivered: "1"),
                                 relayPhone("BBBB0002", "Phone B", undelivered: "3"),
                                 relayPhone("CCCC0003", "Phone C", undelivered: "0"),
                                 relayPhone("DDDD0004", "Phone D", undelivered: "null"))
        XCTAssertEqual(rows(model).map { $0.undeliveredLine?.text }, [
            "On this Mac's side, 1 action from this phone is not applied yet.",
            "On this Mac's side, 3 actions from this phone are not applied yet.",
            nil, nil
        ])
        XCTAssertEqual(rows(model)[0].undeliveredLine?.tone, .warning)
    }

    /// It is what this Mac's side knows, never the phone's own queue.
    func testUndeliveredLineSaysThisMacsSide() {
        for count in [1, 2, 3, 40] {
            let line = Model.undeliveredLine(count)?.text ?? ""
            XCTAssertTrue(line.hasPrefix("On this Mac's side, "), line)
            XCTAssertTrue(line.hasSuffix(" not applied yet."), line)
            XCTAssertFalse(line.contains("delivered"), line)
            XCTAssertFalse(line.contains("Retry"), line)
        }
    }

    func testAcceptedReadsSentToRelay() async {
        let model = await loaded(connected, relayPhone("AAAA0001", "Phone A", alerts: #""accepted""#))
        XCTAssertEqual(rows(model).first?.alertsLine, Model.HubLine(text: "Last alert: sent to relay", tone: .neutral))
    }

    func testNoTokenLine() async {
        let model = await loaded(connected, relayPhone("AAAA0001", "Phone A", alerts: #""no_token""#),
                                 relayPhone("BBBB0002", "Phone B", alerts: #""""#),
                                 relayPhone("CCCC0003", "Phone C", alerts: #""failed""#),
                                 relayPhone("DDDD0004", "Phone D", alerts: "null"))
        XCTAssertEqual(rows(model).map(\.alertsLine), [
            Model.HubLine(text: "Notifications aren't set up on this iPhone. Open Watchtower on it once.", tone: .warning),
            nil, nil, nil
        ])
    }

    func testRelayUnavailableMinutes() async {
        let model = await loaded(MobileHubFixture.relayStatus(state: "unavailable", since: rfc(t0.addingTimeInterval(-150))))
        XCTAssertEqual(model.relayConnection, Model.HubLine(
            text: "Relay unavailable for 2 min. Phones keep their changes and send them when it is back.", tone: .warning
        ))
        XCTAssertEqual(Model.relayUnavailableLine(since: t0, now: t0),
                       "Relay unavailable for 1 min. Phones keep their changes and send them when it is back.")
    }

    func testRelayConnectingLine() async {
        let model = await loaded(MobileHubFixture.relayStatus(state: "connecting", since: rfc(t0.addingTimeInterval(-30))))
        XCTAssertEqual(model.relayConnection, Model.HubLine(text: "Connecting to Relay…", tone: .neutral))
        let fresh = await loaded(connected)
        XCTAssertEqual(fresh.relayConnection, Model.HubLine(text: "Connected · last change delivered 2 min ago", tone: .neutral))
        XCTAssertEqual(Model.relayConnectedLine(lastSavedAt: nil, now: t0), "Connected")
        XCTAssertEqual(Model.relayConnectedLine(lastSavedAt: t0.addingTimeInterval(-30), now: t0),
                       "Connected · last change delivered under a minute ago")
        XCTAssertEqual(Model.ageText(5 * 60 + 10), "5 min")
        XCTAssertEqual(Model.ageText(59 * 60), "59 min")
        XCTAssertEqual(Model.ageText(3 * 3600), "3 h")
        XCTAssertEqual(Model.ageText(2 * 86_400), "2 d")
        XCTAssertNil(Model.relayConnection(.init(state: "something_newer", since: t0), now: t0))
        let off = await loaded(#"{"state":"off","reason":"disabled","relay":{"state":"connected","since":"\#(rfc(t0))"}}"#)
        XCTAssertNil(off.relayConnection, "the hub block is gone while Mobile is off")
    }

    func testQuotaLines() async {
        let model = await loaded(
            MobileHubFixture.relayStatus(state: "connected", since: rfc(t0), quotaHub: true),
            relayPhone("AAAA0001", "Phone A", mailboxFull: "true")
        )
        XCTAssertEqual(model.hubQuotaLine, Model.HubLine(
            text: "This Mac's Relay storage is full (5 GB). New changes are not sent until older recordings are removed.",
            tone: .error
        ))
        XCTAssertEqual(rows(model).first?.mailboxLine, Model.HubLine(text: "Phone A's Relay mailbox is full.", tone: .error))
        let cleared = await loaded(connected, relayPhone("AAAA0001", "Phone A", mailboxFull: "null"))
        XCTAssertNil(cleared.hubQuotaLine)
        XCTAssertNil(rows(cleared).first?.mailboxLine)
    }

    func testPushOffLineFollowsRelayHealth() async {
        let model = await loaded(MobileHubFixture.relayStatus(state: "connected", since: rfc(t0), pushOff: true))
        XCTAssertEqual(model.relayPushLine, Model.HubLine(text: "Relay has no notifications configured.", tone: .warning))
        cli.status(connected)
        await model.load()
        XCTAssertNil(model.relayPushLine)
        cli.status(MobileHubFixture.running)
        await model.load()
        XCTAssertNil(model.relayConnection, "no relay block: no Relay lines")
        XCTAssertNil(model.relayPushLine)
        XCTAssertNil(model.hubQuotaLine)
        XCTAssertEqual(model.relayLines, [], "no Relay row")
    }

    /// An empty or unreadable `since` drops the connection line only: the
    /// status still reads, the other Relay lines and the phones still show.
    func testUnreadableSinceDropsOnlyTheConnectionLine() async {
        for since in ["", "not a time"] {
            let model = await loaded(
                MobileHubFixture.relayStatus(state: "unavailable", since: since, quotaHub: true, pushOff: true),
                relayPhone("AAAA0001", "Phone A", mailboxFull: "true")
            )
            XCTAssertNil(model.relayConnection, since)
            XCTAssertEqual(model.relayLines.map(\.text), [Model.relayPushOff, Model.hubQuotaFull], since)
            XCTAssertEqual(rows(model).first?.indicatorLines.map(\.text), ["Phone A's Relay mailbox is full."], since)
        }
        // A missing key reads the same.
        let missing = await loaded(#"{"state":"running","transport":"relay","relay":{"state":"connected"}}"#)
        XCTAssertNil(missing.relayConnection)
        XCTAssertEqual(missing.relayLines, [])
    }

    /// The lines the view shows, in order, with no unknown ones.
    func testLinesInRowOrder() async {
        let model = await loaded(
            MobileHubFixture.relayStatus(state: "connecting", since: rfc(t0), quotaHub: true, pushOff: true),
            relayPhone("AAAA0001", "Phone A", paying: "false", undelivered: "3", mailboxFull: "true", alerts: #""accepted""#),
            relayPhone("BBBB0002", "Phone B", undelivered: "null", mailboxFull: "null", alerts: "null")
        )
        XCTAssertEqual(model.relayLines.map(\.text), [Model.relayConnecting, Model.relayPushOff, Model.hubQuotaFull])
        XCTAssertEqual(rows(model).map { $0.indicatorLines.map(\.text) }, [
            ["Phone A's Relay mailbox is full.", Model.updatesLine(name: "Phone A").text, Model.undeliveredLine(3)?.text ?? ""],
            []
        ])
    }

    func testMailboxLineNamesEachAffectedPhone() async {
        let model = await loaded(connected, relayPhone("AAAA0001", "Phone A", mailboxFull: "true"),
                                 relayPhone("BBBB0002", "Phone B", mailboxFull: "false"),
                                 relayPhone("CCCC0003", "Phone C", mailboxFull: "true"))
        XCTAssertEqual(rows(model).map { $0.mailboxLine?.text }, [
            "Phone A's Relay mailbox is full.", nil, "Phone C's Relay mailbox is full."
        ])
    }

    func testNoAlertsLineForAPhoneWithoutSubscription() async {
        let model = await loaded(connected, relayPhone("AAAA0001", "Phone A", paying: "false", alerts: #""accepted""#),
                                 relayPhone("BBBB0002", "Phone B", paying: "false", alerts: #""no_token""#),
                                 relayPhone("CCCC0003", "Phone C", paying: "null", alerts: #""accepted""#))
        XCTAssertEqual(rows(model).map(\.alertsLine), [nil, nil, Model.HubLine(text: Model.alertAcceptedLine, tone: .neutral)])
    }

    /// The full product of the independent fields: each line keeps its own
    /// exact text whatever else is set beside it.
    func testEveryCoOccurringCombinationShowsEachLine() async {
        let since = t0.addingTimeInterval(-150)
        let saved = t0.addingTimeInterval(-120)
        let connections: [(String, Model.HubLine)] = [
            ("connected", .init(text: "Connected · last change delivered 2 min ago", tone: .neutral)),
            ("connecting", .init(text: "Connecting to Relay…", tone: .neutral)),
            ("unavailable", .init(text: "Relay unavailable for 2 min. Phones keep their changes and send them when it is back.",
                                  tone: .warning))
        ]
        let pushOff = Model.HubLine(text: "Relay has no notifications configured.", tone: .warning)
        let quota = Model.HubLine(
            text: "This Mac's Relay storage is full (5 GB). New changes are not sent until older recordings are removed.", tone: .error
        )
        let updates = Model.HubLine(
            text: "Doesn't get updates: this Mac runs over Relay. Switch this Mac to iCloud from a subscribed phone, "
                + "or subscribe on Phone A.", tone: .warning
        )
        let undelivered: [Int?: String] = [
            1: "On this Mac's side, 1 action from this phone is not applied yet.",
            3: "On this Mac's side, 3 actions from this phone are not applied yet."
        ]
        let alerts: [String?: Model.HubLine] = [
            "no_token": .init(text: "Notifications aren't set up on this iPhone. Open Watchtower on it once.", tone: .warning),
            "accepted": .init(text: "Last alert: sent to relay", tone: .neutral)
        ]
        // Null (not known) cases sit beside the values: each gives no line.
        let payings: [Bool?] = [true, false, nil] // swiftlint:disable:this discouraged_optional_boolean
        let counts: [Int?] = [0, 1, 3, nil]
        let mailboxes: [Bool?] = [true, false, nil] // swiftlint:disable:this discouraged_optional_boolean
        let outcomes: [String?] = ["", "no_token", "accepted", nil]
        var shown = 0
        for (state, connection) in connections {
            for off in [false, true] {
                for full in [false, true] {
                    let relay = MobileHubCLI.RelayHealth(state: state, since: since, quotaHub: full, pushOff: off, lastSavedAt: saved)
                    let status = MobileHubCLI.Status(state: "running", transport: "relay", name: "Work Mac", relay: relay)
                    var phones: [MobileHubCLI.Phone] = []
                    for paying in payings {
                        for count in counts {
                            for mailbox in mailboxes {
                                for outcome in outcomes {
                                    phones.append(MobileHubCLI.Phone(
                                        deviceID: "P\(phones.count)", name: "Phone A", scope: "shared", linkedAt: t0,
                                        typingAllowed: false, typingRequested: false, permissionsAllowed: false,
                                        permissionsRequested: false, startSessionsAllowed: false, startSessionsGranted: false,
                                        transport: "relay", paying: paying, undelivered: count, mailboxFull: mailbox, alerts: outcome
                                    ))
                                }
                            }
                        }
                    }
                    let model = makeModel(now: t0)
                    model.present(status: status, phones: phones, jobs: nil)
                    let what = "\(state) pushOff=\(off) quota=\(full)"
                    XCTAssertEqual(model.relayConnection, connection, what)
                    XCTAssertEqual(model.relayPushLine, off ? pushOff : nil, what)
                    XCTAssertEqual(model.hubQuotaLine, full ? quota : nil, what)
                    let phoneRows = rows(model)
                    XCTAssertEqual(phoneRows.count, phones.count)
                    for (row, phone) in zip(phoneRows, phones) {
                        let free = phone.paying == false
                        let rowWhat = "\(what) paying=\(String(describing: phone.paying)) undelivered=\(String(describing: phone.undelivered)) "
                            + "mailbox=\(String(describing: phone.mailboxFull)) alerts=\(String(describing: phone.alerts))"
                        XCTAssertEqual(row.updatesLine, free ? updates : nil, rowWhat)
                        XCTAssertEqual(row.undeliveredLine?.text, undelivered[phone.undelivered], rowWhat)
                        XCTAssertEqual(row.mailboxLine?.text, phone.mailboxFull == true ? "Phone A's Relay mailbox is full." : nil, rowWhat)
                        XCTAssertEqual(row.alertsLine, free ? nil : alerts[phone.alerts], rowWhat)
                        if free { XCTAssertNil(row.alertsLine, "never a Last alert line for a free phone: \(rowWhat)") }
                        shown += [row.updatesLine, row.undeliveredLine, row.mailboxLine, row.alertsLine].compactMap { $0 }.count
                    }
                }
            }
        }
        XCTAssertGreaterThan(shown, 0)
    }

    /// The hub rewrote its status (a watch `status` event, `HubCenter.statusEvents`):
    /// the tab reads again and the lines follow, though state and reason stay.
    func testWatchStatusEventRefreshesLines() async {
        let model = await loaded(MobileHubFixture.relayStatus(state: "connecting", since: rfc(t0)),
                                 relayPhone("AAAA0001", "Phone A"))
        XCTAssertEqual(model.relayConnection?.text, Model.relayConnecting)
        XCTAssertNil(rows(model).first?.mailboxLine)
        cli.status(MobileHubFixture.relayStatus(state: "connected", since: rfc(t0), pushOff: true, lastSavedAt: rfc(t0)))
        cli.phones(MobileHubFixture.list(relayPhone("AAAA0001", "Phone A", undelivered: "1", mailboxFull: "true")))
        await model.load() // what MobileSettingsTab runs on `statusEvents`
        XCTAssertEqual(model.relayConnection?.text, "Connected · last change delivered under a minute ago")
        XCTAssertEqual(model.relayPushLine?.text, Model.relayPushOff)
        XCTAssertEqual(rows(model).first?.mailboxLine?.text, "Phone A's Relay mailbox is full.")
        XCTAssertEqual(rows(model).first?.undeliveredLine?.text, Model.undeliveredLine(1)?.text)
    }

    // MARK: - Source guards

    func testEveryUIStringLivesInTheModel() throws {
        for file in ["Sources/Views/Settings/MobileSettingsView.swift", "Sources/Views/Settings/MobileLinkSheet.swift"] {
            XCTAssertEqual(try swiftStringLiterals(in: file), [], "\(file) holds a string literal")
        }
    }

    /// Settings → Mobile reads the hub through `hub … --json` only: no
    /// literal names the hub's database or the Swift hub's folder.
    func testNeverOpensTheSidecar() throws {
        for file in [
            "Sources/ViewModels/MobileSettingsModel.swift", "Sources/ViewModels/MobileSettingsModel+Copy.swift",
            "Sources/ViewModels/MobileSettingsModel+Indicators.swift",
            "Sources/ViewModels/MobileHubCLI.swift", "Sources/ViewModels/MobilePairingModel.swift",
            "Sources/Views/Settings/MobileSettingsView.swift", "Sources/Views/Settings/MobileLinkSheet.swift",
            "Sources/App/AppState+MobileSettings.swift"
        ] {
            for literal in try swiftStringLiterals(in: file, keepSymbols: true) {
                XCTAssertFalse(literal.contains("hubstate.db"), "\(file): \(literal)")
                XCTAssertFalse(literal.contains("MobileHub"), "\(file): \(literal)")
            }
        }
    }
}

private final class BusyProbe: @unchecked Sendable {
    var value = false
}

private actor SleepLog {
    private(set) var all: [Duration] = []
    var count: Int { all.count }
    func add(_ duration: Duration) { all.append(duration) }
}
