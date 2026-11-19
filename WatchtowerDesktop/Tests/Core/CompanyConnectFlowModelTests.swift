import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The company connect flow of screens spec §3 (#1887 Task 23) over a real
/// listener host on a fake child: events come through the host's company
/// handler, commands are read off the child's stdin, and each `company
/// inspect` / `company confirm` run answers from the fake's queue.
@MainActor
final class CompanyConnectFlowModelTests: XCTestCase {
    private typealias Model = CompanyConnectFlowModel
    private let wire = "eyJ2IjoxLCJjb21wYW55IjoiQWNtZSJ9"

    @MainActor
    private struct Rig {
        let model: Model
        let host: SlackConnectListenerHost
        let fake: FakeCLILineStream
        let child: FakeCLILineSession

        func emit(_ event: SlackConnectEvent) { host.onCompanyEvent?(event) }
        var sent: [String] { child.writtenLines }
        /// The one-shot CLI runs (the serve session excluded).
        var runs: [FakeCLILineStream.Invocation] { fake.invocations.filter { $0.args.first == "company" } }
    }

    private func makeRig() async -> Rig {
        let fake = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: fake)
        let model = Model(host: host, makeStreamer: { fake }, makeFlowID: { "chain-1" })
        host.ensureRunning()
        let child = await fake.session(number: 1)
        child.emit(#"{"event":"listening","port":18551}"#)
        await untilObserved { host.state == .listening }
        return Rig(model: model, host: host, fake: fake, child: child)
    }

    private static let allVendors = ["slack", "google", "atlassian", "microsoft", "linear"]

    /// A `company inspect --json` answer for Acme.
    private func inspect(
        state: String = "new",
        vendors: [String] = allVendors,
        connected: [String] = [],
        forbidden: [String] = [],
        changes: String = "[]",
        confluence: Bool = true,
        forced: Bool = false
    ) -> FakeCLILineStream.Reply {
        let list = { (names: [String]) in "[" + names.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        let conn = "{" + connected.map { "\"\($0)\":true" }.joined(separator: ",") + "}"
        let details = #"{"slack":{"team_id":"T0000","client_id":"000.000"},"google":{"client_id":"1234","domain":"example.com"},"#
            + #""atlassian":{"client_id":"9f3a","site":"https://acme.atlassian.net","confluence":\#(confluence)},"#
            + #""microsoft":{"client_id":"m1","tenant_id":"t1"},"linear":{"client_id":"l1"}}"#
        return .init(lines: [#"{"company":"Acme","slug":"acme","state":"\#(state)","forced":\#(forced),"#
                + #""vendors":\#(list(vendors)),"connected":\#(conn),"changes":\#(changes),"#
                + #""forbidden":\#(list(forbidden)),"details":\#(details)}"#])
    }

    private let stored = FakeCLILineStream.Reply(lines: [#"{"result":"stored","slug":"acme","marked":[]}"#])

    /// A link reached the listener and the confirm is up.
    private func linkConfirm(_ rig: Rig, _ reply: FakeCLILineStream.Reply? = nil, flow: String = "f1") async {
        rig.fake.enqueue(reply ?? inspect())
        rig.emit(.companyLink(flow: flow, bundle: wire))
        await untilObserved { rig.model.phase != .idle }
    }

    /// The link's confirm, then **Connect**: the chain runs.
    private func inChain(_ rig: Rig) async {
        await linkConfirm(rig)
        rig.fake.enqueue(stored)
        await rig.model.connect()
        XCTAssertEqual(rig.model.phase, .chain)
    }

    private func vendor(
        _ vendor: CompanyVendor, _ state: CompanyChainState, label: String = "", message: String = "", flow: String = "f1"
    ) -> SlackConnectEvent {
        .companyVendor(CompanyVendorStep(flow: flow, vendor: vendor, state: state, label: label, message: message))
    }

    // MARK: - Confirm

    func testLinkStartsAtConfirm() async throws {
        let rig = await makeRig()
        var shown = 0
        rig.model.onShow = { shown += 1 }
        await linkConfirm(rig)

        XCTAssertEqual(rig.model.phase, .confirm)
        XCTAssertEqual(rig.model.variant, .link)
        XCTAssertTrue(rig.model.showsSheet)
        XCTAssertEqual(shown, 1, "the window comes forward on Connections")
        XCTAssertEqual(rig.model.title, "Connect Acme?")
        XCTAssertEqual(rig.model.body, "A link asks Watchtower to connect your accounts through Acme's apps. "
            + "Connect only if you opened this link yourself.")
        XCTAssertTrue(rig.model.rows.allSatisfy(\.ticked))
        // Nothing before Connect: only the read-only inspect ran, the bundle on stdin.
        XCTAssertEqual(rig.runs.map(\.args), [["company", "inspect", "--json"]])
        XCTAssertEqual(rig.runs.first?.stdin, Data((wire + "\n").utf8))
        XCTAssertEqual(rig.sent, [])

        rig.fake.enqueue(stored)
        await rig.model.connect()
        XCTAssertEqual(rig.runs.last?.args, ["company", "confirm", "--json", "--source", "link"])
        XCTAssertEqual(rig.runs.last?.stdin, Data((wire + "\n").utf8))
        XCTAssertFalse(rig.runs.contains { $0.args.contains(wire) }, "the bundle never goes on argv")
        // The chain answers the link's flow, which releases the held link.
        XCTAssertEqual(rig.sent, [#"{"cmd":"company_connect","flow":"f1","slug":"acme","#
            + #""vendors":["slack","google","atlassian","microsoft","linear"]}"#])
        XCTAssertEqual(rig.model.phase, .chain)
        XCTAssertEqual(rig.model.title, "Connecting Acme")
    }

    func testCancelDismissesTheLink() async {
        let rig = await makeRig()
        await linkConfirm(rig)
        rig.model.cancel()
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertFalse(rig.model.showsSheet)
        XCTAssertEqual(rig.sent, [#"{"cmd":"company_dismiss","flow":"f1"}"#])
        XCTAssertEqual(rig.runs.count, 1, "nothing stored")
    }

    func testConnectNeedsOneTicked() async {
        let rig = await makeRig()
        await linkConfirm(rig, inspect(vendors: ["slack", "google"]))
        XCTAssertTrue(rig.model.canConnect)
        rig.model.toggle(.slack)
        rig.model.toggle(.google)
        XCTAssertFalse(rig.model.canConnect)
        await rig.model.connect()
        XCTAssertEqual(rig.model.phase, .confirm)
        XCTAssertEqual(rig.runs.count, 1)

        rig.model.toggle(.google)
        rig.fake.enqueue(stored)
        await rig.model.connect()
        XCTAssertEqual(rig.sent.last, #"{"cmd":"company_connect","flow":"f1","slug":"acme","vendors":["google"]}"#)
        XCTAssertEqual(rig.model.rows.map(\.vendor), [.google], "the chain lists only what runs")
    }

    func testRowOrderAndDetails() async {
        let rig = await makeRig()
        await linkConfirm(rig, inspect(vendors: ["linear", "microsoft", "atlassian", "google", "slack"]))
        XCTAssertEqual(rig.model.rows.map(\.vendor), [.slack, .google, .atlassian, .microsoft, .linear])
        XCTAssertEqual(rig.model.rows.map(\.title), ["Slack", "Gmail and Calendar", "Jira and Confluence", "Outlook", "Linear"])
        XCTAssertEqual(rig.model.rows.map(rig.model.confirmDetail),
                       ["workspace acme", "example.com", "acme.atlassian.net", "Microsoft 365", "Acme's Linear app"])

        rig.model.cancel()
        await linkConfirm(rig, inspect(confluence: false), flow: "f2")
        XCTAssertEqual(rig.model.rows.first { $0.vendor == .atlassian }?.title, "Jira", "Confluence off: just Jira")
    }

    func testForbiddenVendorIsNotRun() async {
        let rig = await makeRig()
        await linkConfirm(rig, inspect(forbidden: ["linear"]))
        let linear = rig.model.rows.first { $0.vendor == .linear }
        XCTAssertEqual(linear?.forbidden, true)
        XCTAssertEqual(linear?.ticked, false)
        XCTAssertEqual(linear.map(rig.model.confirmDetail), "Blocked by your organization")
        rig.model.toggle(.linear)
        XCTAssertEqual(rig.model.rows.first { $0.vendor == .linear }?.ticked, false, "a locked row cannot be ticked")

        rig.fake.enqueue(stored)
        await rig.model.connect()
        XCTAssertEqual(rig.sent.last, #"{"cmd":"company_connect","flow":"f1","slug":"acme","#
            + #""vendors":["slack","google","atlassian","microsoft"]}"#)
    }

    func testSameBundleAgainDisablesConnected() async {
        let rig = await makeRig()
        await linkConfirm(rig, inspect(state: "same", connected: ["slack", "google"]))
        XCTAssertEqual(rig.model.variant, .again)
        XCTAssertEqual(rig.model.title, "Connect Acme?")
        let slack = rig.model.rows[0]
        XCTAssertTrue(slack.connected)
        XCTAssertFalse(slack.ticked)
        XCTAssertFalse(slack.enabled)
        rig.model.toggle(.slack)
        XCTAssertFalse(rig.model.rows[0].ticked)

        rig.fake.enqueue(.init(lines: [#"{"result":"unchanged","slug":"acme","marked":[]}"#]))
        await rig.model.connect()
        XCTAssertEqual(rig.sent.last, #"{"cmd":"company_connect","flow":"f1","slug":"acme","#
            + #""vendors":["atlassian","microsoft","linear"]}"#)
    }

    func testMDMVariantTitle() async {
        let rig = await makeRig()
        rig.fake.enqueue(inspect(state: "same", connected: ["slack"], forced: true))
        await rig.model.connectAll(slug: "acme")
        XCTAssertEqual(rig.runs.last?.args, ["company", "inspect", "--json", "--slug", "acme"])
        XCTAssertNil(rig.runs.last?.stdin)
        XCTAssertEqual(rig.model.variant, .mdm)
        XCTAssertEqual(rig.model.title, "Acme — Connect all")
        XCTAssertTrue(rig.model.managed)
        XCTAssertEqual(rig.model.body, "Your organization set up Acme's apps on this Mac.")

        await rig.model.connect()
        XCTAssertEqual(rig.runs.count, 1, "the organization's company is never confirmed: it is the profile's")
        XCTAssertEqual(rig.sent, [#"{"cmd":"company_connect","flow":"chain-1","slug":"acme","#
            + #""vendors":["google","atlassian","microsoft","linear"]}"#])
    }

    func testCodeVariant() async {
        let rig = await makeRig()
        rig.fake.enqueue(inspect())
        let error = await rig.model.paste("  eyJ2IjoxLCJj\nb21wYW55IjoiQWNtZSJ9 ")
        XCTAssertNil(error)
        XCTAssertEqual(rig.runs.last?.stdin, Data((wire + "\n").utf8), "a wrapped code is unwrapped")
        XCTAssertEqual(rig.model.variant, .code)
        XCTAssertEqual(rig.model.body, "This code connects your accounts through Acme's apps.")

        rig.fake.enqueue(stored)
        await rig.model.connect()
        XCTAssertEqual(rig.runs.last?.args, ["company", "confirm", "--json", "--source", "code"])
        XCTAssertEqual(rig.sent.last?.contains(#""flow":"chain-1""#), true, "a code has no link flow")
    }

    func testPasteRejectsOtherText() async {
        let rig = await makeRig()
        let invalid = Model.codeInvalid
        for text in ["hello", "T0ACME:1111.2222", "http://127.0.0.1:18551/slack/connect?team=T0ACME&client=1.2", ""] {
            let error = await rig.model.paste(text)
            XCTAssertEqual(error, invalid, text)
        }
        XCTAssertEqual(rig.runs.count, 0, "nothing ran for text that is no bundle")

        // A bundle Go refuses is the same field error; nothing opens.
        rig.fake.enqueue(.init(lines: [#"{"refused":"damaged","company":"","slug":"","state":"","forced":false,"vendors":[],"#
            + #""connected":{},"changes":[],"forbidden":[],"details":{}}"#]))
        let refused = await rig.model.paste(wire)
        XCTAssertEqual(refused, invalid)
        XCTAssertEqual(rig.model.phase, .idle)

        // A link pasted whole reads its b parameter.
        XCTAssertEqual(Model.wire(fromInput: "http://127.0.0.1:18551/company/connect?b=\(wire)"), wire)
        XCTAssertTrue(Model.isCompanyInput(wire))
        XCTAssertFalse(Model.isCompanyInput("T0ACME:1111.2222"))
    }

    func testCLIFailureIsShownAndTheLinkAnswered() async {
        let rig = await makeRig()
        rig.fake.enqueue(.init(lines: [], exitCode: 1, stderr: "database is locked"))
        rig.emit(.companyLink(flow: "f1", bundle: wire))
        await untilObserved { rig.model.phase != .idle }
        XCTAssertEqual(rig.model.phase, .problem("Watchtower could not read this company setup: database is locked."))
        XCTAssertEqual(rig.sent, [#"{"cmd":"company_dismiss","flow":"f1"}"#], "the next link may wait")
        rig.model.finish()
        XCTAssertFalse(rig.model.showsSheet)
    }

    // MARK: - One flow at a time

    func testSecondLinkWhileRunningIsRefused() async {
        let rig = await makeRig()
        await inChain(rig)
        rig.model.close()
        var shown = 0
        rig.model.onShow = { shown += 1 }
        rig.emit(.companyLink(flow: "f2", bundle: wire))
        XCTAssertEqual(rig.sent.last, #"{"cmd":"company_dismiss","flow":"f2"}"#)
        XCTAssertEqual(rig.model.phase, .chain, "the running flow stays")
        XCTAssertTrue(rig.model.showsSheet, "and its sheet comes back")
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(rig.runs.count, 2, "the second link was never read")

        // While a confirm is open, too.
        let other = await makeRig()
        await linkConfirm(other)
        other.emit(.companyLink(flow: "f3", bundle: wire))
        XCTAssertEqual(other.sent, [#"{"cmd":"company_dismiss","flow":"f3"}"#])
        XCTAssertEqual(other.model.phase, .confirm)
        let pasted = await other.model.paste(wire)
        XCTAssertEqual(pasted, Model.anotherRunning)
    }

    func testBusyAnswerRefusesTheChain() async {
        let rig = await makeRig()
        await linkConfirm(rig)
        rig.fake.enqueue(stored)
        await rig.model.connect()
        rig.emit(.busy(flow: "slack-flow"))
        XCTAssertEqual(rig.model.phase, .problem(Model.anotherRunning))

        // A busy naming our own chain answers someone else's start: ignored.
        let other = await makeRig()
        await inChain(other)
        other.emit(.busy(flow: "f1"))
        XCTAssertEqual(other.model.phase, .chain)
    }

    func testSharedGuardRefusesConnect() async {
        let rig = await makeRig()
        await linkConfirm(rig)
        rig.model.externalBusy = { true }
        await rig.model.connect()
        XCTAssertEqual(rig.model.connectError, Model.anotherRunning)
        XCTAssertEqual(rig.model.phase, .confirm)
        XCTAssertEqual(rig.runs.count, 1, "nothing stored")
    }

    // MARK: - The chain

    func testCloseKeepsChainRunning() async {
        let rig = await makeRig()
        await inChain(rig)
        rig.model.close()
        XCTAssertFalse(rig.model.showsSheet)
        XCTAssertEqual(rig.model.phase, .chain)
        XCTAssertTrue(rig.model.isRunning)
        XCTAssertEqual(rig.sent.count, 1, "closing sends neither Skip nor Stop")

        rig.emit(vendor(.slack, .waiting))
        XCTAssertEqual(rig.model.currentVendor, .slack, "the Companies card shows Connecting… Slack")
        rig.emit(vendor(.slack, .connected, label: "Acme"))
        rig.emit(vendor(.google, .waiting))
        XCTAssertEqual(rig.model.currentVendor, .google)
    }

    func testCancelledVendorContinues() async {
        let rig = await makeRig()
        await inChain(rig)
        rig.emit(vendor(.slack, .waiting))
        rig.emit(vendor(.slack, .connected, label: "alice"))
        rig.emit(vendor(.google, .waiting))
        rig.emit(vendor(.google, .cancelled, message: "you did not allow Watchtower"))
        rig.emit(vendor(.atlassian, .waiting))

        let lines = rig.model.rows.map { rig.model.progress($0) }
        XCTAssertEqual(lines.map(\.mark), [.done, .failed, .running, .pending, .pending])
        XCTAssertEqual(lines.map(\.detail), [
            "Connected as alice",
            "You did not allow Watchtower. Connect it later from Connections.",
            "Finish in your browser: Atlassian asks you to allow Watchtower.",
            "Next",
            nil
        ])
        XCTAssertEqual(rig.model.phase, .chain)

        rig.emit(vendor(.atlassian, .failed, message: "the request timed out"))
        XCTAssertEqual(rig.model.progress(rig.model.rows[2]).detail,
                       "Could not connect: the request timed out. Connect it later from Connections.")
    }

    func testEmptyLabelSaysConnected() async {
        let rig = await makeRig()
        await inChain(rig)
        rig.emit(vendor(.google, .connected))
        XCTAssertEqual(rig.model.progress(rig.model.rows[1]).detail, "Connected")
    }

    func testSkipNamesTheWaitingVendorAndStopEndsTheChain() async {
        let rig = await makeRig()
        await inChain(rig)
        rig.model.skipCurrent()
        XCTAssertEqual(rig.sent.count, 1, "nothing waits yet: no Skip")
        rig.emit(vendor(.slack, .waiting))
        rig.model.skipCurrent()
        XCTAssertEqual(rig.sent.last, #"{"cmd":"company_skip","flow":"f1","vendor":"slack"}"#)
        rig.model.stop()
        XCTAssertEqual(rig.sent.last, #"{"cmd":"company_stop","flow":"f1"}"#)
    }

    func testDoneAllAndPartly() async {
        let rig = await makeRig()
        var ended = 0
        rig.model.onChainEnded = { ended += 1 }
        await inChain(rig)
        for vendor in [CompanyVendor.slack, .google, .atlassian, .microsoft] {
            rig.emit(self.vendor(vendor, .connected))
        }
        rig.emit(vendor(.linear, .skipped))
        rig.fake.enqueue(inspect(state: "same", connected: ["slack", "google", "atlassian", "microsoft"]))
        rig.emit(.companyDone(flow: "f1", states: [.slack: .connected, .google: .connected, .atlassian: .connected,
                                                   .microsoft: .connected, .linear: .skipped]))
        XCTAssertEqual(rig.model.phase, .done)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(rig.model.title, "Acme is partly connected")
        XCTAssertEqual(rig.model.body, "The first sync starts now. What is not connected waits in Connections with a Connect button.")
        XCTAssertEqual(rig.model.progress(rig.model.rows[4]).mark, .skipped)
        XCTAssertEqual(rig.model.progress(rig.model.rows[4]).detail, "Skipped")
        XCTAssertNil(rig.model.progress(rig.model.rows[0]).detail)
        XCTAssertFalse(rig.model.isRunning)
        rig.model.finish()
        XCTAssertEqual(rig.model.phase, .idle)

        let all = await makeRig()
        await linkConfirm(all, inspect(vendors: ["slack"]))
        all.fake.enqueue(stored)
        await all.model.connect()
        all.emit(vendor(.slack, .connected, label: "Acme"))
        all.fake.enqueue(inspect(state: "same", vendors: ["slack"], connected: ["slack"]))
        all.emit(.companyDone(flow: "f1", states: [.slack: .connected]))
        XCTAssertEqual(all.model.title, "Acme is connected")
    }

    /// A Slack sign-in that finished just as Skip arrived is stored while the
    /// chain says skipped: the done sheet follows Go's accounts, as
    /// Connections does.
    func testSkippedButStoredShowsConnected() async {
        let rig = await makeRig()
        await linkConfirm(rig, inspect(vendors: ["slack", "google"]))
        rig.fake.enqueue(stored)
        await rig.model.connect()
        rig.emit(vendor(.slack, .waiting))
        rig.emit(vendor(.slack, .skipped))
        rig.emit(vendor(.google, .connected))
        rig.fake.enqueue(inspect(state: "same", vendors: ["slack", "google"], connected: ["slack", "google"]))
        rig.emit(.companyDone(flow: "f1", states: [.slack: .skipped, .google: .connected]))
        await untilObserved { rig.model.rows.first?.state == .connected(label: "") }
        XCTAssertEqual(rig.runs.last?.args, ["company", "inspect", "--json", "--slug", "acme"])
        XCTAssertEqual(rig.model.title, "Acme is connected")
    }

    func testListenerDeathEndsTheChain() async {
        let rig = await makeRig()
        await inChain(rig)
        rig.emit(vendor(.slack, .connected, label: "Acme"))
        rig.emit(vendor(.google, .waiting))
        rig.fake.enqueue(inspect(state: "same", connected: ["slack"]))
        rig.host.onCompanyChildEnded?()
        XCTAssertEqual(rig.model.phase, .done)
        XCTAssertEqual(rig.model.rows.map { rig.model.progress($0).mark }, [.done, .failed, .failed, .failed, .failed])
        XCTAssertEqual(rig.model.progress(rig.model.rows[1]).detail, "Not connected")
        XCTAssertFalse(rig.model.isRunning, "no auto-resume")
    }

    func testEventsOfAnotherFlowAreIgnored() async {
        let rig = await makeRig()
        await inChain(rig)
        rig.emit(vendor(.slack, .connected, flow: "other"))
        rig.emit(.companyDone(flow: "other", states: [:]))
        XCTAssertEqual(rig.model.phase, .chain)
        XCTAssertEqual(rig.model.rows[0].state, .pending)
    }

    // MARK: - Stored companies

    func testConnectRestStartsWithoutConfirm() async {
        let rig = await makeRig()
        rig.fake.enqueue(inspect(state: "same", connected: ["slack", "atlassian"], forbidden: ["linear"]))
        await rig.model.connectRest(slug: "acme")
        XCTAssertEqual(rig.model.phase, .chain)
        XCTAssertEqual(rig.sent, [#"{"cmd":"company_connect","flow":"chain-1","slug":"acme","#
            + #""vendors":["google","microsoft"]}"#])
    }

    func testReloginRunsTheNamedVendors() async {
        let rig = await makeRig()
        rig.fake.enqueue(inspect(state: "same", connected: ["slack"]))
        await rig.model.relogin(slug: "acme", vendors: [.atlassian, .google])
        XCTAssertEqual(rig.sent, [#"{"cmd":"company_connect","flow":"chain-1","slug":"acme","vendors":["google","atlassian"]}"#])
        XCTAssertEqual(rig.model.rows.map(\.vendor), [.google, .atlassian])
    }

    // MARK: - Replace

    private let changes = #"[{"vendor":"atlassian","field":"client_id","old":"9f3a…c21","new":"7b20…e04"},"#
        + #"{"vendor":"google","field":"client_secret","old":"","new":""}]"#

    func testChangedBundleNeedsReplace() async {
        let rig = await makeRig()
        var changed = 0
        rig.model.onCompaniesChanged = { changed += 1 }
        await linkConfirm(rig, inspect(state: "changed", changes: changes))
        guard case let .replace(list) = rig.model.phase else { return XCTFail("\(rig.model.phase)") }
        XCTAssertEqual(list.map(\.line), ["Atlassian app: 9f3a…c21 → 7b20…e04", "Google client secret changed"])
        XCTAssertEqual(rig.model.title, "Acme's link changes its apps")
        XCTAssertEqual(rig.runs.count, 1, "nothing stored without Replace")

        rig.fake.enqueue(.init(lines: [#"{"result":"stored","slug":"acme","marked":[{"source":"jira","id":3}]}"#]))
        await rig.model.replace()
        XCTAssertEqual(rig.runs.last?.args, ["company", "confirm", "--json", "--source", "link", "--replace"])
        XCTAssertEqual(rig.sent, [#"{"cmd":"company_dismiss","flow":"f1"}"#])
        XCTAssertEqual(rig.model.phase, .idle, "nothing else runs")
        XCTAssertEqual(changed, 1)
    }

    func testKeepCurrentIsDefault() async {
        let rig = await makeRig()
        await linkConfirm(rig, inspect(state: "changed", changes: changes))
        // The sheet's close (Esc) is Keep current; so is the button.
        rig.model.close()
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertEqual(rig.sent, [#"{"cmd":"company_dismiss","flow":"f1"}"#])
        XCTAssertEqual(rig.runs.count, 1, "nothing stored")

        await linkConfirm(rig, inspect(state: "changed", changes: changes), flow: "f2")
        rig.model.keepCurrent()
        XCTAssertEqual(rig.sent.last, #"{"cmd":"company_dismiss","flow":"f2"}"#)
        XCTAssertEqual(rig.runs.count, 2)
    }

    func testForcedCompanyNeverAsksReplace() async {
        let rig = await makeRig()
        await linkConfirm(rig, inspect(state: "changed", changes: changes, forced: true))
        XCTAssertEqual(rig.model.phase, .confirm)
    }

    // MARK: - Wire

    func testDecodesCompanyEvents() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("internal/slackconnect/testdata/company_events.jsonl"),
                              encoding: .utf8)
        let events = try text.split(separator: "\n").map { try JSONDecoder().decode(SlackConnectEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(events.count, 11)
        guard case let .companyLink(flow, bundle) = events[0] else { return XCTFail("\(events[0])") }
        XCTAssertEqual(flow, "flow-1")
        XCTAssertTrue(Model.isCompanyInput(bundle), "the listener's wire reads as a code too")
        XCTAssertEqual(events[2], .companyVendor(CompanyVendorStep(flow: "flow-1", vendor: .slack, state: .connected, label: "Acme")))
        XCTAssertEqual(events[10], .companyDone(flow: "flow-1", states: [
            .atlassian: .failed, .google: .cancelled, .linear: .skipped, .microsoft: .skipped, .slack: .connected
        ]))
        let states = Set(events.compactMap { if case let .companyVendor(step) = $0 { step.state } else { nil } })
        XCTAssertEqual(states, [.waiting, .connected, .cancelled, .failed, .skipped])
        for event in events {
            XCTAssertEqual(try JSONDecoder().decode(SlackConnectEvent.self, from: JSONEncoder().encode(event)), event)
        }
        let unknown = #"{"event":"company_vendor","flow":"f","vendor":"slack","state":"brand_new","label":"","message":""}"#
        XCTAssertEqual(try JSONDecoder().decode(SlackConnectEvent.self, from: Data(unknown.utf8)),
                       .companyVendor(CompanyVendorStep(flow: "f", vendor: .slack, state: .failed)))
    }

    func testCompanyCommandLines() throws {
        func text(_ cmd: SlackConnectCommand) throws -> String? { String(bytes: try cmd.line(), encoding: .utf8) }
        XCTAssertEqual(try text(.companyConnect(flow: "f", slug: "acme", vendors: [.slack, .linear])),
                       #"{"cmd":"company_connect","flow":"f","slug":"acme","vendors":["slack","linear"]}"# + "\n")
        XCTAssertEqual(try text(.companySkip(flow: "f", vendor: nil)), #"{"cmd":"company_skip","flow":"f"}"# + "\n")
        XCTAssertEqual(try text(.companySkip(flow: "f", vendor: .google)),
                       #"{"cmd":"company_skip","flow":"f","vendor":"google"}"# + "\n")
        XCTAssertEqual(try text(.companyStop(flow: "f")), #"{"cmd":"company_stop","flow":"f"}"# + "\n")
        XCTAssertEqual(try text(.companyDismiss(flow: "f")), #"{"cmd":"company_dismiss","flow":"f"}"# + "\n")
    }

    /// The mockups' words (`Tests/DesignShots/CompanySetupMockCopy.swift`;
    /// `CompanySetupMockCopyTests.testConnectCopyLivesInTheFlowModel` holds
    /// those equal to the model's).
    func testStringsEqualMockCopy() {
        XCTAssertEqual(Model.confirmCaption, "Each service opens its own sign-in page in your browser, one after another.")
        XCTAssertEqual(Model.alreadyConnected, "Connected")
        XCTAssertEqual(Model.chainNext, "Next")
        XCTAssertEqual(Model.chainDenied, "You did not allow Watchtower. Connect it later from Connections.")
        XCTAssertEqual(Model.chainCaption, "You can close this window: the chain goes on and Connections shows where it is.")
        XCTAssertEqual(Model.chainDoneBody,
                       "The first sync starts now. What is not connected waits in Connections with a Connect button.")
        XCTAssertEqual(Model.skipped, "Skipped")
        XCTAssertEqual(Model.notConnected, "Not connected")
        XCTAssertEqual(Model.replaceBody, "Keep your current setup unless your admin told you the apps changed. Replacing asks "
            + "you to log in again to what changed.")
        XCTAssertEqual(Model.replaceCaption, "Nothing leaves this Mac either way.")
        XCTAssertEqual(Model.codeInvalid, CompanyConnectionsPresentation.codeInvalid)
        XCTAssertEqual([Model.cancelTitle, Model.connectTitle, Model.stopTitle, Model.skipTitle, Model.doneTitle,
                        Model.replaceTitle, Model.keepCurrentTitle],
                       ["Cancel", "Connect", "Stop", "Skip this service", "Done", "Replace", "Keep current"])
        XCTAssertEqual(Model.Change(vendor: "google", field: "client_id", old: "1234-abcd…", new: "5678-efgh…").line,
                       "Google client: 1234-abcd… → 5678-efgh…")
    }
}
