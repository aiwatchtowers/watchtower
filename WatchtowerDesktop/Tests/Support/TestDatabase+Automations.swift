import Foundation
import GRDB

/// Fixtures for the automation tables (migrations 00113, 00117, 00149).
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
        removedAt: String? = nil,
        workbenchID: Int64? = nil
    ) throws -> Int64 {
        // A workbench recipe lives in its folder's .watchtower/automations.
        let path = workbenchID.map { "/tmp/acme/.watchtower/automations/\($0)-\(slug).md" }
            ?? "/tmp/acme/automations/\(slug).md"
        try db.execute(sql: """
            INSERT INTO automations (slug, scope, project_id, path, name, trigger_kind, trigger_spec, approval_hash,
                confirmed_hash, parse_error, enabled, permissions_json, outputs_json, next_run_at, removed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [slug, workbenchID == nil ? "personal" : "workbench", workbenchID, path, name, triggerKind,
                             triggerSpec, approvalHash, confirmedHash, parseError, enabled, permissionsJSON, outputsJSON,
                             nextRunAt, removedAt])
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
        permission: String = "",
        sessionID: Int64? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO automation_run_steps (run_id, seq, kind, name, args_json, status, permission, session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [runID, seq, kind, name, argsJSON, status, permission, sessionID])
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
        dismissedAt: String? = nil,
        doneAt: String? = nil,
        link: String = "",
        actionsJSON: String = "[]",
        pressedAction: Int? = nil,
        pressedRunID: Int64? = nil,
        pressedAt: String? = nil,
        blocksJSON: String = "",
        outputKey: String? = nil,
        contentHash: String = "",
        writtenAt: String? = nil,
        changedAt: String? = nil
    ) throws -> Int64 {
        // Go writes `written_at` and `changed_at` on every row since the
        // blocks migration: `created_at` unless given.
        try db.execute(sql: """
            INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, priority, created_at,
                read_at, dismissed_at, done_at, link, actions_json, pressed_action, pressed_run_id, pressed_at,
                blocks_json, output_key, content_hash, written_at, changed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [automationID, runID, kind, title, body, priority, createdAt, readAt, dismissedAt,
                             doneAt, link, actionsJSON, pressedAction, pressedRunID, pressedAt,
                             blocksJSON, outputKey, contentHash, writtenAt ?? createdAt, changedAt ?? createdAt])
        return db.lastInsertedRowID
    }

    /// A living rewrite of output `id` as Go's `commitRunTx` upserts it by
    /// key: always a new `run_id`, body, blocks, hash and `written_at`; only
    /// a changed hash also moves `changed_at` and clears the read, done,
    /// dismissed and press state (spec "Living upsert and read state").
    package static func rewriteLivingOutput(
        _ db: Database, id: Int64, runID: Int64, body: String, blocksJSON: String, contentHash: String, at stamp: String
    ) throws {
        let changed = try String.fetchOne(db, sql: "SELECT content_hash FROM automation_outputs WHERE id = ?",
                                          arguments: [id]) != contentHash
        try db.execute(sql: """
            UPDATE automation_outputs SET run_id = ?, body = ?, blocks_json = ?, content_hash = ?, written_at = ?
            WHERE id = ?
            """, arguments: [runID, body, blocksJSON, contentHash, stamp, id])
        guard changed else { return }
        try db.execute(sql: """
            UPDATE automation_outputs SET changed_at = ?, read_at = NULL, done_at = NULL, dismissed_at = NULL,
                pressed_action = NULL, pressed_run_id = NULL, pressed_at = NULL
            WHERE id = ?
            """, arguments: [stamp, id])
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
