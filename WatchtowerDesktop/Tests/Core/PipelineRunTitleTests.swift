import XCTest
@testable import WatchtowerCore

final class PipelineRunTitleTests: XCTestCase {

    private func run(_ pipeline: String) throws -> PipelineRun {
        let json = """
        {"id": 1, "pipeline": "\(pipeline)", "source": "", "model": "", "status": "done",
         "error_msg": "", "items_found": 0, "input_tokens": 0, "output_tokens": 0,
         "cost_usd": 0, "total_api_tokens": 0, "started_at": "2026-09-27T10:00:00Z",
         "duration_seconds": 0, "step_count": 0}
        """
        return try JSONDecoder().decode(PipelineRun.self, from: Data(json.utf8))
    }

    /// The daemon's `external-sync` run (phaseExternalSync) reads as the
    /// Confluence sync it is, not the capitalized id "External-Sync".
    func testExternalSyncHasItsOwnTitleAndIcon() throws {
        let external = try run("external-sync")
        XCTAssertEqual(external.pipelineTitle, "Confluence sync")
        XCTAssertEqual(external.pipelineIcon, "books.vertical")
    }

    func testUnknownPipelineFallsBack() throws {
        let other = try run("some-new-thing")
        XCTAssertEqual(other.pipelineTitle, "Some-New-Thing")
        XCTAssertEqual(other.pipelineIcon, "gearshape")
    }
}
