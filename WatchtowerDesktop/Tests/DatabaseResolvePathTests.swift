import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

/// `DatabaseManager.resolveDBPath` must open the same database the CLI would
/// write to: an explicit `active_workspace` or the single workspace holding a
/// `watchtower.db` — never a first-match guess between several (the Go
/// `config.resolveActiveWorkspace` rule, mirrored by
/// `Constants.workspacesWithDatabase`).
final class DatabaseResolvePathTests: XCTestCase {
    private var root: URL!
    private var configPath: String { root.appendingPathComponent("config.yaml").path }
    private var dataPath: String { root.appendingPathComponent("data").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchtower-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ name: String) throws {
        let dir = "\(dataPath)/\(name)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: "\(dir)/watchtower.db"))
    }

    private func writeConfig(_ yaml: String) throws {
        try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private func resolve() throws -> String {
        try DatabaseManager.resolveDBPath(configPath: configPath, basePath: dataPath)
    }

    func testConfiguredWorkspaceWins() throws {
        try seed("alpha")
        try seed("zenith")
        try writeConfig("active_workspace: zenith\n")
        XCTAssertEqual(try resolve(), "\(dataPath)/zenith/watchtower.db")
    }

    func testSingleCandidateResolvesWithoutConfig() throws {
        try seed("zenith")
        XCTAssertEqual(try resolve(), "\(dataPath)/zenith/watchtower.db")
    }

    func testNoCandidateIsNotFound() throws {
        XCTAssertThrowsError(try resolve()) { error in
            guard case WatchtowerDatabaseError.databaseNotFound = error else {
                return XCTFail("expected databaseNotFound, got \(error)")
            }
        }
    }

    /// Several databases and no `active_workspace`: the CLI refuses to start,
    /// so the Desktop must refuse too and name the candidates.
    func testSeveralCandidatesAreAmbiguous() throws {
        try seed("zenith")
        try seed("alpha")
        try writeConfig("sync:\n  workers: 2\n")
        XCTAssertThrowsError(try resolve()) { error in
            guard case WatchtowerDatabaseError.ambiguousWorkspace(let names) = error else {
                return XCTFail("expected ambiguousWorkspace, got \(error)")
            }
            XCTAssertEqual(names, ["alpha", "zenith"])
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("alpha, zenith"), message)
            XCTAssertTrue(message.contains("watchtower config set active_workspace <name>"), message)
        }
    }

    /// A configured workspace whose database does not exist yet is where the
    /// CLI will create it — opening some other workspace's database instead
    /// would show data the daemon never writes.
    func testConfiguredButMissingDoesNotFallBackToAnotherWorkspace() throws {
        try seed("alpha")
        try writeConfig("active_workspace: zenith\n")
        XCTAssertThrowsError(try resolve()) { error in
            guard case WatchtowerDatabaseError.databaseNotFound = error else {
                return XCTFail("expected databaseNotFound, got \(error)")
            }
        }
    }

    /// `_foo` passes the old path guard but not Go's `ValidWorkspaceRe`: the
    /// CLI refuses it, so the Desktop must not open its database either.
    func testInvalidConfiguredNameThrows() throws {
        try seed("_foo")
        for name in ["../etc", "_foo"] {
            try writeConfig("active_workspace: \(name)\n")
            XCTAssertThrowsError(try resolve(), name) { error in
                guard case WatchtowerDatabaseError.invalidWorkspaceName = error else {
                    return XCTFail("expected invalidWorkspaceName for \(name), got \(error)")
                }
            }
        }
    }
}
