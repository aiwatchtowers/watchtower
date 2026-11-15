import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore
import WatchtowerChatText

/// LIVE-01 — a conversation that used the Live Slack connector, from that turn
/// on, stays out of every store that makes chat text lasting. The Go readers
/// are pinned by `TestLIVE01_*` in internal/db; this file pins the Swift side.
/// BEHAVIOR LIVE-01 — see docs/inventory/chat.md
final class LiveSlack01GuardTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var conversationID: Int64 = 0
    private var assistantID: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        (conversationID, assistantID) = try pool.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t1",
                                                           provider: "claude", model: "")
            return (conv, asst.id)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    private func addStep(_ name: String) throws {
        let (message, seq) = (assistantID, Int.random(in: 0..<1_000_000))
        try pool.write { d in
            try d.execute(sql: "INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, started_at) VALUES (?, ?, ?, ?, 0)",
                          arguments: [message, seq, "tool-\(seq)", name])
        }
    }

    private func finalize() async throws {
        try await ChatTurnStore(dbPool: pool).finalizeTurn(conversationID: conversationID, messageID: assistantID,
                                                           text: "answer", status: "complete", usage: nil, error: nil)
    }

    private func mark() throws -> Int64? {
        let conv = conversationID
        return try pool.read { try Int64.fetchOne($0, sql: "SELECT live_slack_since FROM chat_conversations WHERE id = ?", arguments: [conv]) }
    }

    func testFinalizeMarksConversationOnSlackStep() async throws {
        try addStep("search_knowledge")
        try addStep("claude_ai_Slack:slack_search_public")
        try await finalize()
        let marked = try mark()
        XCTAssertEqual(marked, assistantID)
    }

    func testStepStartMarksWithoutFinalize() async throws {
        let store = ChatTurnStore(dbPool: pool)
        let plain = ChatToolStart(turnID: "t1", id: "a", name: "search_knowledge", argsJSON: "{}")
        try await store.stepStarted(messageID: assistantID, seq: 0, start: plain, at: Date())
        let none = try mark()
        XCTAssertNil(none)
        let slack = ChatToolStart(turnID: "t1", id: "b", name: "codex_apps:slack.slack_search_public", argsJSON: "{}")
        try await store.stepStarted(messageID: assistantID, seq: 1, start: slack, at: Date())
        let marked = try mark()
        XCTAssertEqual(marked, assistantID)
    }

    func testFinalizeMarksConversationOnCodexSlackStep() async throws {
        try addStep("codex_apps:slack.slack_read_channel")
        try await finalize()
        let marked = try mark()
        XCTAssertEqual(marked, assistantID)
    }

    func testFinalizeLeavesUnmarkedWithoutSlackStep() async throws {
        try addStep("search_knowledge")
        try addStep("claude_ai_Gmail:search_threads")
        try addStep("list_slack_channels")
        try addStep("list_messages")
        try await finalize()
        let marked = try mark()
        XCTAssertNil(marked)
    }

    func testFirstMarkIsKept() async throws {
        try addStep("claude_ai_Slack:slack_read_thread")
        let conv = conversationID
        try await pool.write { try $0.execute(sql: "UPDATE chat_conversations SET live_slack_since = 1 WHERE id = ?", arguments: [conv]) }
        try await finalize()
        let marked = try mark()
        XCTAssertEqual(marked, 1)
    }

    /// Go's chat step names of every Slack connector tool (Claude: reads and
    /// writes; Codex: the read tools its allow-list shows), produced by the real
    /// translators in `TestLIVE01_StepNamesFixture`.
    private static func goStepNames() throws -> [String: [String]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/slacklive/testdata/slack_step_names.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(obj as? [String: [String]])
    }

    func testEveryGoSlackStepNameMarks() throws {
        let names = try Self.goStepNames()
        let claude = try XCTUnwrap(names["claude"])
        let codex = try XCTUnwrap(names["codex"])
        XCTAssertFalse(claude.isEmpty)
        XCTAssertFalse(codex.isEmpty)
        for name in claude + codex {
            XCTAssertTrue(LiveSlackMark.isSlackConnectorStep(name), name)
            // markIfSlackStep (the step-start writer) on a fresh conversation.
            let conv = try pool.write { d -> Int64 in
                let conv = try TestDatabase.insertChatConversation(d)
                let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t",
                                                               provider: "claude", model: "")
                try LiveSlackMark.markIfSlackStep(d, messageID: asst.id, name: name)
                return conv
            }
            let started = try pool.read { try LiveSlackMark.isMarked($0, conversationID: conv) }
            XCTAssertTrue(started, "step start: \(name)")
            // markIfUsed (the finalize backstop) on another fresh conversation.
            let conv2 = try pool.write { d -> Int64 in
                let conv = try TestDatabase.insertChatConversation(d)
                let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t",
                                                               provider: "claude", model: "")
                try d.execute(sql: "INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, started_at) VALUES (?, 0, 'x', ?, 0)",
                              arguments: [asst.id, name])
                try LiveSlackMark.markIfUsed(d, conversationID: conv, messageID: asst.id)
                return conv
            }
            let finalized = try pool.read { try LiveSlackMark.isMarked($0, conversationID: conv2) }
            XCTAssertTrue(finalized, "finalize: \(name)")
        }
    }

    func testKeepRefusedForLiveConversation() throws {
        let (conv, msg) = (conversationID, assistantID)
        try pool.write { d in
            try ChatArtifactQueries.keep(d, conversationID: conv, artifactKey: "plan", version: 1)
            try ChatArtifactQueries.unkeep(d, conversationID: conv, artifactKey: "plan")
            try d.execute(sql: "UPDATE chat_conversations SET live_slack_since = ? WHERE id = ?", arguments: [msg, conv])
        }
        do {
            try pool.write { try ChatArtifactQueries.keep($0, conversationID: conv, artifactKey: "plan", version: 1) }
            XCTFail("keep must be refused")
        } catch {
            XCTAssertEqual(error as? ChatArtifactKeepError, .liveSlack)
        }
        let kept = try pool.read { try ChatArtifactQueries.keptKeys($0, conversationID: conv) }
        XCTAssertTrue(kept.isEmpty)
    }

    @MainActor
    func testPanelExplainsWhyKeepIsDisabled() throws {
        let (conv, msg) = (conversationID, assistantID)
        try pool.write { d in
            let draft = ArtifactDraft(key: "plan", kind: "document", title: "Plan", meta: [:], content: "x", isComplete: true)
            _ = try ChatArtifactQueries.saveVersion(d, conversationID: conv, messageID: msg, draft: draft, edited: false)
        }
        let model = ArtifactPanelModel(db: pool, conversationID: conv, key: "plan")
        XCTAssertNil(model.keepDisabledReason)
        try pool.write { try $0.execute(sql: "UPDATE chat_conversations SET live_slack_since = ? WHERE id = ?", arguments: [msg, conv]) }
        model.reload()
        XCTAssertEqual(model.keepDisabledReason, "Built on Live Slack answers, which are not kept")
    }

    /// The panel disables Add with the reason (M2), but an artifact kept before
    /// the Live turn can still be removed.
    @MainActor
    func testPanelBlocksKeepButNotRemove() async throws {
        let (conv, msg) = (conversationID, assistantID)
        try await pool.write { d in
            let draft = ArtifactDraft(key: "plan", kind: "document", title: "Plan", meta: [:], content: "x", isComplete: true)
            _ = try ChatArtifactQueries.saveVersion(d, conversationID: conv, messageID: msg, draft: draft, edited: false)
        }
        let model = ArtifactPanelModel(db: pool, conversationID: conv, key: "plan")
        XCTAssertEqual(model.knowledgeState, .add)
        XCTAssertNil(model.knowledgeKeepBlocked)
        try await pool.write { try ChatArtifactQueries.keep($0, conversationID: conv, artifactKey: "plan", version: 1) }
        try await pool.write { try $0.execute(sql: "UPDATE chat_conversations SET live_slack_since = ? WHERE id = ?", arguments: [msg, conv]) }
        model.reload()
        XCTAssertEqual(model.knowledgeState, .remove)
        XCTAssertNil(model.knowledgeKeepBlocked, "Remove is never blocked")
        await model.toggleKnowledge()
        XCTAssertNil(model.keptVersion, "the earlier pin is dropped")
        XCTAssertEqual(model.knowledgeState, .add)
        XCTAssertEqual(model.knowledgeKeepBlocked, ArtifactPanelModel.liveSlackReason)
    }

    // MARK: - Reader list

    /// Files that checked the mark: the writer and the one path that pins text.
    private static let checked: Set<String> = ["ChatArtifactQueries.swift", "ChatTurnStore.swift", "LiveSlackMark.swift"]

    /// Files that mention a chat table without feeding a lasting store.
    private static let displayOnly: [String: String] = [
        "ChatConversationQueries.swift": "conversation list, titles, routing for the chat screens",
        "ChatMessageQueries.swift": "messages shown in the chat",
        "ChatTreeQueries.swift": "the chat's own branch tree and turn rows",
        "ChatStepQueries.swift": "tool steps shown under an answer",
        "ChatHistoryQueries.swift": "the history list",
        "ChatSearchQueries.swift": "search inside the chat screens",
        "ChatProjectQueries.swift": "project grouping of chats",
        "CodeQuestionList.swift": "workbench Questions tab, never leaves it",
        "EmbeddedChatStore.swift": "the embedded chat's own rows",
        "ChatSurfaceSpec.swift": "surface wiring, no read of text",
        "AutomationListSections.swift": "automation editor chats list",
        "ChatViewModel.swift": "the chat screen's own state",
        "CodeQuestionSurface.swift": "workbench Questions tab, never leaves it",
        "IdeaChatSurface.swift": "Discuss-an-idea chat, never mined",
        "DatabaseManager.swift": "table list of the database",
        "IdeaQueries.swift": "delete only",
        "LearnQueries.swift": "an existence signal, no text",
        "ChatCommand.swift": "comment only",
        "ChatErrorPresentation.swift": "comment only",
        "ChatModels.swift": "row types and comments",
        "ChatTurnDriver.swift": "the chat's own flushes",
        "CodeQuestionContext.swift": "comment only",
        "MeetingChatSurface.swift": "meeting chat surface wiring",
        "ReviewerSurface.swift": "Branch review thread, never leaves it",
        "SpecReviewThread.swift": "spec review thread constants",
        "SpecReviewThreadQueries.swift": "spec review thread list, never leaves its card",
        "SpecReviewThreadSurface.swift": "spec review thread surface, never leaves its card",
        "TargetChatViewModel.swift": "target chat screen state",
        "TrackChatSurface.swift": "track chat surface wiring",
        "TuningChatSurface.swift": "Analytics tuning chat, its own first-message title"
    ]

    /// A new Swift file that touches the chat tables must either apply the mark
    /// (and join `checked`) or be listed as display only, with its reason.
    func testReaderList() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = tests.deletingLastPathComponent().appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let tables = ["chat_messages", "chat_conversations", "chat_turn_steps", "chat_artifacts"]
        var unknown: [String] = []
        var seen: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard tables.contains(where: text.contains) else { continue }
            let name = url.lastPathComponent
            seen.insert(name)
            if !Self.checked.contains(name), Self.displayOnly[name] == nil { unknown.append(name) }
        }
        XCTAssertTrue(unknown.isEmpty, "touch the chat tables without LIVE-01 review: \(unknown.sorted())")
        XCTAssertTrue(Self.checked.isSubset(of: seen), "a checked reader no longer exists: \(Self.checked.subtracting(seen))")
        let stale = Set(Self.displayOnly.keys).subtracting(seen).sorted()
        XCTAssertTrue(stale.isEmpty, "stale display-only entry: \(stale)")
    }
}
