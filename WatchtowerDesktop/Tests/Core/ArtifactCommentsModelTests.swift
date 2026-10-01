import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class ArtifactCommentsModelTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var conversationID: Int64 = 0
    private var messages: [Int64] = []

    private let v1 = """
    # Plan

    ## Risks

    Keep the retry budget small so a flaky service cannot stall the sync.

    ## Dates

    Ship on Friday.
    """

    override func setUp() async throws {
        queue = try TestDatabase.create()
        (conversationID, messages) = try await queue.write { db in
            let conversation = try TestDatabase.insertChatConversation(db)
            var ids: [Int64] = []
            for _ in 0..<4 {
                ids.append(try TestDatabase.insertChatMessage(db, conversationID: conversation, role: "assistant", text: ""))
            }
            return (conversation, ids)
        }
    }

    /// Stores a version of the "plan" artifact produced by `messages[index]`.
    private func store(_ content: String, message index: Int, kind: String = "document") throws {
        let draft = ArtifactDraft(key: "plan", kind: kind, title: "Plan", meta: [:], content: content, isComplete: true)
        _ = try queue.write {
            try ChatArtifactQueries.saveVersion($0, conversationID: conversationID, messageID: messages[index],
                                                draft: draft, edited: false)
        }
    }

    private func makePanel() -> ArtifactPanelModel {
        ArtifactPanelModel(db: queue, conversationID: conversationID, key: "plan")
    }

    private func range(_ needle: String, in model: ArtifactCommentsModel) throws -> NSRange {
        let text = try XCTUnwrap(model.rendered?.text)
        let found = (text as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "\(needle) not in the rendered text")
        return found
    }

    private func row(_ id: Int64) throws -> ArtifactComment? {
        try queue.read {
            try ArtifactComment.fetchOne($0, sql: "SELECT * FROM chat_artifact_comments WHERE id = ?", arguments: [id])
        }
    }

    func testCommentAnchorsOnTheLatestVersionsRenderedText() throws {
        try store(v1, message: 0)
        let model = makePanel().comments
        XCTAssertTrue(model.add(body: "Why so small?", selection: try range("retry budget small", in: model)))
        let comment = try XCTUnwrap(model.comments.first)
        XCTAssertEqual(comment.anchorQuote, "retry budget small")
        XCTAssertEqual(comment.anchorHeading, "Risks")
        XCTAssertEqual(comment.artifactVersion, 1)
        XCTAssertEqual(comment.status, .open)
        XCTAssertEqual(model.ranges[comment.id], try range("retry budget small", in: model))
    }

    func testEmptySelectionOrBodyWritesNothing() throws {
        try store(v1, message: 0)
        let model = makePanel().comments
        XCTAssertFalse(model.add(body: "x", selection: NSRange(location: 3, length: 0)))
        XCTAssertFalse(model.add(body: "   ", selection: try range("retry", in: model)))
        XCTAssertTrue(model.comments.isEmpty)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_artifact_comments") }, 0)
    }

    func testANewVersionThatKeepsThePassageMovesTheCommentOntoIt() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Why so small?", selection: try range("retry budget small", in: panel.comments))
        let id = try XCTUnwrap(panel.comments.comments.first?.id)

        try store("Intro added by the assistant.\n\n" + v1.replacingOccurrences(of: "Ship on Friday.", with: "Ship on Thursday."),
                  message: 1)
        panel.turnFinished()

        XCTAssertEqual(try row(id)?.status, .open)
        XCTAssertEqual(try row(id)?.artifactVersion, 2)
        XCTAssertEqual(panel.comments.ranges[id], try range("retry budget small", in: panel.comments))
    }

    func testANewVersionWithoutThePassageMakesOnlyThatCommentOutdated() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Why so small?", selection: try range("retry budget small", in: panel.comments))
        panel.comments.add(body: "Thursday?", selection: try range("Ship on Friday", in: panel.comments))
        let (risk, date) = (panel.comments.comments[0].id, panel.comments.comments[1].id)

        try store(v1.replacingOccurrences(of: "Keep the retry budget small so a flaky service cannot stall the sync.",
                                          with: "Retries are unbounded."), message: 1)
        panel.turnFinished()

        XCTAssertEqual(try row(risk)?.status, .outdated)
        XCTAssertEqual(try row(risk)?.artifactVersion, 1)
        XCTAssertNil(panel.comments.ranges[risk])
        XCTAssertEqual(try row(date)?.status, .open)
        XCTAssertEqual(try row(date)?.artifactVersion, 2)
        XCTAssertEqual(panel.comments.outdated.map(\.id), [risk])
        XCTAssertEqual(panel.comments.unsent.map(\.id), [date])
    }

    func testSentCommentsAreReanchoredAndResolvedOnesOnlyLoseTheirHighlight() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Why so small?", selection: try range("retry budget small", in: panel.comments))
        panel.comments.add(body: "Thursday?", selection: try range("Ship on Friday", in: panel.comments))
        let (sent, resolved) = (panel.comments.comments[0].id, panel.comments.comments[1].id)
        try queue.write { db in
            try ArtifactCommentQueries.markSent(db, ids: [sent, resolved], at: Date())
            try ArtifactCommentQueries.resolve(db, id: resolved)
        }

        try store("# Plan\n\nAll rewritten.", message: 1)
        panel.turnFinished()

        XCTAssertEqual(try row(sent)?.status, .outdated)
        XCTAssertNotNil(try row(sent)?.sentAt, "an outdated sent comment keeps sent_at")
        XCTAssertEqual(try row(resolved)?.status, .resolved)
        XCTAssertTrue(panel.comments.ranges.isEmpty)
    }

    func testTheOwnersEditIsANewVersionAndReanchorsLikeAnyOther() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Thursday?", selection: try range("Ship on Friday", in: panel.comments))
        let id = try XCTUnwrap(panel.comments.comments.first?.id)
        panel.beginEdit()
        panel.editText = panel.editText.replacingOccurrences(of: "Ship on Friday.", with: "Ship on Thursday.")
        panel.saveEdit()
        XCTAssertEqual(try row(id)?.status, .outdated)
    }

    func testAnOutdatedCommentIsNeverReattachedWhenItsTextComesBack() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Thursday?", selection: try range("Ship on Friday", in: panel.comments))
        let id = try XCTUnwrap(panel.comments.comments.first?.id)
        try store("# Plan\n\nRewritten.", message: 1)
        panel.turnFinished()
        try store(v1, message: 2)
        panel.turnFinished()
        XCTAssertEqual(try row(id)?.status, .outdated)
        XCTAssertNil(panel.comments.ranges[id])
    }

    func testUnsentAreInTextOrderAndTheOutgoingMessageCarriesExactlyThem() throws {
        try store(v1, message: 0)
        let model = makePanel().comments
        model.add(body: "Thursday?", selection: try range("Ship on Friday", in: model))
        model.add(body: "Why so small?", selection: try range("retry budget small", in: model))
        model.add(body: "Already sent", selection: try range("flaky service", in: model))
        let alreadySent = try XCTUnwrap(model.comments.last?.id)
        _ = try queue.write { try ArtifactCommentQueries.markSent($0, ids: [alreadySent], at: Date()) }
        model.reload()

        XCTAssertEqual(model.unsent.map(\.body), ["Why so small?", "Thursday?"])
        XCTAssertEqual(model.sent.map(\.id), [alreadySent])
        let outgoing = try XCTUnwrap(model.outgoing())
        XCTAssertEqual(outgoing.ids, model.unsent.map(\.id))
        XCTAssertEqual(outgoing.text,
                       ArtifactCommentMessage.compose(title: "Plan", key: "plan", version: 1, comments: model.unsent))
    }

    func testNothingUnsentHasNoOutgoingMessage() throws {
        try store(v1, message: 0)
        XCTAssertNil(makePanel().comments.outgoing())
    }

    func testDeleteAndResolveFollowTheStatusRules() throws {
        try store(v1, message: 0)
        let model = makePanel().comments
        model.add(body: "Draft", selection: try range("Ship on Friday", in: model))
        model.add(body: "Sent", selection: try range("retry budget small", in: model))
        let (draft, sent) = (model.comments[0].id, model.comments[1].id)
        _ = try queue.write { try ArtifactCommentQueries.markSent($0, ids: [sent], at: Date()) }
        model.reload()
        model.delete(draft)
        model.resolve(sent)
        XCTAssertEqual(model.comments.map(\.id), [sent])
        XCTAssertEqual(model.resolved.map(\.id), [sent])
        XCTAssertNil(model.ranges[draft])
    }

    /// A table anchors on its cells as the panel shows them (#181: the
    /// panel reads and comments on one rendering); a draft message on its
    /// raw text.
    func testNonDocumentKindsAnchorOnTheTextThePanelShows() throws {
        try store("a,b\nretry,small", message: 0, kind: "table")
        let model = makePanel().comments
        XCTAssertEqual(model.rendered?.text, "a\nb\nretry\nsmall\n\n")
        XCTAssertTrue(model.add(body: "Rename", selection: try range("retry", in: model)))
    }

    func testCommentingNeedsTheLatestStoredVersionOnScreen() throws {
        try store(v1, message: 0)
        try store(v1 + "\n\nMore.", message: 1)
        let panel = makePanel()
        XCTAssertTrue(panel.canComment)
        panel.selectedVersion = 1
        XCTAssertFalse(panel.canComment, "an older version is read-only for comments")
        panel.selectedVersion = 2
        XCTAssertTrue(panel.canComment)
        panel.selectedVersion = nil
        panel.applyStreaming([ArtifactDraft(key: "plan", kind: "document", title: "Plan", meta: [:], content: "partial",
                                            isComplete: false)])
        XCTAssertFalse(panel.canComment, "a version being written is not commentable")
        panel.turnFinished()
        panel.beginEdit()
        XCTAssertFalse(panel.canComment, "editing and commenting are exclusive")
    }
}
