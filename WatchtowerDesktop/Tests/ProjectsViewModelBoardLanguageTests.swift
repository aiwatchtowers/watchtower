import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Board item #122: the project page sets the board language through
/// `watchtower project update`, then shows the stored value.
@MainActor
final class ProjectsViewModelBoardLanguageTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectsViewModelBoardLanguageTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// Stands in for `watchtower project update N --board-language=X`: writes
    /// the column the way the CLI would, or fails like its validation does.
    private final class UpdatingCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
        let pool: DatabasePool
        var fail = false
        private(set) var calls: [[String]] = []
        init(pool: DatabasePool) { self.pool = pool }

        func run(args: [String]) async throws -> Data {
            calls.append(args)
            if fail { throw CLIRunnerError.nonZeroExit(code: 1, stderr: "board language must be a language name") }
            let prefix = "--board-language="
            guard args.count == 4, args[1] == "update", let id = Int64(args[2]), args[3].hasPrefix(prefix) else {
                return Data()
            }
            let value = String(args[3].dropFirst(prefix.count))
            try await pool.write {
                try $0.execute(sql: "UPDATE projects SET board_language = ? WHERE id = ?", arguments: [value, id])
            }
            return Data()
        }
    }

    func testSetBoardLanguageRunsTheCLIAndShowsTheStoredValue() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = UpdatingCLIRunner(pool: pool)
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
        await vm.reload()
        XCTAssertEqual(vm.summaries.first?.project.boardLanguage, "", "a new project follows the session")

        await vm.setBoardLanguage(projectID: id, language: "Russian")

        XCTAssertEqual(runner.calls, [["project", "update", String(id), "--board-language=Russian"]])
        XCTAssertEqual(vm.summaries.first?.project.boardLanguage, "Russian")
        XCTAssertNil(vm.boardLanguageErrors[id])
        XCTAssertFalse(vm.settingBoardLanguage.contains(id))
    }

    func testAFailedChangeKeepsTheOldValueAndSaysWhy() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = UpdatingCLIRunner(pool: pool)
        runner.fail = true
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
        await vm.reload()

        await vm.setBoardLanguage(projectID: id, language: "Russian.")

        XCTAssertEqual(vm.summaries.first?.project.boardLanguage, "")
        let error = try XCTUnwrap(vm.boardLanguageErrors[id])
        XCTAssertTrue(error.contains("board language must be a language name"), error)
        XCTAssertFalse(vm.settingBoardLanguage.contains(id))
    }
}
