import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class AssistantToolsViewModelTests: XCTestCase {
    private let listing = Data("""
    [{"name":"create_target","description":"d1","access":"write","external":false,"surfaces":["main"],"trust":"ask"},
     {"name":"create_jira_issue","description":"d2","access":"write","external":true,"surfaces":["main","target"],"trust":"ask"}]
    """.utf8)

    func testLoadDecodesListing() async {
        let runner = FakeCLIRunner(stdout: listing)
        let vm = AssistantToolsViewModel(cliRunner: runner)
        await vm.load()
        XCTAssertEqual(runner.invocations, [["actions", "tools", "--json"]])
        XCTAssertEqual(vm.rows.map(\.name), ["create_target", "create_jira_issue"])
        XCTAssertTrue(vm.rows[1].external)
        XCTAssertNil(vm.error)
    }

    func testSetTrustRunsCLIThenReloads() async {
        let runner = FakeCLIRunner(stdout: listing)
        let vm = AssistantToolsViewModel(cliRunner: runner)
        await vm.setTrust("create_target", execute: true)
        XCTAssertEqual(runner.invocations.first, ["actions", "trust", "create_target", "execute"])
        XCTAssertEqual(runner.invocations.last, ["actions", "tools", "--json"])
    }

    func testSetTrustSurfacesCLIError() async {
        struct Boom: Error {}
        let vm = AssistantToolsViewModel(cliRunner: FakeCLIRunner(error: Boom()))
        await vm.setTrust("create_jira_issue", execute: true)
        XCTAssertNotNil(vm.error)
    }
}
