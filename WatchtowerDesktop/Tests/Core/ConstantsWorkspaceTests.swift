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
        try seed("whitebit", withDB: true)
        try seed("scratch", withDB: false)
        XCTAssertEqual(Constants.singleWorkspaceWithDatabase(under: root.path), "whitebit")
    }

    func testSeveralDatabasesStayUnresolved() throws {
        try seed("alpha", withDB: true)
        try seed("whitebit", withDB: true)
        XCTAssertNil(Constants.singleWorkspaceWithDatabase(under: root.path))
    }

    func testNoDatabaseAndMissingRootStayUnresolved() throws {
        XCTAssertNil(Constants.singleWorkspaceWithDatabase(under: root.appendingPathComponent("missing").path))
        try seed("empty", withDB: false)
        XCTAssertNil(Constants.singleWorkspaceWithDatabase(under: root.path))
    }

    /// Names the Go validator rejects are not candidates, even with a DB —
    /// otherwise the two halves would resolve different workspaces.
    func testSkipsNamesTheGoValidatorRejects() throws {
        try seed("whitebit", withDB: true)
        try seed("_scratch", withDB: true)
        try seed(".hidden", withDB: true)
        try Data().write(to: root.appendingPathComponent("watchtower.db"))
        XCTAssertEqual(Constants.singleWorkspaceWithDatabase(under: root.path), "whitebit")
    }
}
