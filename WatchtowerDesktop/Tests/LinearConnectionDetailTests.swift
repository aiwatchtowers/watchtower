import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Connections → Linear grouped by company (company screens spec §4.2,
/// #1887 Task 25a): a stored company with Linear and no workspace shows a
/// **Not connected** row whose **Connect** runs that vendor's login through
/// the company's app, without a confirm.
@MainActor
final class LinearConnectionDetailTests: XCTestCase {
    static let acmeWithLinear = #"{"companies":[{"slug":"acme","company":"Acme","forced":false,"personal":false,"#
        + #""vendors":{"linear":{"client_id":"lin-1"}}}],"errors":[],"draft":{"state":"none"}}"#

    /// AppState with a company connect flow and a Companies zone on one fake CLI.
    static func wired() -> (AppState, FakeCLILineStream) {
        let appState = AppState.isolated()
        appState.sharedConfig = ConfigService(configPath: NSTemporaryDirectory() + "watchtower-tests-\(UUID().uuidString).yaml")
        let fake = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: fake)
        appState.slackConnectFlow = appState.makeSlackConnectFlow(host: host)
        appState.companyConnect = appState.makeCompanyConnectFlow(host: host) { fake }
        appState.companiesZone = CompaniesZoneModel { fake }
        return (appState, fake)
    }

    func testNotConnectedRowConnects() async throws {
        let (appState, fake) = Self.wired()
        appState.linearAccountsViewModel = LinearAccountsViewModel(daemon: FakeDaemonRestarter()) { nil }
        fake.enqueue(.init(lines: [Self.acmeWithLinear]))
        await appState.companiesZone.reload()

        let groups = appState.companyAccountGroups(.linear)
        XCTAssertEqual(groups.map(\.title), ["Acme"])
        XCTAssertEqual(groups.first?.caption, "Acme's Linear app")
        XCTAssertEqual(groups.first?.rows, [.notConnected(.linear)])

        let view = LinearConnectionDetail().environment(appState)
        XCTAssertNoThrow(try view.inspect().find(text: CompanyConnectionsPresentation.rowNotConnected))
        XCTAssertThrowsError(try view.inspect().find(text: LinearConnectionDetail.noWorkspaces),
                             "a company's Not connected row is not \"nothing connected\"")
        try view.inspect().find(button: RowStatus.Action.connect.title).tap()
        await fake.signal.until { fake.invocations.contains { $0.args.starts(with: ["company", "inspect"]) } }
        let inspect = try XCTUnwrap(fake.invocations.last { $0.args.starts(with: ["company", "inspect"]) })
        XCTAssertEqual(inspect.args, ["company", "inspect", "--json", "--slug", "acme"],
                       "the company's stored bundle, never a confirm over a link")
        fake.sessions.last?.exit(code: 1) // ends the read; the flow shows its problem
        await untilObserved { appState.companyConnect?.isRunning == false }
    }

    /// No company and no workspace: the plain empty line and Add.
    func testNoCompanyNoWorkspaceIsTheEmptyLine() throws {
        let (appState, _) = Self.wired()
        appState.linearAccountsViewModel = LinearAccountsViewModel(daemon: FakeDaemonRestarter()) { nil }
        let view = LinearConnectionDetail().environment(appState)
        XCTAssertNoThrow(try view.inspect().find(text: LinearConnectionDetail.noWorkspaces))
        XCTAssertNoThrow(try view.inspect().find(text: CompanyConnectionsPresentation.addAccountTitle))
        XCTAssertThrowsError(try view.inspect().find(button: RowStatus.Action.connect.title))
    }
}
