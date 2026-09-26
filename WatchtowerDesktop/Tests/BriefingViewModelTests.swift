import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

// MARK: - BriefingViewModelTests

@MainActor
final class BriefingViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - generateBriefing

    /// OWNER-02: `briefing generate` with no owner exits non-zero; its stderr
    /// must reach `generateError` instead of being thrown away.
    func testOwner02GenerateSurfacesCLIStderr() async throws {
        let cli = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
            code: 1, stderr: "no owner identity: connect Slack, Google or Jira first"
        ))
        let vm = BriefingViewModel(dbManager: dbManager, cliRunner: cli)

        await vm.generateBriefing()

        XCTAssertEqual(cli.invocations, [["briefing", "generate"]])
        XCTAssertFalse(vm.isGenerating)
        let message = try XCTUnwrap(vm.generateError)
        XCTAssertTrue(message.contains("no owner identity: connect Slack, Google or Jira first"), message)
    }

    /// A clean run clears a previous failure and leaves the spinner off.
    func testGenerateSuccessClearsPreviousError() async throws {
        let cli = FakeCLIRunner()
        let vm = BriefingViewModel(dbManager: dbManager, cliRunner: cli)
        vm.generateError = "stale"

        await vm.generateBriefing()

        XCTAssertEqual(cli.invocations, [["briefing", "generate"]])
        XCTAssertFalse(vm.isGenerating)
        XCTAssertNil(vm.generateError)
    }

    /// No CLI binary → a visible error and no run.
    func testGenerateWithoutBinaryReportsNotFound() async throws {
        let vm = BriefingViewModel(dbManager: dbManager, cliRunner: nil)

        await vm.generateBriefing()

        XCTAssertFalse(vm.isGenerating)
        XCTAssertEqual(vm.generateError, "watchtower binary not found")
    }
}
