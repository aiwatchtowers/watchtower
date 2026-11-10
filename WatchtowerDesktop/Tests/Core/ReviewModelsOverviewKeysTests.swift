import XCTest
@testable import WatchtowerCore

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
