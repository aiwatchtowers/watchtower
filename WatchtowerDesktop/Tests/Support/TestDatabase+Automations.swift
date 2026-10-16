import Foundation
import GRDB

/// Fixtures for the automation tables (migrations 00113, 00117).
extension TestDatabase {
    /// A personal recipe; defaults to a confirmed, enabled manual recipe.
    @discardableResult
    package static func insertAutomation(
        _ db: Database,
        slug: String = "digest",
        name: String = "Digest",
        triggerKind: String = "manual",
        triggerSpec: String = #"{"manual":true}"#,
        approvalHash: String = "h1",
        confirmedHash: String = "h1",
        parseError: String = "",
        enabled: Bool = true,
        permissionsJSON: String = "[]",
        outputsJSON: String = "[]",
        nextRunAt: String? = nil,
        removedAt: String? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO automations (slug, scope, path, name, trigger_kind, trigger_spec, approval_hash,
                confirmed_hash, parse_error, enabled, permissions_json, outputs_json, next_run_at, removed_at)
            VALUES (?, 'personal', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [slug, "/tmp/acme/automations/\(slug).md", name, triggerKind, triggerSpec, approvalHash,
                             confirmedHash, parseError, enabled, permissionsJSON, outputsJSON, nextRunAt, removedAt])
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertAutomationRun(
        _ db: Database,
        automationID: Int64,
        trigger: String = "manual",
        status: String = "succeeded",
        waitingReason: String = "",
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        error: String = "",
        summary: String = "",
        queuedAt: String = "2026-10-01T09:00:00Z",
        startedAt: String? = "2026-10-01T09:00:01Z",
        finishedAt: String? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO automation_runs (automation_id, trigger, status, waiting_reason, input_tokens, output_tokens,
                error, summary, queued_at, started_at, finished_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [automationID, trigger, status, waitingReason, inputTokens, outputTokens, error, summary,
                             queuedAt, startedAt, finishedAt])
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertAutomationStep(
        _ db: Database,
        runID: Int64,
        seq: Int,
        kind: String = "llm",
        name: String = "",
        argsJSON: String = "",
        status: String = "ok",
        permission: String = ""
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO automation_run_steps (run_id, seq, kind, name, args_json, status, permission)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [runID, seq, kind, name, argsJSON, status, permission])
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertAutomationOutput(
        _ db: Database,
        automationID: Int64,
        runID: Int64,
        kind: String = "inbox",
        title: String = "New mail",
        body: String = "Two threads need you.",
        priority: String = "medium",
        createdAt: String = "2026-10-01T09:00:05Z",
        readAt: String? = nil,
        dismissedAt: String? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, priority, created_at,
                read_at, dismissed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [automationID, runID, kind, title, body, priority, createdAt, readAt, dismissedAt])
        return db.lastInsertedRowID
    }

    package static func insertAutomationGrant(
        _ db: Database,
        automationID: Int64,
        tool: String,
        grantHash: String,
        grantedAt: String = "2026-10-01T08:00:00Z"
    ) throws {
        try db.execute(sql: """
            INSERT INTO automation_tool_grants (automation_id, tool, grant_hash, granted_at) VALUES (?, ?, ?, ?)
            """, arguments: [automationID, tool, grantHash, grantedAt])
    }
}
