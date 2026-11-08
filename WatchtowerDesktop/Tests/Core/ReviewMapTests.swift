import XCTest
@testable import WatchtowerCore

/// The map wire shape, pinned by the Go golden `cmd/testdata/review-map.json`
/// (copied byte for byte into `Fixtures/review-map.json`).
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
        XCTAssertFalse(map.lanesPartial)
        XCTAssertFalse(map.diffTruncated)
        XCTAssertEqual(map.notes, [])
    }

    func testNullListsReadAsEmpty() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let map = try decoder.decode(ReviewMap.self, from: Data("""
            {"chapters":[{"key":"dir:a","title":"a","level":"normal","core":false,"paths":null,"changed_lines":0,
            "signals_summary":null}],"files":null,"lanes_partial":true,"diff_truncated":true,"notes":null}
            """.utf8))
        XCTAssertEqual(map.chapters[0].paths, [])
        XCTAssertEqual(map.chapters[0].signalsSummary, [:])
        XCTAssertEqual(map.files, [])
        XCTAssertTrue(map.lanesPartial)
        XCTAssertTrue(map.diffTruncated)
    }
}

/// `ReviewOverview`'s additive keys (tech spec §3.4) and the overview envelope's
/// `incomplete`, `error_class` and `detail`.
final class ReviewModelsOverviewKeysTests: XCTestCase {
    private func decode(_ json: String) throws -> ReviewEnvelope {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ReviewEnvelope.self, from: Data(json.utf8))
    }

    func testNewKeysDecode() throws {
        let env = try decode("""
            {"ok":true,"overview":{"summary":"s","coverage":[{"index":1,"item":"i","status":"done","where":[],"source":"lane"}],
            "out_of_scope":[],"risk":[],"chapters":[{"key":"dir:api","title":"api","level":"breaking","paths":["api/a.go"],
            "core":true,"what":"about"}],"incomplete":["lane:x"]},"incomplete":["lane:x"]}
            """)
        let overview = try XCTUnwrap(env.overview)
        XCTAssertEqual(overview.incomplete, ["lane:x"])
        XCTAssertEqual(overview.coverage[0].source, .lane)
        XCTAssertEqual(overview.chapters[0].key, "dir:api")
        XCTAssertEqual(overview.chapters[0].level, .breaking)
        XCTAssertEqual(overview.chapters[0].what, "about")
        XCTAssertEqual(overview.chapters[0].lenses, [])
        XCTAssertEqual(env.incomplete, ["lane:x"])
    }

    func testOldOverviewWithoutNewKeys() throws {
        let env = try decode("""
            {"ok":true,"overview":{"summary":"s","coverage":[{"index":1,"item":"i","status":"partial","where":["a"]}],
            "out_of_scope":null,"risk":null,"chapters":[{"title":"t","paths":["a"],"core":false,"lenses":["tests"]}]}}
            """)
        let overview = try XCTUnwrap(env.overview)
        XCTAssertEqual(overview.incomplete, [])
        XCTAssertNil(overview.coverage[0].source)
        XCTAssertNil(overview.chapters[0].key)
        XCTAssertNil(overview.chapters[0].level)
        XCTAssertNil(overview.chapters[0].what)
        XCTAssertNil(env.incomplete)
    }

    func testUnknownCoverageSourceReadsAsNil() throws {
        let env = try decode("""
            {"ok":true,"overview":{"summary":"s","coverage":[{"index":1,"item":"i","status":"done","where":[],"source":"later"}]}}
            """)
        XCTAssertNil(env.overview?.coverage[0].source)
    }

    func testErrorEnvelope() throws {
        let env = try decode("""
            {"ok":false,"error":"Another overview of this branch is still running.","error_class":"busy","detail":"raw"}
            """)
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.errorClass, "busy")
        XCTAssertEqual(env.detail, "raw")
        XCTAssertEqual(env.error, "Another overview of this branch is still running.")
    }
}
