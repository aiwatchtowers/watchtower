import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// An ask's text and fields (#394): the agent's text renders as markdown
/// with links that open (http(s) in the browser, a workbench path in
/// Files), a closed ask's answer too, and every field of the drawer is the
/// shared multi-line editor writing to the draft.
@MainActor
final class OwnerAskTextTests: XCTestCase {
    nonisolated private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#

    private func ask(kind: String = "question", summary: String = "", payload: String = "{}") throws -> OwnerAsk {
        try OwnerAsk(row: Row([
            "id": 1, "project_id": 1, "kind": kind, "title": "Ask", "status": "open", "summary": summary, "payload": payload
        ]))
    }

    private func attributedTexts(_ view: some View) throws -> [AttributedString] {
        try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.attributedString() }
    }

    private func links(_ view: some View) throws -> [URL] {
        try attributedTexts(view).flatMap { text in text.runs.compactMap(\.link) }
    }

    // MARK: - Rendering

    func testTheSummaryRendersMarkdownWithALink() throws {
        let card = OwnerAskHeaderCard(ask: try ask(summary: "Read [the spec](https://example.com/spec), **then** answer"))
        XCTAssertEqual(try links(card), [try XCTUnwrap(URL(string: "https://example.com/spec"))])
        let texts = try attributedTexts(card)
        XCTAssertTrue(texts.contains { String($0.characters) == "Read the spec, then answer" }, "the markup is not shown")
        XCTAssertTrue(texts.contains { $0.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true } })
    }

    /// In the drawer `OwnerAskLinks` turns on code links, and
    /// `MarkdownView` renders a workbench path as a link to the file (the
    /// chain it runs; an environment value does not reach ViewInspector).
    func testAPathInTheTextLinksToTheFile() throws {
        let summary = "Changed `cmd/run.go:40` and [the plan](docs/plan.md)"
        guard case let .paragraph(inlines)? = MarkdownDocument.parse(CodeLineLinks.linkified(summary)).first else {
            return XCTFail("one paragraph")
        }
        XCTAssertEqual(MarkdownView.inlineText(inlines, codeLinks: true).runs.compactMap(\.link?.absoluteString), [
            CodeLineLinks.url(path: "cmd/run.go", line: 40, col: nil),
            CodeLineLinks.url(path: "docs/plan.md", line: 1, col: nil)
        ])
    }

    func testChecklistItemsAndAClosedAsksNotesRenderLinks() throws {
        let body = OwnerAskChecklistBody(
            items: [OwnerAskCheckItem(id: "1", text: "Open [the page](https://example.com/page)", hint: "See *the log*")],
            marks: ["1": .broken],
            notes: ["1": "Fails, see [trace](https://example.com/trace)"],
            editable: false
        )
        XCTAssertEqual(try links(body).map(\.absoluteString), ["https://example.com/page", "https://example.com/trace"])
    }

    func testQuestionsAndOptionDescriptionsRenderLinks() throws {
        let card = ChatQuestionCard(questions: [
            ChatQuestion(id: "q", question: "Keep [the flag](https://example.com/flag)?", options: [
                ChatQuestionOption(label: "**Yes**", description: "As in [the RFC](https://example.com/rfc)"),
                ChatQuestionOption(label: "No")
            ])
        ])
        let view = ChatQuestionCardView(card: card, answerText: nil, onAnswer: nil, draftPicks: .constant([:]))
        XCTAssertEqual(try links(view).map(\.absoluteString), ["https://example.com/flag", "https://example.com/rfc"])
        XCTAssertNoThrow(try view.inspect().find(button: "Yes"), "the label renders without its markup")
    }

    /// Every link the text renders opens something: a file, or the
    /// system for an allowlisted scheme; any other scheme is stripped
    /// before it renders, so none looks clickable and does nothing.
    func testLinkRoutes() throws {
        let file = try XCTUnwrap(URL(string: CodeLineLinks.url(path: "a.go", line: 3, col: nil)))
        XCTAssertEqual(OwnerAskLinks.route(file), .file(OpenQuicklyTarget(path: "a.go", line: 3, col: nil)))
        for url in ["https://example.com", "HTTP://example.com", "mailto:someone@example.com", "slack://channel?id=C1"] {
            XCTAssertEqual(OwnerAskLinks.route(try XCTUnwrap(URL(string: url))), .system, url)
        }
        let escaping = try XCTUnwrap(URL(string: CodeLineLinks.url(path: "../x.go", line: 1, col: nil)))
        for url in ["file:///etc/hosts", "smb://host/x", escaping.absoluteString] {
            XCTAssertEqual(OwnerAskLinks.route(try XCTUnwrap(URL(string: url))), .refused, url)
        }
        let card = OwnerAskHeaderCard(ask: try ask(summary: "[hosts](file:///etc/hosts) or [share](smb://host/x)"))
        XCTAssertEqual(try links(card), [], "a refused scheme renders as plain text")
    }

    // MARK: - Fields

    func testACheckNoteIsTheMultiLineEditorWritingTheDraft() throws {
        var written: [String: String] = [:]
        let setNote: (String, String) -> Void = { written[$0] = $1 }
        let body = OwnerAskChecklistBody(
            items: [OwnerAskCheckItem(id: "1", text: "Step")], marks: ["1": .broken], notes: [:], editable: true, setNote: setNote
        )
        let editor = try body.inspect().find(CommentTextEditor.self).actualView()
        XCTAssertEqual(editor.minHeight, CommentTextEditor.formMinHeight, "several lines tall from the start")
        XCTAssertNotNil(editor.onSubmit, "⌘↩ leaves the field")
        editor.text = "Line one\nline two"
        XCTAssertEqual(written, ["1": "Line one\nline two"])
    }

    func testAnAsksOtherAnswerIsTheTallEditorAndTheChatsStaysCompact() throws {
        let card = ChatQuestionCard(questions: [ChatQuestion(id: "q", question: "Which?", options: [ChatQuestionOption(label: "A")])])
        var stored: [String: ChatQuestionAnswer.Entry] = [:]
        let picks = Binding(get: { stored }, set: { stored = $0 })
        let onAsk = try ChatQuestionCardView(card: card, answerText: nil, onAnswer: nil, draftPicks: picks)
            .inspect().find(CommentTextEditor.self).actualView()
        XCTAssertEqual(onAsk.minHeight, CommentTextEditor.formMinHeight)
        onAsk.text = "Neither:\nB"
        XCTAssertEqual(stored["q"]?.other, "Neither:\nB")

        var sent: String?
        let chat = ChatQuestionCardView(card: card, answerText: nil) { sent = $0 }
        let field = try chat.inspect().find(CommentTextEditor.self).actualView()
        XCTAssertLessThan(field.minHeight, CommentTextEditor.formMinHeight, "one line in the chat, growing as typed")
        XCTAssertNil(field.onSubmit, "⌘↩ sends nothing while the card is incomplete")
        XCTAssertThrowsError(try chat.inspect().find(ViewType.TextField.self))
        XCTAssertNil(sent)
    }

    func testTheDrawersNoteIsTheMultiLineEditorWritingTheDraft() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (project, askID) = try await pool.write { db in
            let project = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme")
            return (project, try TestDatabase.insertOwnerAsk(db, projectID: project, payload: Self.questions))
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAskTextTests-\(UUID().uuidString)"))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        await vm.asks.load(projectID: project)
        let open = try XCTUnwrap(vm.asks.openAsks[project]?.first { $0.id == askID })
        let editors = try OwnerAskDrawer(vm: vm, ask: open).inspect().findAll(CommentTextEditor.self).map { try $0.actualView() }
        XCTAssertEqual(editors.count, 2, "the question's Other and the note")
        XCTAssertTrue(editors.allSatisfy { $0.minHeight == CommentTextEditor.formMinHeight })
        let note = try XCTUnwrap(editors.last)
        note.text = "First line\nsecond line"
        XCTAssertEqual(vm.asks.drafts.askDraft(for: askID).note, "First line\nsecond line", "kept in the draft as before")
    }

    func testMarginCommentsAreTheMultiLineEditor() throws {
        let anchor = CommentAnchor(quote: "q", prefix: "", suffix: "", heading: "")
        let margin = OwnerAskMarginComments(
            comments: [OwnerAskMarginComment(id: "c", draftID: UUID(), anchor: anchor, body: "", placed: false)],
            rects: [nil], textExtent: nil, active: .constant(nil), setBody: { _, _ in }, remove: { _ in }
        )
        XCTAssertEqual(try margin.inspect().find(CommentTextEditor.self).actualView().minHeight, CommentTextEditor.formMinHeight)
        XCTAssertThrowsError(try margin.inspect().find(ViewType.TextField.self))
    }
}
