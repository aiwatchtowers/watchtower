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

    // The mark itself (the turn's start and end, every Go step name, the
    // keep refusal) is written by Go now: `TestFinalizeMarksConversationOnSlackStep`,
    // `TestStepStartMarksWithoutFinalize`, `TestFinalizeMarksConversationOnCodexSlackStep`,
    // `TestFinalizeLeavesUnmarkedWithoutSlackStep`, `TestFirstMarkIsKept`,
    // `TestEveryGoSlackStepNameMarks` and `TestKeepRefusedForLiveConversation`
    // in internal/chatstore/moved_guards_test.go. The panel's side stays here.

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

    /// Files that check the mark (the panel's Add to Knowledge reads it
    /// through `LiveSlackMark.isMarked`; Go writes it and refuses the keep).
    private static let checked: Set<String> = ["LiveSlackMark.swift"]

    /// Files that mention a chat table without feeding a lasting store.
    private static let displayOnly: [String: String] = [
        "ChatConversationQueries.swift": "conversation list, titles, routing for the chat screens",
        "ChatArtifactQueries.swift": "artifact versions shown in the panel (Go writes and keeps them)",
        "ChatMessageQueries.swift": "messages shown in the chat",
        "ChatTreeQueries.swift": "the chat's own branch tree and turn rows",
        "ChatStepQueries.swift": "tool steps shown under an answer",
        "ChatHistoryQueries.swift": "the history list",
        "ChatSearchQueries.swift": "search inside the chat screens",
        "ChatProjectQueries.swift": "project grouping of chats",
        "CodeQuestionList.swift": "workbench Questions tab, never leaves it",
        "ChatSurfaceSpec.swift": "surface wiring, no read of text",
        "ChatToolCatalog.swift": "names the chat-history tools in step labels, no read",
        "EmbeddedChatReplay.swift": "names the chat-history tools in the replay hint, no read",
        "AutomationListSections.swift": "automation editor chats list",
        "CodeQuestionSurface.swift": "workbench Questions tab, never leaves it",
        "IdeaChatSurface.swift": "Discuss-an-idea chat, never mined",
        "DatabaseManager.swift": "table list of the database",
        "IdeaQueries.swift": "delete only",
        "LearnQueries.swift": "an existence signal, no text",
        "ChatCommand.swift": "comment only",
        "ChatModels.swift": "row types and comments",
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
