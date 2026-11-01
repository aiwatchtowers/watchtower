import XCTest
@testable import WatchtowerCore

/// The restart list of the one-time v1-host restart (go hub spec §8 p. 4b).
final class HostRestartListTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HostRestartListTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private var url: URL { dir.appendingPathComponent(HostRestartList.fileName) }

    func testFileRoundTripsWithItsKeysAndMode() throws {
        let list = HostRestartList(rows: [
            .init(scope: "aaaa", rowID: 7, agent: "claude", resumeID: "id-7"),
            .init(scope: "bbbb", rowID: 3, agent: "", resumeID: "")
        ])
        try list.save(to: url)

        XCTAssertEqual(try HostRestartList.load(from: url), list)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"row_id\":7"), text)
        XCTAssertTrue(text.contains("\"resume_id\":\"id-7\""), text)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testNoFileIsNoList() throws {
        XCTAssertNil(try HostRestartList.load(from: url))
    }

    func testAnUnreadableFileThrows() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try HostRestartList.load(from: url))
    }

    func testAnEmptyListRemovesTheFile() throws {
        try HostRestartList(rows: [.init(scope: "a", rowID: 1, agent: "claude", resumeID: "x")]).save(to: url)
        try HostRestartList().save(to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try HostRestartList().save(to: url) // nothing to remove: no error
    }

    func testMergeKeepsWhatIsListedAndAddsNewRows() {
        var list = HostRestartList(rows: [.init(scope: "a", rowID: 1, agent: "claude", resumeID: "old")])
        list.merge([
            .init(scope: "a", rowID: 1, agent: "claude", resumeID: "new"),
            .init(scope: "b", rowID: 1, agent: "", resumeID: ""),
            .init(scope: "a", rowID: 2, agent: "codex", resumeID: "c")
        ])
        XCTAssertEqual(list.rows.map(\.resumeID), ["old", "", "c"])
    }

    func testRowsOfAScopeCountTheOlderHostsEmptyScope() {
        let list = HostRestartList(rows: [
            .init(scope: "a", rowID: 1, agent: "claude", resumeID: ""),
            .init(scope: "", rowID: 2, agent: "claude", resumeID: ""),
            .init(scope: "b", rowID: 3, agent: "claude", resumeID: "")
        ])
        XCTAssertEqual(list.rows(in: "a").map(\.rowID), [1, 2])
        XCTAssertEqual(list.waiting(besides: "a"), ["b": 1])
    }

    func testWaitingCountsEveryOtherScope() {
        var list = HostRestartList(rows: [
            .init(scope: "a", rowID: 1, agent: "claude", resumeID: ""),
            .init(scope: "b", rowID: 1, agent: "", resumeID: ""),
            .init(scope: "b", rowID: 2, agent: "", resumeID: ""),
            .init(scope: "c", rowID: 9, agent: "", resumeID: "")
        ])
        XCTAssertEqual(list.waiting(besides: "a"), ["b": 2, "c": 1])
        list.remove(scope: "b", rowID: 2)
        XCTAssertEqual(list.waiting(besides: "a"), ["b": 1, "c": 1])
    }
}
