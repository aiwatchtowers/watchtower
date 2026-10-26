import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatPanelRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func conversation(updatedAt: Double, readAt: Double?) throws -> ChatConversation {
        let db = try TestDatabase.create()
        return try db.write { d in
            let id = try TestDatabase.insertChatConversation(d, title: "t", updatedAt: updatedAt)
            try d.execute(sql: "UPDATE chat_conversations SET read_at = ? WHERE id = ?", arguments: [readAt, id])
            return try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: id))
        }
    }

    private func row(
        answeredAgo: TimeInterval? = 7200,
        readAt: Double? = nil,
        preview: String = "Done.",
        pending: Int = 0,
        tool: String? = nil,
        project: String? = nil
    ) throws -> ChatPanelRow {
        let updated = now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970
        return ChatPanelRow(
            conversation: try conversation(updatedAt: updated, readAt: readAt),
            lastAnswerAt: answeredAgo.map { now.addingTimeInterval(-$0) },
            lastAnswerPreview: preview, pendingApprovals: pending, pendingTool: tool, projectName: project)
    }

    // MARK: unread

    func testUnreadAgainstReadAt() throws {
        let answeredAt = now.addingTimeInterval(-7200).timeIntervalSince1970
        XCTAssertTrue(try row(readAt: answeredAt - 1).isUnread, "answer newer than the mark")
        XCTAssertFalse(try row(readAt: answeredAt).isUnread, "marked at the answer")
        XCTAssertFalse(try row(readAt: answeredAt + 1).isUnread, "marked after the answer")
        XCTAssertTrue(try row(readAt: nil).isUnread, "never marked read")
        XCTAssertFalse(try row(answeredAgo: nil, readAt: nil).isUnread, "no answer yet")
    }

    // MARK: state precedence

    func testStatePrecedence() throws {
        let unreadPending = try row(readAt: nil, pending: 1, tool: "create_target")
        // A live turn blocked on an Approve card waits for the owner.
        XCTAssertEqual(ChatPanelRowState(row: unreadPending, isAnswering: true), .waitingForApproval)
        XCTAssertEqual(ChatPanelRowState(row: unreadPending, isAnswering: false), .waitingForApproval)
        XCTAssertEqual(ChatPanelRowState(row: try row(readAt: nil), isAnswering: true), .answering)
        XCTAssertEqual(ChatPanelRowState(row: try row(readAt: now.timeIntervalSince1970), isAnswering: true), .answering)
        XCTAssertEqual(ChatPanelRowState(row: try row(readAt: nil), isAnswering: false), .unread)
        XCTAssertEqual(ChatPanelRowState(row: try row(readAt: now.timeIntervalSince1970), isAnswering: false), .read)
        XCTAssertEqual(ChatPanelRowState(row: try row(answeredAgo: nil), isAnswering: false), .read)
    }

    func testAccessibilityLabelsDiffer() {
        XCTAssertEqual(Set(ChatPanelRowState.allCases.map(\.accessibilityLabel)).count, ChatPanelRowState.allCases.count)
    }

    // MARK: second line

    private func line(_ text: String, _ age: String? = nil) -> ChatPanelSecondLine {
        ChatPanelSecondLine(text: text, age: age)
    }

    func testSecondLineAnsweringAndWaiting() throws {
        let pending = try row(pending: 2, tool: "create_target", project: "Project A")
        XCTAssertEqual(ChatPanelRowState.answering.secondLine(for: pending, now: now, showsProject: true), line("Answering…"))
        XCTAssertEqual(ChatPanelRowState.waitingForApproval.secondLine(for: pending, now: now, showsProject: true),
                       line("Waiting for approval: \(ReactionToolCatalog.title(for: "create_target"))"))
        let noTool = try row(pending: 1, tool: nil)
        XCTAssertEqual(ChatPanelRowState.waitingForApproval.secondLine(for: noTool, now: now, showsProject: false),
                       line("Waiting for approval"))
    }

    /// The tool is named as its approval card names it, never by its id.
    func testWaitingNamesTheToolByItsCardTitleOrNotAtAll() throws {
        let connector = try row(pending: 1, tool: ConnectorCallProposal.tool)
        XCTAssertEqual(ChatPanelRowState.waitingForApproval.secondLine(for: connector, now: now, showsProject: false),
                       line("Waiting for approval: Use a claude.ai connector"))
        let unknown = try row(pending: 1, tool: "some_future_tool")
        XCTAssertEqual(ChatPanelRowState.waitingForApproval.secondLine(for: unknown, now: now, showsProject: false),
                       line("Waiting for approval"))
    }

    func testSecondLinePreviewAgeAndProject() throws {
        let inProject = try row(preview: "Done.", project: "Project A")
        XCTAssertEqual(ChatPanelRowState.read.secondLine(for: inProject, now: now, showsProject: true),
                       line("Project A · Done.", "2h"))
        XCTAssertEqual(ChatPanelRowState.unread.secondLine(for: inProject, now: now, showsProject: false),
                       line("Done.", "2h"))
        let plain = try row(answeredAgo: 4 * 86_400, preview: "Done.")
        let shown = ChatPanelRowState.read.secondLine(for: plain, now: now, showsProject: true)
        XCTAssertEqual(shown, line("Done.", "4d"))
        XCTAssertEqual(shown.ageLabel, "· 4d")
        XCTAssertEqual(shown.joined, "Done. · 4d")
    }

    /// No answer yet: only the age, of the chat itself (three days here).
    func testSecondLineWithoutAnswerShowsOnlyTheAge() throws {
        let fresh = try row(answeredAgo: nil, preview: "")
        let shown = ChatPanelRowState.read.secondLine(for: fresh, now: now, showsProject: true)
        XCTAssertEqual(shown, line("", "3d"))
        XCTAssertEqual(shown.ageLabel, "3d")
        XCTAssertEqual(shown.joined, "3d")
        let inProject = try row(answeredAgo: nil, preview: "", project: "Project A")
        XCTAssertEqual(ChatPanelRowState.read.secondLine(for: inProject, now: now, showsProject: true),
                       line("Project A", "3d"))
    }

    // MARK: preview

    func testPreviewIsTheFirstLineStripped() {
        XCTAssertEqual(ChatPanelRow.preview("## **Plan** for `today`\nmore text"), "Plan for today")
        XCTAssertEqual(ChatPanelRow.preview("> quoted *bit*"), "quoted bit")
        XCTAssertEqual(ChatPanelRow.preview("- [link](https://example.com) item"), "link item")
        XCTAssertEqual(ChatPanelRow.preview("\n\n```swift\nlet x = 1\n```"), "let x = 1")
        XCTAssertEqual(ChatPanelRow.preview(""), "")
    }
}
