import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The reviewed session's folder for the reviewer's thread key (#2003): a
/// home-folder session uses the page's home status; a session of another
/// bench folder reads that folder's own status, never home's.
@MainActor
final class WorkbenchesViewModelReviewFolderTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ReviewFolderTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private static func status(branch: String) -> Data {
        Data(#"""
            {"workbench_id":1,"git_available":true,"git":true,"branch":"\#(branch)","head":"a1b2c3d","dirty":false,
             "changes":0,"top_level":"/tmp/hub","git_dir":"/tmp/hub/.git","common_dir":"/tmp/hub/.git",
             "status_ok":true,"status_error":""}
            """#.utf8)
    }

    func testAnotherFoldersSessionReadsThatFoldersStatus() async throws {
        let (bench, homeSession, hubSession) = try await pool.write { db -> (Int64, Int64, Int64) in
            let bench = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme")
            try db.execute(sql: """
                INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
                VALUES (?, '/tmp/hub', 1, 'owner', 'hub')
                """, arguments: [bench])
            let hub = db.lastInsertedRowID
            let home = try TerminalSessionQueries.create(db, .init(projectID: bench, kind: .shell, title: "a", folderPath: "/tmp/acme"))
            let inHub = try TerminalSessionQueries.create(db, .init(projectID: bench, kind: .shell, title: "h", folderPath: "/tmp/hub",
                                                                    workbenchFolderID: hub))
            return (bench, home.id, inHub.id)
        }
        let runner = FakeCLIRunner(stdout: Self.status(branch: "feature/hub"))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        _ = await vm.loadSessions(projectID: bench)

        let before = runner.invocations.count
        let home = await vm.reviewedFolder(sessionID: homeSession, projectID: bench)
        XCTAssertEqual(home, .home)
        XCTAssertEqual(runner.invocations.count, before, "home's status is the page's own")

        let hub = await vm.reviewedFolder(sessionID: hubSession, projectID: bench)
        guard case let .other(status) = hub else { return XCTFail("a hub session is another folder's: \(String(describing: hub))") }
        XCTAssertEqual(status?.branch, "feature/hub")
        XCTAssertEqual(runner.invocations.last, ["workbench", "git", "status", "--workbench", String(bench), "--folder", "/tmp/hub", "--json"])

        let broken = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "no"))
        let failing = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: broken), defaults: defaults)
        _ = await failing.loadSessions(projectID: bench)
        let unread = await failing.reviewedFolder(sessionID: hubSession, projectID: bench)
        XCTAssertEqual(unread, .other(nil), "a failed read keys nothing, never home")
    }
}
