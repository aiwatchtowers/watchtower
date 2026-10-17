import Foundation
import GRDB

/// What `FeatureReadiness` reads from the DB: whether each feature has
/// content, and each pipeline's newest run.
package enum ReadinessQueries {
    /// The table whose rows are a feature's content. Whole-table: one owner
    /// per workspace, and briefing/day plan count any row, not today's (a
    /// day plan's "fresh install" is no row at all, dual path with Go's
    /// `dayPlanFresh`).
    static func contentTable(_ feature: ReadinessFeature) -> String {
        switch feature {
        case .slackSync: "messages"
        case .digests: "digests"
        case .streamDigests: "stream_digests"
        case .tracks: "tracks"
        case .peopleCards: "people_cards"
        case .briefing: "briefings"
        case .dayPlan: "day_plans"
        case .ideas: "ideas"
        case .memory: "memory_nodes"
        case .inbox: "inbox_items"
        case .knowledgeIndex: "kb_documents"
        case .calendar: "calendar_events"
        case .jira: "jira_issues"
        }
    }

    /// Tables `contentPresent` and `latestRuns` read, for the
    /// ReadinessCenter's ValueObservation region.
    package static let observedTables: [String] = ReadinessFeature.allCases.map(contentTable) + ["pipeline_runs"]

    /// One SELECT of EXISTS subselects; a table missing from this DB (an
    /// install mid-migration) reads as absent.
    package static func contentPresent(_ db: Database) throws -> Set<ReadinessFeature> {
        let existing = try existingTables(db, among: ReadinessFeature.allCases.map(contentTable))
        let features = ReadinessFeature.allCases.filter { existing.contains(contentTable($0)) }
        guard !features.isEmpty else { return [] }
        let columns = features
            .map { "EXISTS(SELECT 1 FROM \(contentTable($0))) AS \($0.rawValue)" }
            .joined(separator: ", ")
        guard let row = try Row.fetchOne(db, sql: "SELECT \(columns)") else { return [] }
        return Set(features.filter { row[$0.rawValue] as Bool })
    }

    /// Newest row (highest id, any status) per pipeline name, for the names
    /// in `ReadinessFeature.pipelineName`. A `started_at` that doesn't parse
    /// reads as `.distantPast`: the row's status still counts, but it is
    /// never "preparing".
    package static func latestRuns(_ db: Database) throws -> [String: RunSnapshot] {
        guard try existingTables(db, among: ["pipeline_runs"]).contains("pipeline_runs") else { return [:] }
        let names = ReadinessFeature.allCases.compactMap(\.pipelineName)
        let placeholders = names.map { _ in "?" }.joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT pipeline, status, started_at, error_msg FROM pipeline_runs
                WHERE id IN (
                    SELECT MAX(id) FROM pipeline_runs WHERE pipeline IN (\(placeholders)) GROUP BY pipeline
                )
                """,
            arguments: StatementArguments(names)
        )
        var runs: [String: RunSnapshot] = [:]
        for row in rows {
            let startedAt: String = row["started_at"]
            runs[row["pipeline"]] = RunSnapshot(
                status: row["status"],
                startedAt: SyncProgress.parseTimestamp(startedAt) ?? .distantPast,
                errorMessage: row["error_msg"]
            )
        }
        return runs
    }

    /// `started_at` of every running `history_backfill` row (a held row
    /// included), for memory's backfill wait; a database without the table
    /// reads as none. A `started_at` that doesn't parse is skipped (it can't
    /// be placed in the wait window).
    package static func runningBackfillStarts(_ db: Database) throws -> [Date] {
        guard try existingTables(db, among: ["history_backfill"]).contains("history_backfill") else { return [] }
        return try String.fetchAll(db, sql: "SELECT started_at FROM history_backfill WHERE status = 'running'")
            .compactMap { SyncProgress.parseTimestamp($0) }
    }

    private static func existingTables(_ db: Database, among names: [String]) throws -> Set<String> {
        let placeholders = names.map { _ in "?" }.joined(separator: ", ")
        return Set(try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (\(placeholders))",
            arguments: StatementArguments(names)
        ))
    }
}
