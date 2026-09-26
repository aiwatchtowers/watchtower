import XCTest
@testable import WatchtowerCore

/// `Constants.singleWorkspaceWithDatabase` mirrors Go's
/// `config.resolveActiveWorkspace`: exactly one workspace directory with a
/// `watchtower.db` resolves, anything else stays nil so the Desktop never
/// guesses where the CLI refused to.
final class ConstantsWorkspaceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchtower-constants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ name: String, withDB: Bool) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withDB {
            try Data().write(to: dir.appendingPathComponent("watchtower.db"))
        }
    }

    func testResolvesTheOnlyDatabase() throws {
        try seed("zenith", withDB: true)
        try seed("scratch", withDB: false)
        XCTAssertEqual(Constants.singleWorkspaceWithDatabase(under: root.path), "zenith")
    }

    func testSeveralDatabasesStayUnresolved() throws {
        try seed("alpha", withDB: true)
        try seed("zenith", withDB: true)
        XCTAssertNil(Constants.singleWorkspaceWithDatabase(under: root.path))
    }

    /// The full candidate list (sorted) feeds the Desktop's "pick one" error,
    /// so the names it shows match the ones Go's ValidateWorkspace names.
    func testListsEveryCandidateSorted() throws {
        try seed("zenith", withDB: true)
        try seed("alpha", withDB: true)
        try seed("scratch", withDB: false)
        try seed("_ignored", withDB: true)
        XCTAssertEqual(Constants.workspacesWithDatabase(under: root.path), ["alpha", "zenith"])
        XCTAssertEqual(Constants.workspacesWithDatabase(under: root.appendingPathComponent("missing").path), [])
    }

    func testWorkspaceNameMatchesTheGoPattern() {
        for good in ["zenith", "a", "Work.space-2_x"] {
            XCTAssertTrue(Constants.isWorkspaceName(good), good)
        }
        for bad in ["", "_scratch", "-x", ".hidden", "../etc", "a b", "é", "zenith\n"] {
            XCTAssertFalse(Constants.isWorkspaceName(bad), bad)
        }
    }

    func testNoDatabaseAndMissingRootStayUnresolved() throws {
        XCTAssertNil(Constants.singleWorkspaceWithDatabase(under: root.appendingPathComponent("missing").path))
        try seed("empty", withDB: false)
        XCTAssertNil(Constants.singleWorkspaceWithDatabase(under: root.path))
    }

    /// Names the Go validator rejects are not candidates, even with a DB —
    /// otherwise the two halves would resolve different workspaces.
    func testSkipsNamesTheGoValidatorRejects() throws {
        try seed("zenith", withDB: true)
        try seed("_scratch", withDB: true)
        try seed(".hidden", withDB: true)
        try Data().write(to: root.appendingPathComponent("watchtower.db"))
        XCTAssertEqual(Constants.singleWorkspaceWithDatabase(under: root.path), "zenith")
    }

    /// A symlinked workspace directory is a candidate on both sides (Go's
    /// `workspaceDirsWithDatabase` stats through the link too); a dangling
    /// symlink or one pointing at a plain file holds no database.
    func testFollowsSymlinkedWorkspaceDirs() throws {
        let fm = FileManager.default
        let elsewhere = root.appendingPathComponent("elsewhere-store")
        try fm.createDirectory(at: elsewhere.appendingPathComponent("real"), withIntermediateDirectories: true)
        try Data().write(to: elsewhere.appendingPathComponent("real/watchtower.db"))
        try Data().write(to: elsewhere.appendingPathComponent("plain"))

        let workspaces = root.appendingPathComponent("workspaces")
        try fm.createDirectory(at: workspaces, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: workspaces.appendingPathComponent("linked"),
                                  withDestinationURL: elsewhere.appendingPathComponent("real"))
        try fm.createSymbolicLink(at: workspaces.appendingPathComponent("dangling"),
                                  withDestinationURL: elsewhere.appendingPathComponent("gone"))
        try fm.createSymbolicLink(at: workspaces.appendingPathComponent("to-file"),
                                  withDestinationURL: elsewhere.appendingPathComponent("plain"))

        XCTAssertEqual(Constants.singleWorkspaceWithDatabase(under: workspaces.path), "linked")
    }
}
