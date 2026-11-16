import Foundation
import GRDB
import WatchtowerChatText
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The Swift chat writers over Go's `chat_writes.json` (spec
/// 2026-11-15-mobile-inbox-design §8): each case's Swift writer, on the
/// case's seed, leaves the rows the Go `chat.*` command leaves. Until Task 18
/// deletes these writers this pins every Go port to them. The writers that
/// live in the app target run in `ChatWritesAppFixtureTests`.
final class ChatWritesFixtureTests: XCTestCase {
    func testSwiftWritersMatchEveryGoCase() async throws {
        let all = try ChatWritesFixture.cases()
        XCTAssertFalse(all.isEmpty)
        for fixtureCase in all where !ChatWritesFixture.appWriters.contains(fixtureCase.swift) {
            let (pool, path) = try ChatWritesFixture.seeded(fixtureCase)
            defer { TestDatabase.cleanup(path: path) }
            let root = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("chat_files")
            do {
                try await Self.run(fixtureCase, pool: pool, filesRoot: root)
            } catch let error as UnknownWriter {
                XCTFail("\(fixtureCase.name): no runner for \(error.name)")
                continue
            } catch {
                if fixtureCase.refusal == nil {
                    XCTFail("\(fixtureCase.name): \(fixtureCase.swift) threw \(error)")
                }
            }
            for mismatch in try ChatWritesFixture.mismatches(fixtureCase, in: pool) {
                XCTFail("\(fixtureCase.name) (\(fixtureCase.swift)): \(mismatch)")
            }
        }
    }

