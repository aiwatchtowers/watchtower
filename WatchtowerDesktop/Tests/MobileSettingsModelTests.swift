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
        func retryAdoption() async {
            retries += 1
            adoptionState = .done
        }
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
             Model.OffCopy(title: "Mobile sync", detail: "Off. Linked phones are kept.", showsToggle: true, toggleOn: false, managed: false)),
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
        XCTAssertEqual(Model.offCopy("vouch_revoked").detail, "Mobile is off (vouch_revoked).")

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
        XCTAssertEqual(Model.hubLine(state: "starting", reason: nil), "Starting…")
        XCTAssertEqual(Model.hubLine(state: "running", reason: "no_relay_origin"),
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
        let adoption = Adoption(.inProgress(step: "copy"))
        let model = makeModel(adoption: adoption)
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
        "adoption":"done","identity":"keychain","switched_at":"2026-11-02T10:42:00.123Z","switched_by":"AAAA0001",\
        "kept_recordings":{"count":2,"remove_at":"2026-11-14T08:00:00Z","dir":"/tmp/acme-recordings"}}
        """)
        cli.phones(MobileHubFixture.list(MobileHubFixture.phoneA))
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.hubTransport, "relay")
        XCTAssertFalse(model.recordingsOn)
        XCTAssertTrue(model.showsBridgeUnavailable)
        XCTAssertEqual(Model.bridgeUnavailableLine, "iCloud is not reachable from this Mac right now. Relay links keep working.")
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
        XCTAssertEqual(byID["AAAA0001"]?.detailLine, "\(linked) · Relay · switched by Phone A today \(time)")
        XCTAssertEqual(byID["BBBB0002"]?.transportLabel, "iCloud")
        XCTAssertNil(byID["BBBB0002"]?.switchedLine, "not on the transport the switch chose")
        XCTAssertEqual(byID["BBBB0002"]?.detailLine, "\(linked) · iCloud")
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
        await model.setRecordings(false)
        XCTAssertEqual(cli.writes, [["hub", "recordings", "off", "--json"]])

        cli.fail(MobileHubCLI.recordingsArgs(true), stderr: "Error: this host has no transcriber\n")
        cli.status(#"{"state":"running","recordings":"off"}"#)
        await model.setRecordings(true)
        XCTAssertEqual(cli.writes.last, ["hub", "recordings", "on", "--json"])
        XCTAssertEqual(model.recordingsError, "This host has no transcriber.")
        XCTAssertEqual(Model.noTranscriber, "This host has no transcriber.")
        XCTAssertFalse(model.recordingsAvailable, "off-only from now")
        XCTAssertFalse(model.recordingsOn)
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
