import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore
import WatchtowerChatText

/// The Mac's chat write path over Go's `internal/chatstore/testdata/chat_turn_cases.json`,
/// which `TestChatstore_MatchesSwiftFixture` runs through the hub's Go turn
/// store: the same starting tree, request and protocol-v2 events must leave
/// the same rows. The start mirrors `ChatViewModel.send/regenerate/edit` +
/// `persistTurnStart` (private to the app target, so its steps are replayed
/// here through the same Core queries); the turn runs through the real
/// `ChatTurnDriver` + `ChatTurnStore`. The lease is Go's until Task 8 and is
/// not checked here.
@MainActor
final class ChatTurnStoreFixtureTests: XCTestCase {
    nonisolated private static let preferredProvider = "claude"

    private static func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chatstore/testdata/chat_turn_cases.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testTurnsMatchTheGoStore() async throws {
        let turns = try XCTUnwrap(try Self.fixture()["turns"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(turns.count, 10)
        for tc in turns {
            try await run(tc)
        }
    }

    func testSaveVersionMatchesTheGoStore() throws {
        let cases = try XCTUnwrap(try Self.fixture()["save_version"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for tc in cases {
            let name = tc["name"] as? String ?? "?"
            let queue = try TestDatabase.create()
            try queue.write { db in
                let conv = try TestDatabase.insertChatConversation(db)
                for _ in 0..<2 {
                    _ = try ChatTreeQueries.insertAssistant(db, conversationID: conv, parentID: nil, turnID: "", provider: "", model: "")
                }
                for a in tc["existing"] as? [[String: Any]] ?? [] {
                    try db.execute(sql: """
                        INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, edited, created_at)
                        VALUES (?, ?, ?, ?, 'document', ?, ?, ?, 1)
                        """, arguments: [conv, a["message"] as? Int64, a["key"] as? String, a["version"] as? Int,
                                         a["title"] as? String, a["content"] as? String, (a["edited"] as? Bool ?? false) ? 1 : 0])
                }
                let d = try XCTUnwrap(tc["draft"] as? [String: Any])
                let draft = ArtifactDraft(key: d["key"] as? String ?? "", kind: d["kind"] as? String ?? "",
                                          title: d["title"] as? String ?? "", meta: d["meta"] as? [String: String] ?? [:],
                                          content: d["content"] as? String ?? "", isComplete: true)
                try ChatArtifactQueries.saveVersion(db, conversationID: conv, messageID: try XCTUnwrap(tc["message"] as? Int64),
                                                    draft: draft, edited: false)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT artifact_key, version, message_id, title, content, meta_json, edited FROM chat_artifacts
                    WHERE conversation_id = ? ORDER BY artifact_key, version
                    """, arguments: [conv])
                let got: [String] = rows.map { r in
                    let edited: Bool = (r["edited"] as Int) == 1
                    return Self.norm(["key": r["artifact_key"] as String, "version": r["version"] as Int,
                                      "message": r["message_id"] as Int64, "title": r["title"] as String,
                                      "content": r["content"] as String, "meta": Self.parse(r["meta_json"] as String),
                                      "edited": edited])
                }
                let want: [String] = (tc["expect"] as? [[String: Any]] ?? []).map { e in
                    var row = Self.pick(e, ["key", "version", "message", "title", "content", "meta", "edited"])
                    if e["meta"] == nil { row["meta"] = [String: String]() }
                    return Self.norm(row)
                }
                XCTAssertEqual(got, want, name)
            }
        }
    }

    /// The Swift half of the start's timing gate (spec 2026-11-15 mobile
    /// inbox §8, Go's `BenchmarkPersistStart`): the median of the lease claim
    /// + `persistTurnStart` writes on the fixture's first case, in one write
    /// as the app does, the rows undone between runs. Prints only; runs when
    /// `WT_CHAT_START_TIMING=1` is set (`make test-swift FILTER=ChatTurnStoreFixtureTests`).
    func testPersistStartTiming() async throws {
        guard ProcessInfo.processInfo.environment["WT_CHAT_START_TIMING"] == "1" else {
            throw XCTSkip("set WT_CHAT_START_TIMING=1 to time the start")
        }
        let tc = try XCTUnwrap((try Self.fixture()["turns"] as? [[String: Any]])?.first)
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (conv, ids, files, comments) = try await pool.write { db in try Self.seed(db, tc) }
        let request = try XCTUnwrap(tc["request"] as? [String: Any])
        let config = try await pool.read { db in try Self.config(db, conv: conv, request: request) }
        let plan = try await pool.read { db in
            try Self.plan(db, conv: conv, request: request, ids: ids, files: files, comments: comments, floor: nil)
        }
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for run in 0..<201 {
            let turnID = "timing-\(run)"
            let nowMS = ChatLease.milliseconds(Date())
            let lease = ChatLease(conversationID: conv, owner: .desktop, ownerID: "launch", turnID: turnID,
                                  startedAtMS: nowMS, heartbeatAtMS: nowMS)
            let started = clock.now
            _ = try await pool.write { db in
                guard try ChatLeaseQueries.claim(db, lease, nowMS: nowMS) else { throw ChatBusyError() }
                return try Self.persistStart(db, conv: conv, plan: plan, config: config, turnID: turnID)
            }
            samples.append(clock.now - started)
            try await pool.write { db in
                try ChatLeaseQueries.release(db, conversationID: conv, turnID: turnID)
                try db.execute(sql: "DELETE FROM chat_messages WHERE conversation_id = ? AND turn_id = ?", arguments: [conv, turnID])
                try db.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = NULL, title = '' WHERE id = ?",
                               arguments: [conv])
            }
        }
        let median = samples.sorted()[samples.count / 2]
        print("ChatTurnStoreFixtureTests persist start median: \(median.components.attoseconds / 1_000_000_000_000) µs over \(samples.count) runs")
    }

    // MARK: - One turn case

    private struct Config {
        let provider: String
        let model: String?
        let automatic: Bool
    }

    private struct Plan {
        let historyTipID: Int64?
        let userText: String
        let reuseUserMessageID: Int64?
        let attachments: [ChatAttachment]
        let outcomes: String?
        let forceReplay: Bool
        let titleText: String?
        /// The quote batch: artifact comments `persistTurnStart`'s `alsoWrite`
        /// marks sent (`ChatViewModel.sendArtifactComments`).
        var quoteIDs: [Int64] = []
    }

    private func run(_ tc: [String: Any]) async throws {
        let name = tc["name"] as? String ?? "?"
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (conv, ids, files, comments) = try await pool.write { db in try Self.seed(db, tc) }
        let request = try XCTUnwrap(tc["request"] as? [String: Any], name)
        let config = try await pool.read { db in try Self.config(db, conv: conv, request: request) }
        // The outcomes floor's formatter is main-actor isolated: format it here.
        let lastOwner = try await pool.read { db in
            try ChatTreeQueries.thread(db, conversationID: conv).last { $0.message.isUser }?.message.createdDate
        }
        let floor = lastOwner.map { AgentActionFeed.timestampString($0) }
        let plan = try await pool.read { db in
            try Self.plan(db, conv: conv, request: request, ids: ids, files: files, comments: comments, floor: floor)
        }
        let turnID = request["turn_id"] as? String ?? "t1"

        // ChatViewModel.persistTurnStart, step by step.
        let persisted = try await pool.write { db in
            try Self.persistStart(db, conv: conv, plan: plan, config: config, turnID: turnID)
        }

        let expect = try XCTUnwrap(tc["expect"] as? [String: Any], name)
        let continuous = (request["continuous_leaf"] as? String).flatMap { ids[$0] }
        let replay = plan.forceReplay
            || ChatContinuity.replayNeeded(historyTipID: persisted.historyTip, continuousLeafID: continuous)
        XCTAssertEqual(replay, expect["replay"] as? Bool, "\(name): replay")
        XCTAssertEqual(ChatTurnText.compose(userText: plan.userText, outcomes: plan.outcomes),
                       expect["send_text"] as? String, "\(name): send text")
        let refByID = Dictionary(uniqueKeysWithValues: files.map { ($1, $0) })
        XCTAssertEqual(plan.attachments.map { refByID[$0.id] ?? "?" }, expect["attachments_sent"] as? [String] ?? [],
                       "\(name): attachments sent")

        let clock = ChatTestClock()
        let driver = ChatTurnDriver(conversationID: conv, store: ChatTurnStore(dbPool: pool)) { clock.now }
        driver.begin(messageID: persisted.assistant, turnID: turnID)
        for event in tc["events"] as? [[String: Any]] ?? [] {
            if let ms = event["advance_ms"] as? Double { clock.advance(ms / 1000) }
            if event["type"] as? String == "stop" {
                driver.finishRunningAsPartial()
                continue
            }
            let line = String(bytes: try JSONSerialization.data(withJSONObject: event), encoding: .utf8) ?? ""
            let parsed = try XCTUnwrap(ChatEvent.parse(line), "\(name): event \(line)")
            driver.apply(parsed)
        }
        await driver.writesSettled()
        try await pool.read { db in try Self.check(db, conv: conv, ids: ids, files: files, comments: comments, expect: expect, name: name) }
    }

    /// `ChatViewModel.persistTurnStart` after its lease claim, step by step.
    nonisolated private static func persistStart(
        _ db: Database, conv: Int64, plan: Plan, config: Config, turnID: String
    ) throws -> (assistant: Int64, historyTip: Int64?) {
        var historyTip = plan.historyTipID
        let userID: Int64
        if let reuse = plan.reuseUserMessageID {
            userID = reuse
        } else {
            if let tip = historyTip,
               let row = try ChatMessageRecord.fetchOne(db, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [tip]),
               row.isUser {
                historyTip = try ChatTreeQueries.insertAssistant(db, conversationID: row.conversationID, parentID: row.id,
                                                                 turnID: row.turnID, provider: config.provider, model: "").id
            }
            userID = try ChatTreeQueries.insertUser(db, conversationID: conv, parentID: historyTip,
                                                    text: plan.userText, turnID: turnID).id
            try ChatAttachmentQueries.link(db, attachmentIDs: plan.attachments.map(\.id), messageID: userID)
            try ChatConversationQueries.setPrefixTitle(db, id: conv, text: plan.titleText ?? plan.userText)
            if !plan.quoteIDs.isEmpty {
                _ = try ArtifactCommentQueries.markSent(db, ids: plan.quoteIDs, at: Date())
            }
        }
        if !config.automatic {
            try ChatConversationQueries.setRouting(db, id: conv, automatic: false, provider: config.provider, model: config.model)
        }
        let assistant = try ChatTreeQueries.insertAssistant(db, conversationID: conv, parentID: userID, turnID: turnID,
                                                            provider: config.automatic ? "" : config.provider,
                                                            model: config.automatic ? "" : config.model ?? "")
        return (assistant.id, historyTip)
    }

    // MARK: - Seeding

    /// The case's conversation and the ids of its message, attachment and
    /// artifact-comment refs (apart: ids of different tables may repeat).
    nonisolated private static func seed(
        _ db: Database, _ tc: [String: Any]
    ) throws -> (Int64, [String: Int64], [String: Int64], [String: Int64]) {
        let c = tc["conversation"] as? [String: Any] ?? [:]
        try db.execute(sql: """
            INSERT INTO chat_conversations (title, title_source, routing_mode, provider, model, actual_provider, actual_model,
                routing_reason, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 1)
            """, arguments: [c["title"] as? String ?? "", c["title_source"] as? String ?? "prefix",
                             c["routing_mode"] as? String ?? "preferred_reserve", c["provider"] as? String,
                             c["model"] as? String, c["actual_provider"] as? String ?? "", c["actual_model"] as? String ?? "",
                             c["routing_reason"] as? String ?? ""])
        let conv = db.lastInsertedRowID
        var ids: [String: Int64] = [:]
        var files: [String: Int64] = [:]
        var comments: [String: Int64] = [:]
        for (i, m) in (tc["messages"] as? [[String: Any]] ?? []).enumerated() {
            try db.execute(sql: """
                INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at, turn_id, status, provider, model, error_code)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [conv, (m["parent"] as? String).flatMap { ids[$0] }, m["role"] as? String, m["text"] as? String,
                                 m["created_at"] as? Double ?? 1_700_000_000 + Double(i), m["turn_id"] as? String ?? "",
                                 m["status"] as? String ?? "complete", m["provider"] as? String, m["model"] as? String,
                                 m["error_code"] as? String])
            ids[m["ref"] as? String ?? ""] = db.lastInsertedRowID
        }
        if let leaf = tc["active_leaf"] as? String {
            try ChatTreeQueries.setActiveLeaf(db, conversationID: conv, messageID: try XCTUnwrap(ids[leaf]))
        }
        for a in tc["artifacts"] as? [[String: Any]] ?? [] {
            let meta = try JSONSerialization.data(withJSONObject: a["meta"] ?? [String: String](), options: [.sortedKeys])
            try db.execute(sql: """
                INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """, arguments: [conv, (a["message"] as? String).flatMap { ids[$0] }, a["key"] as? String, a["version"] as? Int,
                                 a["kind"] as? String, a["title"] as? String, a["content"] as? String,
                                 String(bytes: meta, encoding: .utf8), (a["edited"] as? Bool ?? false) ? 1 : 0])
        }
        for f in tc["attachments"] as? [[String: Any]] ?? [] {
            try db.execute(sql: """
                INSERT INTO chat_attachments (conversation_id, message_id, name, mime, size, path, sha256, created_at)
                VALUES (?, ?, ?, ?, 1, ?, 'sha', 1)
                """, arguments: [conv, (f["message"] as? String).flatMap { ids[$0] }, f["name"] as? String, f["mime"] as? String,
                                 f["path"] as? String])
            files[f["ref"] as? String ?? ""] = db.lastInsertedRowID
        }
        for a in tc["actions"] as? [[String: Any]] ?? [] {
            try db.execute(sql: """
                INSERT INTO agent_actions (id, tool, args_json, conversation_id, status, result_json, error, created_at, decided_at, applied_at)
                VALUES (?, ?, '{}', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [a["id"] as? Int64, a["tool"] as? String, conv, a["status"] as? String, a["result_json"] as? String,
                                 a["error"] as? String, a["created_at"] as? String, a["decided_at"] as? String,
                                 a["applied_at"] as? String])
        }
        for c in tc["comments"] as? [[String: Any]] ?? [] {
            let status = c["status"] as? String ?? "open"
            try db.execute(sql: """
                INSERT INTO chat_artifact_comments (conversation_id, artifact_key, artifact_version, body, anchor_quote, status,
                    created_at, sent_at) VALUES (?, 'doc', 1, 'body', 'quote', ?, 1, ?)
                """, arguments: [conv, status, status == "sent" ? 1.0 : nil])
            comments[c["ref"] as? String ?? ""] = db.lastInsertedRowID
        }
        return (conv, ids, files, comments)
    }

    /// `ChatViewModel.sessionConfig` after `applyConversationSettings`, or the
    /// request's own pick.
    nonisolated private static func config(_ db: Database, conv: Int64, request: [String: Any]) throws -> Config {
        if let r = request["routing"] as? [String: Any] {
            let automatic = r["automatic"] as? Bool ?? false
            let model = r["model"] as? String ?? ""
            return Config(provider: automatic ? preferredProvider : r["provider"] as? String ?? "",
                          model: automatic || model.isEmpty ? nil : model, automatic: automatic)
        }
        let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT routing_mode, provider, model FROM chat_conversations WHERE id = ?",
                                                 arguments: [conv]))
        let automatic = (row["routing_mode"] as String) != "pinned"
        let model = row["model"] as String? ?? ""
        return Config(provider: automatic ? preferredProvider : row["provider"] as String? ?? preferredProvider,
                      model: automatic || model.isEmpty ? nil : model, automatic: automatic)
    }

    /// `ChatViewModel.send` / `regenerate` / `edit` → their `TurnPlan`.
    nonisolated private static func plan(
        _ db: Database,
        conv: Int64,
        request: [String: Any],
        ids: [String: Int64],
        files: [String: Int64],
        comments: [String: Int64],
        floor: String?
    ) throws -> Plan {
        let thread = try ChatTreeQueries.thread(db, conversationID: conv)
        let text = request["text"] as? String ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (request["message"] as? String).flatMap { ids[$0] }
        switch request["mode"] as? String {
        case "regenerate" where request["reuse_owner"] is String:
            // The Mac's regenerate hands persistTurnStart the owner row itself.
            let ownerID = (request["reuse_owner"] as? String).flatMap { ids[$0] }
            let owner = try XCTUnwrap(thread.first { $0.message.id == ownerID })
            return Plan(historyTipID: owner.message.parentID, userText: owner.message.text,
                        reuseUserMessageID: owner.message.id, attachments: owner.attachments, outcomes: nil,
                        forceReplay: true, titleText: nil)
        case "regenerate":
            let index = try XCTUnwrap(thread.firstIndex { $0.message.id == target })
            let owner = thread[index - 1]
            return Plan(historyTipID: owner.message.parentID, userText: owner.message.text,
                        reuseUserMessageID: owner.message.id, attachments: owner.attachments, outcomes: nil,
                        forceReplay: true, titleText: nil)
        case "edit":
            let item = try XCTUnwrap(thread.first { $0.message.id == target })
            return Plan(historyTipID: item.message.parentID,
                        userText: ChatTurnComposer.recompose(stored: item.message.text, newBody: trimmed),
                        reuseUserMessageID: nil, attachments: item.attachments, outcomes: nil, forceReplay: true, titleText: nil)
        default:
            let attachmentIDs = (request["attachments"] as? [String] ?? []).compactMap { files[$0] }
            let attachments = try attachmentIDs.map { id in
                try XCTUnwrap(try ChatAttachment.fetchOne(db, sql: "SELECT * FROM chat_attachments WHERE id = ?", arguments: [id]))
            }
            var outcomes: String?
            if let floor {
                let decided = try AgentActionQueries.fetchDecidedAfter(db, conversationID: conv, after: floor)
                outcomes = AgentToolsContract.actionsSinceLastTurnBlock(decided)
            }
            // A request with title_text carries the text as the composer
            // already built it (`send`'s turnText) and the owner's words apart.
            let titleText = request["title_text"] as? String
            return Plan(historyTipID: thread.last?.message.id,
                        userText: titleText == nil ? ChatTurnComposer.compose(text: text, skill: nil, mentions: []) : text,
                        reuseUserMessageID: nil, attachments: attachments, outcomes: outcomes, forceReplay: false,
                        titleText: titleText ?? trimmed,
                        quoteIDs: (request["quotes"] as? [String] ?? []).compactMap { comments[$0] })
        }
    }

    // MARK: - Checking

    nonisolated private static func check(
        _ db: Database,
        conv: Int64,
        ids: [String: Int64],
        files: [String: Int64],
        comments: [String: Int64],
        expect: [String: Any],
        name: String
    ) throws {
        var refOf = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
        let ref: (Int64?) -> Any? = { id in id.flatMap { refOf[$0] } }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY id",
                                    arguments: [conv])
        let wantMessages = expect["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, wantMessages.count, "\(name): message rows")
        for (row, want) in zip(rows, wantMessages) { refOf[row["id"] as Int64] = want["ref"] as? String }
        let messageKeys = ["role", "text", "parent", "status", "turn_id", "provider", "model", "tokens_in", "tokens_out",
                           "error_code", "error_message"]
        let gotMessages: [String] = rows.map { row in
            var d: [String: Any?] = [:]
            for key in messageKeys where key != "parent" { d[key] = row[key] as DatabaseValue }
            d["parent"] = ref(row["parent_id"] as Int64?)
            d["ref"] = ref(row["id"] as Int64)
            return norm(d)
        }
        XCTAssertEqual(gotMessages, wantMessages.map { norm(pick($0, messageKeys + ["ref"])) }, "\(name): messages")

        let steps = try Row.fetchAll(db, sql: """
            SELECT s.* FROM chat_turn_steps s JOIN chat_messages m ON m.id = s.message_id
            WHERE m.conversation_id = ? ORDER BY s.message_id, s.seq, s.id
            """, arguments: [conv])
        let gotSteps: [String] = steps.map { s in
            let okFlag: Int? = s["ok"]
            let ok: Any = okFlag.map { NSNumber(value: $0 == 1) } ?? NSNull()
            let ended: Bool = (s["ended_at"] as Double?) != nil
            return norm(["message": ref(s["message_id"] as Int64), "seq": s["seq"] as Int, "tool_id": s["tool_id"] as String,
                         "name": s["name"] as String, "args": parse(s["args_json"] as String), "ok": ok,
                         "summary": s["summary"] as String, "sources": parse(s["sources_json"] as String), "ended": ended])
        }
        let stepKeys = ["message", "seq", "tool_id", "name", "args", "ok", "summary", "sources", "ended"]
        XCTAssertEqual(gotSteps, (expect["steps"] as? [[String: Any]] ?? []).map { norm(pick($0, stepKeys)) },
                       "\(name): steps")

        let artifacts = try Row.fetchAll(db, sql: """
            SELECT * FROM chat_artifacts WHERE conversation_id = ? ORDER BY artifact_key, version
            """, arguments: [conv])
        let gotArtifacts: [String] = artifacts.map { a in
            let edited: Bool = (a["edited"] as Int) == 1
            return norm(["key": a["artifact_key"] as String, "version": a["version"] as Int, "message": ref(a["message_id"] as Int64),
                         "kind": a["kind"] as String, "title": a["title"] as String, "content": a["content"] as String,
                         "meta": parse(a["meta_json"] as String), "edited": edited])
        }
        let wantArtifactRows = (expect["artifacts"] as? [[String: Any]] ?? []).sorted { lhs, rhs in
            let l = (lhs["key"] as? String ?? "", lhs["version"] as? Int ?? 0)
            let r = (rhs["key"] as? String ?? "", rhs["version"] as? Int ?? 0)
            return l < r
        }
        XCTAssertEqual(gotArtifacts, wantArtifactRows.map {
            norm(pick($0, ["key", "version", "message", "kind", "title", "content", "meta", "edited"]))
        }, "\(name): artifacts")

        for (attachment, want) in expect["attachment_links"] as? [String: Any] ?? [:] {
            let message = try Int64.fetchOne(db, sql: "SELECT message_id FROM chat_attachments WHERE id = ?",
                                             arguments: [files[attachment]])
            XCTAssertEqual(ref(message) as? String, want as? String, "\(name): attachment \(attachment)")
        }

        for (comment, want) in expect["comments"] as? [String: String] ?? [:] {
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT status, sent_at FROM chat_artifact_comments WHERE id = ?",
                                                     arguments: [comments[comment]]), "\(name): comment \(comment)")
            XCTAssertEqual(row["status"] as String, want, "\(name): comment \(comment)")
            XCTAssertEqual((row["sent_at"] as Double?) != nil, want == "sent", "\(name): comment \(comment) sent_at")
        }

        let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM chat_conversations WHERE id = ?", arguments: [conv]))
        let convKeys = ["title", "title_source", "routing_mode", "provider", "model", "actual_provider", "actual_model",
                        "routing_reason", "session_id"]
        var gotConv: [String: Any?] = [:]
        for key in convKeys { gotConv[key] = row[key] as DatabaseValue }
        gotConv["active_leaf"] = ref(row["active_leaf_message_id"] as Int64?)
        gotConv["live_slack_since"] = ref(row["live_slack_since"] as Int64?)
        XCTAssertEqual(norm(gotConv), norm(pick(expect["conversation"] as? [String: Any] ?? [:],
                                                convKeys + ["active_leaf", "live_slack_since"])),
                       "\(name): conversation")
    }

    /// `keys` of `d`, a missing key as null.
    nonisolated private static func pick(_ d: [String: Any], _ keys: [String]) -> [String: Any?] {
        var out: [String: Any?] = [:]
        for key in keys { out[key] = d[key] }
        return out
    }

    nonisolated private static func parse(_ text: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
    }

    /// One row as sorted-key JSON: nil and SQL NULL as null, a database value
    /// as its plain value — so the comparison never depends on key order,
    /// spacing or number types.
    nonisolated private static func norm(_ d: [String: Any?]) -> String {
        var plain: [String: Any] = [:]
        for (key, value) in d {
            switch value {
            case nil, is NSNull: plain[key] = NSNull()
            case let v as DatabaseValue:
                switch v.storage {
                case .null: plain[key] = NSNull()
                case .int64(let n): plain[key] = n
                case .double(let x): plain[key] = x
                case .string(let s): plain[key] = s
                case .blob(let b): plain[key] = b.base64EncodedString()
                }
            case let v?: plain[key] = v
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: plain, options: [.sortedKeys]),
              let text = String(bytes: data, encoding: .utf8) else { return "\(plain)" }
        return text
    }
}