    struct UnknownWriter: Error { let name: String }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func run(_ fixtureCase: ChatWritesFixture.Case, pool: DatabasePool, filesRoot: URL) async throws {
        let params = fixtureCase.params
        let conv = params.int64("conversation_id") ?? 0
        let project = params.int64("project_id")
        switch fixtureCase.swift {
        case "ChatConversationQueries.create":
            let context = params.object("context")
            _ = try await pool.write { db in
                try ChatConversationQueries.create(db, title: context.string("title") ?? "",
                                                   contextType: context.string("type"), contextID: context.string("id"),
                                                   projectID: project)
            }
        case "ChatConversationQueries.create+setRouting":
            let routing = params.object("routing")
            try await pool.write { db in
                let created = try ChatConversationQueries.create(db, projectID: project)
                try ChatConversationQueries.setRouting(db, id: created.id, automatic: routing.bool("automatic"),
                                                       provider: routing.string("provider") ?? "", model: routing.string("model"))
            }
        case "ChatConversationQueries.create+setProviderModel":
            let context = params.object("context"), routing = params.object("routing")
            try await pool.write { db in
                let created = try ChatConversationQueries.create(db, title: context.string("title") ?? "",
                                                                 contextType: context.string("type"), contextID: context.string("id"))
                try ChatConversationQueries.setProviderModel(db, id: created.id, provider: routing.string("provider") ?? "",
                                                             model: routing.string("model"))
            }
        case "DatabaseEmbeddedChatStore.conversationID":
            let context = params.object("context")
            _ = try await DatabaseEmbeddedChatStore.conversationID(
                dbPool: pool, contextType: context.string("type") ?? "", contextID: context.string("id") ?? "",
                title: context.string("title") ?? "")
        case "ChatConversationQueries.pin":
            try await pool.write { try ChatConversationQueries.pin($0, id: conv, pinned: params.bool("pinned")) }
        case "ChatConversationQueries.rename":
            try await pool.write { try ChatConversationQueries.rename($0, id: conv, title: params.string("title") ?? "") }
        case "ChatConversationQueries.updateTitle":
            try await pool.write { try ChatConversationQueries.updateTitle($0, id: conv, title: params.string("title") ?? "") }
        case "ChatConversationQueries.delete":
            try await pool.write { try ChatConversationQueries.delete($0, id: conv) }
        case "CodeQuestionList.delete":
            _ = try await pool.write { try CodeQuestionList.delete($0, conversationID: conv) }
        case "ChatConversationQueries.deleteIfUntouched":
            _ = try await pool.write {
                try ChatConversationQueries.deleteIfUntouched($0, id: conv, createdAt: params.double("created_at") ?? 0,
                                                              projectID: project)
            }
        case "ChatConversationQueries.archive":
            try await pool.write { try ChatConversationQueries.archive($0, id: conv) }
        case "ChatTreeQueries.selectSibling":
            let message = params.int64("message_id") ?? 0
            try await pool.write { db in
                let owner = try Int64.fetchOne(db, sql: "SELECT conversation_id FROM chat_messages WHERE id = ?",
                                               arguments: [message]) ?? 0
                try ChatTreeQueries.selectSibling(db, conversationID: owner, siblingID: message)
            }
        case "ChatConversationQueries.markRead":
            try await pool.write { try ChatConversationQueries.markRead($0, id: conv) }
        case "ChatAttachmentStore.importData":
            let data = Data(base64Encoded: params.string("data_base64") ?? "") ?? Data()
            let owner: ChatAttachmentOwner = project.map { .project($0) } ?? .conversation(conv)
            _ = try await ChatAttachmentStore(db: pool, rootDir: filesRoot)
                .importData(data, name: params.string("name") ?? "", owner: owner)
        case "ChatAttachmentStore.discard":
            let id = params.int64("attachment_id") ?? 0
            let row = try await pool.read { db in
                try ChatAttachment.fetchOne(db, sql: "SELECT * FROM chat_attachments WHERE id = ?", arguments: [id])
            }
            if let row {
                try await ChatAttachmentStore(db: pool, rootDir: filesRoot).discard(row)
            }
        case "ChatAttachmentQueries.link":
            try await pool.write {
                try ChatAttachmentQueries.link($0, attachmentIDs: params.int64s("attachment_ids"),
                                               messageID: params.int64("message_id") ?? 0)
            }
        case "ChatConversationQueries.setProject":
            try await pool.write { try ChatConversationQueries.setProject($0, id: conv, projectID: project) }
        case "ChatConversationQueries.setRouting":
            let routing = params.object("routing")
            try await pool.write {
                try ChatConversationQueries.setRouting($0, id: conv, automatic: routing.bool("automatic"),
                                                       provider: routing.string("provider") ?? "", model: routing.string("model"))
            }
        case "ChatConversationQueries.setProviderModel":
            try await pool.write {
                try ChatConversationQueries.setProviderModel($0, id: conv, provider: params.string("provider") ?? "",
                                                             model: params.string("model"))
            }
        case "DatabaseEmbeddedChatStore.rekeyConversation":
            _ = try await DatabaseEmbeddedChatStore.rekeyConversation(
                dbPool: pool, conversationID: conv, toContextType: params.string("context_type") ?? "",
                contextID: params.string("context_id") ?? "")
        case "ReviewerThreadQueries.ensure":
            _ = try await pool.write {
                try ReviewerThreadQueries.ensure($0, projectID: project ?? 0, branch: params.string("branch") ?? "")
            }
        case "CodeQuestionList.deleteEmpty":
            _ = try await pool.write {
                try CodeQuestionList.deleteEmpty($0, workbenchID: params.int64("workbench_id") ?? 0,
                                                 createdBefore: params.double("created_before") ?? 0,
                                                 keeping: Set(params.int64s("keeping")))
            }
        default:
            try await runLeaseProjectCommentWriters(fixtureCase, pool: pool)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func runLeaseProjectCommentWriters(_ fixtureCase: ChatWritesFixture.Case, pool: DatabasePool) async throws {
        let params = fixtureCase.params
        let conv = params.int64("conversation_id") ?? 0
        let project = params.int64("project_id") ?? 0
        let now = ChatLease.milliseconds(Date())
        switch fixtureCase.swift {
        case "ChatLeaseQueries.requestCancel":
            _ = try await pool.write {
                try ChatLeaseQueries.requestCancel($0, conversationID: conv, turnID: params.string("turn_id") ?? "", nowMS: now)
            }
        case "ChatLeaseQueries.release":
            try await pool.write { try ChatLeaseQueries.release($0, conversationID: conv, turnID: params.string("turn_id") ?? "") }
        case "ChatLeaseQueries.releaseEarlierDesktopLaunches":
            _ = try await pool.write {
                try ChatLeaseQueries.releaseEarlierDesktopLaunches($0, currentLaunchID: params.string("keep") ?? "")
            }
        case "ChatProjectQueries.create":
            _ = try await pool.write { try ChatProjectQueries.create($0, name: params.string("name") ?? "") }
        case "ChatProjectQueries.rename":
            try await pool.write { try ChatProjectQueries.rename($0, id: project, name: params.string("name") ?? "") }
        case "ChatProjectQueries.updateInstructions":
            try await pool.write {
                try ChatProjectQueries.updateInstructions($0, id: project, instructions: params.string("instructions") ?? "")
            }
        case "ChatProjectQueries.archive":
            try await pool.write { try ChatProjectQueries.archive($0, id: project) }
        case "ChatProjectQueries.delete":
            _ = try await pool.write { try ChatProjectQueries.delete($0, id: project) }
        case "ChatProjectQueries.addSource":
            let kind = try XCTUnwrap(ChatProjectSource.Kind(rawValue: params.string("kind") ?? ""))
            _ = try await pool.write {
                try ChatProjectQueries.addSource($0, projectID: project, kind: kind, ref: params.string("ref") ?? "",
                                                 label: params.string("label") ?? "")
            }
        case "ChatProjectQueries.removeSource":
            _ = try await pool.write { try ChatProjectQueries.removeSource($0, id: params.int64("source_id") ?? 0) }
        case "ChatProjectQueries.removeFile":
            _ = try await pool.write { try ChatProjectQueries.removeFile($0, id: params.int64("attachment_id") ?? 0) }
        case "ArtifactCommentQueries.add":
            let anchor = params.object("anchor")
            _ = try await pool.write {
                try ArtifactCommentQueries.add(
                    $0, conversationID: conv, key: params.string("artifact_key") ?? "",
                    version: Int(params.int64("version") ?? 0),
                    anchor: CommentAnchor(quote: anchor.string("quote") ?? "", prefix: anchor.string("prefix") ?? "",
                                          suffix: anchor.string("suffix") ?? "", heading: anchor.string("heading") ?? ""),
                    body: params.string("body") ?? "")
            }
        case "ArtifactCommentQueries.deleteUnsent":
            _ = try await pool.write { try ArtifactCommentQueries.deleteUnsent($0, id: params.int64("comment_id") ?? 0) }
        case "ArtifactCommentQueries.resolve":
            _ = try await pool.write { try ArtifactCommentQueries.resolve($0, id: params.int64("comment_id") ?? 0) }
        case "ArtifactCommentQueries.markSent":
            _ = try await pool.write {
                try ArtifactCommentQueries.markSent($0, ids: params.int64s("comment_ids"),
                                                    at: Date(timeIntervalSince1970: params.double("sent_at") ?? 0))
            }
        case "ArtifactCommentQueries.apply":
            var plan = ArtifactCommentReanchor.Plan()
            plan.moved = params.int64s("moved")
            plan.lost = params.int64s("lost")
            let version = Int(params.int64("version") ?? 0)
            try await pool.write { [plan] in try ArtifactCommentQueries.apply($0, plan: plan, version: version) }
        case "QueuedDraftQueries.save":
            try await pool.write {
                try QueuedDraftQueries.save($0, key: params.string("surface_key") ?? "", text: params.string("text") ?? "", at: Date())
            }
        case "QueuedDraftQueries.clear":
            try await pool.write { try QueuedDraftQueries.clear($0, key: params.string("surface_key") ?? "") }
        case "ChatArtifactQueries.keep":
            try await pool.write {
                try ChatArtifactQueries.keep($0, conversationID: conv, artifactKey: params.string("artifact_key") ?? "",
                                             version: Int(params.int64("version") ?? 0))
            }
        case "ChatArtifactQueries.unkeep":
            try await pool.write {
                try ChatArtifactQueries.unkeep($0, conversationID: conv, artifactKey: params.string("artifact_key") ?? "")
            }
        case "ChatArtifactQueries.saveVersion":
            let draft = ArtifactDraft(
                key: params.string("artifact_key") ?? "", kind: params.string("kind") ?? "", title: params.string("title") ?? "",
                meta: params.object("meta").compactMapValues { $0 as? String }, content: params.string("content") ?? "",
                isComplete: true)
            _ = try await pool.write {
                try ChatArtifactQueries.saveVersion($0, conversationID: conv, messageID: params.int64("message_id") ?? 0,
                                                    draft: draft, edited: true)
            }
        default:
            throw UnknownWriter(name: fixtureCase.swift)
        }
    }
}
