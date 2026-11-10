import Foundation
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The Inbox's folders over a test database (Task 12): the built-ins Needs
/// approval and Waiting for me as the indexer writes their rows, their
/// living cards, and an Inbox view model reading at a fixed moment.
enum NeedsApprovalFixtures {
    /// The fixed moment every read is made at.
    static let now = AutomationDates.parse("2026-11-06T10:00:00Z") ?? Date()

    /// A built-in's automation row (`builtin_id`, `origin`), optionally
    /// stopped by the daemon (`disabled_reason`).
    @discardableResult
    static func builtin(_ db: Database, id: String, name: String, disabledReason: String = "") throws -> Int64 {
        let automation = try TestDatabase.insertAutomation(db, slug: id, name: name)
        try db.execute(sql: """
            UPDATE automations SET origin = 'builtin', builtin_id = ?, path = ?, disabled_reason = ?,
                enabled = ? WHERE id = ?
            """, arguments: [id, "builtin:\(id)", disabledReason, disabledReason.isEmpty, automation])
        return automation
    }

    /// A finished run of `automation`.
    @discardableResult
    static func run(_ db: Database, _ automation: Int64, status: String = "succeeded") throws -> Int64 {
        try TestDatabase.insertAutomationRun(db, automationID: automation, status: status)
    }

    /// A living card `key` of `automation`, written at `written`.
    @discardableResult
    static func card(
        _ db: Database,
        _ automation: Int64,
        run: Int64,
        key: String,
        written: String,
        title: String = "Approval",
        blocks: String = ""
    ) throws -> Int64 {
        try TestDatabase.insertAutomationOutput(
            db, automationID: automation, runID: run, title: title, createdAt: written, blocksJSON: blocks,
            outputKey: key, contentHash: "h-\(key)", writtenAt: written, changedAt: written)
    }

    /// The Inbox's view model at `now`, its filter in its own defaults suite.
    @MainActor
    static func viewModel(_ pool: DatabasePool, suite: String) -> ActionStripViewModel {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let now = now
        // Labeled: a trailing closure would bind to `automationsWake`.
        // swiftlint:disable:next trailing_closure
        return ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { now })
    }
}
