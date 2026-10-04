import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class PipelineRunQueriesTests: XCTestCase {

    private func insertRun(
        _ db: Database, pipeline: String, status: String, errorMsg: String = "", tokens: Int, startedAt: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO pipeline_runs (pipeline, source, model, status, error_msg,
                    input_tokens, output_tokens, total_api_tokens, started_at)
                VALUES (?, 'daemon', 'auto', ?, ?, ?, ?, ?, ?)
                """,
            arguments: [pipeline, status, errorMsg, tokens, tokens, tokens, startedAt]
        )
    }

    /// A token-less memory failure (the vault would not open) is listed in
    /// Usage and counts no AI call; token-less runs of other pipelines stay
    /// filtered out, failed or not — offline they would fail every cycle.
    func testFetchByDateKeepsOnlyMemoryTokenlessFailures() throws {
        let db = try TestDatabase.create()
        let now = ISO8601DateFormatter().string(from: Date())
        try db.write { db in
            try insertRun(db, pipeline: "digests", status: "done", tokens: 100, startedAt: now)
            try insertRun(db, pipeline: "slack-sync", status: "done", tokens: 0, startedAt: now)
            try insertRun(
                db, pipeline: "slack-sync", status: "error",
                errorMsg: "slack: invalid_auth", tokens: 0, startedAt: now
            )
            try insertRun(
                db, pipeline: "memory", status: "error",
                errorMsg: "opening memory vault: permission denied", tokens: 0, startedAt: now
            )
        }

        let runs = try db.read { try PipelineRunQueries.fetchByDate($0, on: Date()) }

        XCTAssertEqual(Set(runs.map(\.pipeline)), ["digests", "memory"])
        let memory = try XCTUnwrap(runs.first { $0.pipeline == "memory" })
        XCTAssertEqual(memory.status, "error")
        XCTAssertEqual(memory.errorMsg, "opening memory vault: permission denied")
        XCTAssertEqual(memory.aiCallCount, 0, "a run that used no tokens made no AI call")
        XCTAssertEqual(runs.reduce(0) { $0 + $1.aiCallCount }, 1)
    }

    func testFetchByDateEmptyDay() throws {
        let db = try TestDatabase.create()
        let runs = try db.read { try PipelineRunQueries.fetchByDate($0, on: Date()) }
        XCTAssertTrue(runs.isEmpty)
    }
}
