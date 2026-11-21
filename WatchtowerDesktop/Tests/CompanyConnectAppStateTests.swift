import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// `AppState.companyConnect` (#1887 Task 23): where a company link's sheet
/// shows, and the one-flow-at-a-time guard it shares with the Slack flow.
@MainActor
final class CompanyConnectAppStateTests: XCTestCase {
    private let inspect = FakeCLILineStream.Reply(lines: [#"{"company":"Acme","slug":"acme","state":"new","forced":false,"#
        + #""vendors":["slack"],"connected":{},"changes":[],"forbidden":[],"details":{}}"#])

    private func wired() -> (AppState, SlackConnectListenerHost, FakeCLILineStream) {
        let appState = AppState.isolated()
        let fake = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: fake)
        appState.slackConnectFlow = appState.makeSlackConnectFlow(host: host)
        appState.companyConnect = appState.makeCompanyConnectFlow(host: host) { fake }
        return (appState, host, fake)
    }

    func testCompanyLinkOpensConnections() async {
        let (appState, host, fake) = wired()
        appState.selectedDestination = .home
        fake.enqueue(inspect)
        host.onCompanyEvent?(.companyLink(flow: "f1", bundle: "eyJ2IjoxfQ"))
        await untilObserved { appState.companyConnect?.showsSheet == true }
        XCTAssertEqual(appState.selectedDestination, .connections)

        // On another Connections page already: it stays there.
        appState.companyConnect?.cancel()
        appState.openConnections(.jira)
        fake.enqueue(inspect)
        host.onCompanyEvent?(.companyLink(flow: "f2", bundle: "eyJ2IjoxfQ"))
        await untilObserved { appState.companyConnect?.showsSheet == true }
        XCTAssertEqual(appState.selectedConnection, .jira)
    }

    func testPendingCompanySheetShowsAfterOnboardingEnds() async {
        let (appState, host, fake) = wired()
        appState.needsOnboarding = true
        appState.selectedDestination = .home
        fake.enqueue(inspect)
        host.onCompanyEvent?(.companyLink(flow: "f1", bundle: "eyJ2IjoxfQ"))
        await untilObserved { appState.companyConnect?.showsSheet == true }
        XCTAssertNotEqual(appState.selectedDestination, .connections, "onboarding stays on screen")

        appState.needsOnboarding = false
        XCTAssertEqual(appState.selectedDestination, .connections)
    }

    /// Onboarding's Slack field has no Connections tab to show a company
    /// confirm on: the code is answered in the field, nothing opens.
    func testCompanyCodeInOnboardingSaysWhereItGoes() async throws {
        let (appState, _, fake) = wired()
        appState.needsOnboarding = true
        let slack = try XCTUnwrap(appState.slackConnectFlow)
        slack.pasteText = "eyJ2IjoxfQ"
        slack.connectPasted()
        await untilObserved { slack.pasteError != nil }
        XCTAssertEqual(slack.pasteError, CompanyConnectFlowModel.pasteDuringOnboarding)
        XCTAssertEqual(appState.companyConnect?.phase, .idle)
        XCTAssertTrue(fake.invocations.isEmpty)
    }

    /// A20 through the production wiring: a company code in Slack's field
    /// opens the company confirm and clears the field, no error.
    func testCompanyCodeInSlackFieldOpensTheConfirm() async throws {
        let (appState, _, fake) = wired()
        let slack = try XCTUnwrap(appState.slackConnectFlow)
        fake.enqueue(inspect)
        slack.pasteText = "eyJ2IjoxfQ"
        slack.connectPasted()
        await untilObserved { slack.pasteText.isEmpty }
        XCTAssertNil(slack.pasteError)
        XCTAssertEqual(appState.companyConnect?.phase, .confirm)
    }

    func testCompanyAndSlackFlowsShareTheGuard() async throws {
        let (appState, host, fake) = wired()
        let slack = try XCTUnwrap(appState.slackConnectFlow)
        let company = appState.companyConnect

        fake.enqueue(inspect)
        host.onCompanyEvent?(.companyLink(flow: "f1", bundle: "eyJ2IjoxfQ"))
        await untilObserved { company?.phase == .confirm }
        XCTAssertEqual(slack.canStart, false, "a company flow open: no Slack flow starts")

        // A Slack link while the company confirm is open is refused, not a second sheet.
        host.onEvent?(.link(flow: "s0", teamID: "T0ACME", clientID: "1111.2222"))
        XCTAssertEqual(slack.showsSheet, false)

        company?.cancel()
        XCTAssertEqual(slack.canStart, true)
        host.onEvent?(.link(flow: "s1", teamID: "T0ACME", clientID: "1111.2222"))
        XCTAssertEqual(company?.externalBusy(), true, "a Slack flow open: no chain starts")
        // And a company link then is answered at once.
        host.onCompanyEvent?(.companyLink(flow: "f2", bundle: "eyJ2IjoxfQ"))
        XCTAssertEqual(company?.phase, .idle)
    }

    // MARK: - The card's waiting sign-in (#2132 C1)

    /// A chain left running behind a closed sheet: the card names the vendor
    /// it waits on, and its Cancel is the chain's Stop plus one re-read of
    /// the companies — the chain ends with no problem and the card's line goes.
    func testCardCancelStopsTheHiddenChain() async throws {
        let (appState, host, fake) = wired()
        let zoneCLI = FakeCLILineStream(replies: Array(repeating: .init(lines: [], exitCode: 1), count: 4))
        appState.companiesZone = CompaniesZoneModel { zoneCLI }
        let lists = { zoneCLI.invocations.filter { $0.args.starts(with: ["company", "list"]) }.count }
        host.ensureRunning()
        let child = await fake.session(number: 1)
        child.emit(#"{"event":"listening","port":18551}"#)
        await untilObserved { host.state == .listening }
        let flow = try XCTUnwrap(appState.companyConnect)
        fake.enqueue(inspect)
        host.onCompanyEvent?(.companyLink(flow: "f1", bundle: "eyJ2IjoxfQ"))
        await untilObserved { flow.phase == .confirm }
        fake.enqueue(.init(lines: [#"{"result":"stored","slug":"acme","marked":[]}"#]))
        await flow.connect()
        XCTAssertEqual(flow.phase, .chain)
        await zoneCLI.signal.until { lists() >= 1 } // the store's own re-read
        host.onCompanyEvent?(.companyVendor(CompanyVendorStep(flow: "f1", vendor: .slack, state: .waiting, label: "", message: "")))
        XCTAssertNil(appState.companyConnecting, "the open sheet shows the chain itself")

        flow.close()
        XCTAssertEqual(appState.companyConnecting?.slug, "acme")
        XCTAssertEqual(appState.companyConnecting?.vendor, .slack)

        let before = lists()
        appState.companiesZoneActions.stopChain()
        XCTAssertEqual(child.writtenLines.last, #"{"cmd":"company_stop","flow":"f1"}"#)
        await zoneCLI.signal.until { lists() >= before + 1 }
        XCTAssertEqual(lists(), before + 1, "Cancel re-reads the companies once")
        fake.enqueue(inspect)
        host.onCompanyEvent?(.companyDone(flow: "f1", states: [.slack: .skipped]))
        XCTAssertEqual(flow.phase, .done)
        XCTAssertFalse(flow.showsSheet, "a stop from the card brings no sheet back")
        XCTAssertNil(appState.companyConnecting)
        XCTAssertNil(flow.connectError)
    }

    // MARK: - Connect this Mac after Publish (#1887 Task 22)

    /// A wizard model over a scripted CLI: Linear only (checked, so Connect
    /// this Mac has it to offer), published as acme when `published` is true.
    private func setup(published: Bool) async -> CompanySetupWizardModel {
        let cli = CompanyScriptedCLI()
        let model = CompanySetupWizardModel(streamer: cli, slack: SlackAppSetupModel(streamer: cli, mode: .wizard))
        await model.open()
        model.toggle(.linear)
        model.publishName = "Acme"
        await model.next()
        model.createNew()
        model.setField(.linear, .clientID, "lin-0000-acme")
        cli.on(["company", "check", "linear"], [#"{"result":"ok","checked":true}"#])
        await model.next()
        await untilObserved { model.current == .denyList }
        await model.next()
        if published {
            cli.on(["company", "publish"], [#"{"result":"no_slack","slug":"acme","link":"l","code":"c"}"#])
            await model.next()
        }
        return model
    }

    /// The listener is not up: no company connect flow, the button is hidden.
    func testConnectThisMacHiddenWithoutTheFlow() {
        let appState = AppState.isolated()
        XCTAssertNil(appState.companyConnect)
        XCTAssertNil(appState.connectThisMacAction)
    }

    /// After Publish it opens the same-bundle confirm for the published slug.
    func testConnectThisMacOpensTheSameBundleConfirm() async throws {
        let (appState, _, fake) = wired()
        appState.companySetup = await setup(published: true)
        XCTAssertEqual(appState.companySetup.primary.title, "Connect this Mac")
        XCTAssertTrue(appState.companySetup.primary.enabled, "the page shows it")
        let action = try XCTUnwrap(appState.connectThisMacAction)
        fake.enqueue(FakeCLILineStream.Reply(lines: [#"{"company":"Acme","slug":"acme","state":"same","forced":false,"#
            + #""vendors":["linear"],"connected":{},"changes":[],"forbidden":[],"details":{}}"#]))
        action()
        await untilObserved { appState.companyConnect?.phase == .confirm }
        XCTAssertEqual(fake.invocations.last?.args, ["company", "inspect", "--json", "--slug", "acme"])
        XCTAssertEqual(appState.companyConnect?.variant, .again)
        XCTAssertEqual(appState.companyConnect?.phase, .confirm)
    }

    /// Before Publish went through it does nothing.
    func testConnectThisMacBeforePublishDoesNothing() async {
        let (appState, _, fake) = wired()
        appState.companySetup = await setup(published: false)
        let before = fake.invocations.count
        await appState.connectThisMac()
        XCTAssertEqual(fake.invocations.count, before)
        XCTAssertEqual(appState.companyConnect?.phase, .idle)
    }
}
