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

    func testCompanyAndSlackFlowsShareTheGuard() async {
        let (appState, host, fake) = wired()
        let slack = try? XCTUnwrap(appState.slackConnectFlow)
        let company = appState.companyConnect

        fake.enqueue(inspect)
        host.onCompanyEvent?(.companyLink(flow: "f1", bundle: "eyJ2IjoxfQ"))
        await untilObserved { company?.phase == .confirm }
        XCTAssertEqual(slack?.canStart, false, "a company flow open: no Slack flow starts")

        company?.cancel()
        XCTAssertEqual(slack?.canStart, true)
        host.onEvent?(.link(flow: "s1", teamID: "T0ACME", clientID: "1111.2222"))
        XCTAssertEqual(company?.externalBusy(), true, "a Slack flow open: no chain starts")
    }
}
