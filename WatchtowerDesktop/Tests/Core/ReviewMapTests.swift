import XCTest
@testable import WatchtowerCore

/// The map wire shape, pinned by the Go golden `cmd/testdata/review-map.golden.json`
/// (copied byte for byte into `Fixtures/review-map.json`; a Go test keeps them equal).
final class ReviewMapTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    static func goldenMap() throws -> ReviewMap {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let env = try decoder.decode(ReviewEnvelope.self, from: fixture("review-map.json"))
        XCTAssertTrue(env.ok)
        return try XCTUnwrap(env.map)
    }

    func testGoldenDecodes() throws {
        let map = try Self.goldenMap()
        XCTAssertEqual(map.chapters.map(\.key), [
            "dir:api", "lane:ABC-1-login", "dir:", "dir:internal/db/migrations", "agent:1", "lane:task-b", "collapsed"
        ])
        let api = map.chapters[0]
        XCTAssertEqual(api.level, .breaking)
        XCTAssertTrue(api.core)
        XCTAssertEqual(api.changedLines, 2)
        // A dictionary's keys are not touched by `.convertFromSnakeCase`.
        XCTAssertEqual(api.signalsSummary, ["api_removed": 1])
        XCTAssertNil(api.lane)

        let login = map.chapters[1]
        XCTAssertEqual(login.lane, "ABC-1-login")
        XCTAssertEqual(login.jiraKey, "ABC-1")
        XCTAssertNil(login.targetId)
        XCTAssertEqual(map.chapters[5].targetId, 1)
        XCTAssertTrue(map.chapters[6].isCollapsed)

        XCTAssertEqual(map.files.count, 8)
        let shared = try XCTUnwrap(map.files.first { $0.path == "shared.go" })
        XCTAssertEqual(shared.chapter, "lane:task-b")
        XCTAssertEqual(shared.lane, "task-b")
        XCTAssertEqual(shared.also, ["ABC-1-login"])
        XCTAssertEqual(map.files.first { $0.path == "README.md" }?.signals, ["file_deleted"])
        XCTAssertEqual(map.files.first { $0.path == "README.md" }?.also, [])
        XCTAssertEqual(map.lanes, [
            ReviewMap.Lane(name: "ABC-1-login", title: "Login with a passkey", targetId: nil, jiraKey: "ABC-1"),
            ReviewMap.Lane(name: "task-b", title: "Payments lane", targetId: 1, jiraKey: nil)
        ])
        XCTAssertFalse(map.lanesPartial)
        XCTAssertFalse(map.diffTruncated)
        XCTAssertEqual(map.notes, [])
    }

    func testNullListsReadAsEmpty() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let map = try decoder.decode(ReviewMap.self, from: Data("""
            {"chapters":[{"key":"dir:a","title":"a","level":"normal","core":false,"paths":null,"changed_lines":0,
            "signals_summary":null}],"files":null,"lanes":null,"lanes_partial":true,"diff_truncated":true,"notes":null}
            """.utf8))
        XCTAssertEqual(map.chapters[0].paths, [])
        XCTAssertEqual(map.lanes, [])
        XCTAssertEqual(map.chapters[0].signalsSummary, [:])
        XCTAssertEqual(map.files, [])
        XCTAssertTrue(map.lanesPartial)
        XCTAssertTrue(map.diffTruncated)
    }

    func testAbsentLanesReadAsEmpty() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let map = try decoder.decode(ReviewMap.self, from: Data(#"{"chapters":[],"files":[]}"#.utf8))
        XCTAssertEqual(map.lanes, [])
    }
}
