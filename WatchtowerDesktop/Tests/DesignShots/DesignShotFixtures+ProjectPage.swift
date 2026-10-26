import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The chat project page (spec 2026-10-26 §7) on fixed sample data: three
/// chats, instructions, two files and two pinned sources — or, `empty`, a
/// fresh project. One database per variant, made on first use and removed
/// by `cleanUp`; no session process is ever started (nothing is typed).
@MainActor
enum ProjectPageShotFixtures {
    private struct Fixture {
        let manager: DatabaseManager
        let path: String
        let pool: ChatSessionPool
        let chatVM: ChatViewModel
        let projectID: Int64
    }

    private static var fixtures: [Bool: Fixture] = [:]

    static func cleanUp() {
        for fixture in fixtures.values { TestDatabase.cleanup(path: fixture.path) }
        fixtures = [:]
    }

    static func page(empty: Bool = false) -> AnyView {
        do {
            let fixture = try fixture(empty: empty)
            return AnyView(
                ProjectDetailView(
                    projectID: fixture.projectID,
                    chatVM: fixture.chatVM,
                    dbPool: fixture.manager.dbPool,
                    attachmentsRoot: nil,
                    modelSuggestions: [],
                    maxComposerHeight: 200,
                    onOpenChat: { _ in }, onRenamed: {}, onDeleted: { _ in }, onPromptChanged: { _ in }
                )
                .detailBackground()
            )
        } catch {
            XCTFail("project page fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    private static func fixture(empty: Bool) throws -> Fixture {
        if let fixture = fixtures[empty] { return fixture }
        let (manager, path) = try TestDatabase.createDatabaseManager()
        let projectID = try manager.dbPool.write { db in
            let project = try ChatProjectQueries.create(db, name: empty ? "" : "acme research")
            guard !empty else { return project.id }
            try ChatProjectQueries.updateInstructions(
                db, id: project.id,
                instructions: "Answer briefly, in tables where you can. Numbers only from the project's sources, with a link.")
            let now = Date().timeIntervalSince1970
            for (title, age) in [("Pricing models of the competitors", 3600.0), ("Customer interviews: findings", 86400),
                                 ("Draft report for the team", 3 * 86400)] {
                let id = try TestDatabase.insertChatConversation(db, title: title, updatedAt: now - age)
                let msg = try TestDatabase.insertChatMessage(db, conversationID: id, role: "user", text: title)
                try db.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?",
                               arguments: [msg, id])
                try ChatConversationQueries.setProject(db, id: id, projectID: project.id)
            }
            for (name, mime) in [("market-report.pdf", "application/pdf"), ("interview-notes.md", "text/markdown")] {
                try db.execute(sql: """
                    INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
                    VALUES (?, ?, ?, 1, ?, 'h', 1)
                    """, arguments: [project.id, name, mime, "/tmp/\(name)"])
            }
            try ChatProjectQueries.addSource(db, projectID: project.id, kind: .jiraProject, ref: "ACME", label: "ACME")
            try ChatProjectQueries.addSource(db, projectID: project.id, kind: .slackChannel, ref: "1:C1", label: "#acme-research")
            return project.id
        }
        let pool = ChatSessionPool(dbPool: manager.dbPool) { FakeChatSessionProcess(arguments: $0) }
        let defaults = UserDefaults(suiteName: DesignShotFixtures.defaultsSuite) ?? .standard
        let chatVM = ChatViewModel(dbManager: manager, pool: pool, defaults: defaults, attachmentsRoot: nil)
        chatVM.openProject(projectID)
        let fixture = Fixture(manager: manager, path: path, pool: pool, chatVM: chatVM, projectID: projectID)
        fixtures[empty] = fixture
        return fixture
    }
}
