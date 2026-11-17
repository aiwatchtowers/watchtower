import ChatUI
import ChatWire
import SwiftUI
import ViewInspector
import WatchtowerChatText
@testable import WatchtowerDesktop
import WatchtowerCore
import XCTest

/// ChatUI's row and parts as the Mac's embedded chats and Workchat draw them (unified chat T12): the error card, the
/// row's actions, the artifact card, the steps and sources, the published-link card. The behaviours the app's own row
/// had, held on the shared views.
@MainActor
final class ChatUIMacRowTests: XCTestCase {
    private func reply(
        _ text: String = "body",
        status: String = "complete",
        errorCode: String? = nil,
        errorMessage: String? = nil,
        steps: [ChatFeed.Step] = []
    ) -> ChatFeed.Message {
        ChatFeed.Message(id: 4, role: "assistant", text: text, status: status, errorCode: errorCode,
                         errorMessage: errorMessage, createdAt: .distantPast, steps: steps)
    }

    private func row(
        _ message: ChatFeed.Message,
        rowActions: ChatRowActions = ChatRowActions(),
        partActions: ChatPartActions = ChatPartActions(),
        provider: String? = nil
    ) -> ChatUI.ChatMessageRow {
        ChatUI.ChatMessageRow(message: message, parts: ChatMessageParts.parts(for: message),
                              context: ChatPartContext(message: message, provider: provider, actions: partActions),
                              rowActions: rowActions, isTurnRunning: false)
    }

    /// An embedded chat's row: Copy only, no Edit, Regenerate or Continue.
    private var embeddedRowActions: ChatRowActions {
        var actions = ChatRowActions()
        actions.allowsEdit = false
        actions.allowsRegenerate = false
        return actions
    }

    // MARK: - The error card

    func testRetryableErrorShowsRetry() throws {
        var retried: Int64?
        var actions = ChatPartActions()
        actions.retry = { retried = $0 }
        let view = row(reply(status: "error", errorCode: "rate_limit"), partActions: actions)
        try view.inspect().find(button: "Retry").tap()
        XCTAssertEqual(retried, 4)
    }

    func testAuthErrorHasNoRetry() throws {
        let view = row(reply(status: "error", errorCode: "auth"))
        XCTAssertThrowsError(try view.inspect().find(button: "Retry"))
        XCTAssertNoThrow(try view.inspect().find(text: ChatErrorText.message(for: "auth", provider: nil)))
    }

    /// A chat folder that isn't private: the card names the folder (the session's message) and offers no Retry,
    /// which would meet it again.
    func testUnsafeWorkDirNamesTheFolderAndHasNoRetry() throws {
        let reason = "Watchtower's chat folder /tmp/watchtower-chat-cwd isn't private (it is a symlink, not a folder); "
            + "delete it and try again."
        let view = row(reply(status: "error", errorCode: "workdir_unsafe", errorMessage: reason))
        XCTAssertThrowsError(try view.inspect().find(button: "Retry"))
        XCTAssertNoThrow(try view.inspect().find(text: reason))
    }

    /// The card keeps the session's own reason under the generic phrase.
    func testErrorCardShowsTheSessionMessage() throws {
        let reason = "no Ollama model is configured: pick one in Settings → AI"
        let view = row(reply(status: "error", errorCode: "provider_unavailable", errorMessage: reason), provider: "ollama")
        XCTAssertNoThrow(try view.inspect().find(text: reason))
    }

    func testCodexAuthErrorNeverSaysClaudeLogin() throws {
        let view = row(reply(status: "error", errorCode: "auth"), provider: "codex")
        XCTAssertNoThrow(try view.inspect().find(text: ChatErrorText.message(for: "auth", provider: "codex")))
        XCTAssertThrowsError(try view.inspect().find(text: ChatErrorText.message(for: "auth", provider: nil)))
    }

    /// An embedded chat retries only the reply it says may be retried (its last failed one, while nothing runs).
    func testEmbeddedErrorRowShowsRetryOnlyWhereTheChatOffersIt() throws {
        var actions = ChatPartActions()
        actions.canRetry = { $0 == 4 }
        XCTAssertNoThrow(try row(reply(status: "error", errorCode: "rate_limit"), partActions: actions)
            .inspect().find(button: "Retry"))
        actions.canRetry = { _ in false }
        XCTAssertThrowsError(try row(reply(status: "error", errorCode: "rate_limit"), partActions: actions)
            .inspect().find(button: "Retry"))
    }

    /// A cut reply offers Continue in the main chat only: an embedded chat cannot continue one.
    func testEmbeddedStoppedRowHasNoContinue() throws {
        let cut = reply(status: "partial", errorCode: "max_turns")
        XCTAssertNoThrow(try row(cut).inspect().find(button: "Continue"))
        var embedded = ChatPartActions()
        embedded.offersContinue = false
        XCTAssertThrowsError(try row(cut, partActions: embedded).inspect().find(button: "Continue"))
    }

    // MARK: - The row's actions

    func testEmbeddedRowOffersCopyOnly() throws {
        let answer = row(reply(), rowActions: embeddedRowActions)
        XCTAssertNoThrow(try answer.inspect().find(button: "Copy"))
        XCTAssertThrowsError(try answer.inspect().find(button: "Regenerate"))
        let owner = row(ChatFeed.Message(id: 3, role: "user", text: "hi", createdAt: .distantPast), rowActions: embeddedRowActions)
        XCTAssertThrowsError(try owner.inspect().find(button: "Edit"))
    }

    func testCopyTakesAQuestionCardAsTextNotJSON() throws {
        let text = """
        Which one?
        ```watchtower-question
        {"questions": [{"question": "Pick a release", "options": [{"label": "v1"}, {"label": "v2"}]}]}
        ```
        """
        var copied: String?
        var actions = ChatRowActions()
        actions.copy = { copied = $0 }
        try row(reply(text), rowActions: actions).inspect().find(button: "Copy").tap()
        XCTAssertEqual(copied, "Which one?\n\nPick a release\n- v1\n- v2")
    }

    func testTheCaptionShowsUnderTheRow() throws {
        let message = reply()
        let view = ChatUI.ChatMessageRow(message: message, parts: ChatMessageParts.parts(for: message),
                                         context: ChatPartContext(message: message), rowActions: ChatRowActions(),
                                         isTurnRunning: false, caption: "opus · 10:42")
        XCTAssertNoThrow(try view.inspect().find(text: "opus · 10:42"))
    }

    // MARK: - Artifacts, steps, sources, published pages

    func testArtifactCardShowsWritingThenOpens() throws {
        let writing = reply(":::artifact key=\"q3\" kind=\"document\" title=\"Q3 plan\"\nx", status: "pending")
        XCTAssertNoThrow(try row(writing).inspect().find(text: "Writing Q3 plan…"))
        var opened: [String] = []
        let done = reply("Intro\n:::artifact key=\"q3\" kind=\"table\" title=\"Numbers\"\na,b\n:::\nOutro")
        var actions = ChatPartActions()
        actions.openArtifact = { opened.append($0.key) }
        let view = row(done, partActions: actions)
        XCTAssertNoThrow(try view.inspect().find(text: "Numbers"))
        try view.inspect().find(ViewType.Button.self) { (try? $0.find(text: "Numbers")) != nil }.tap()
        XCTAssertEqual(opened, ["q3"])
    }

    private let sources = (1...3).map {
        ChatFeed.Source(kind: "slack", title: "#payments — m\($0)", url: "https://example.com/p\($0)", ref: "s\($0)",
                        group: "#payments")
    }

    /// The sources pill shows once the turn is finished, and only in a chat with a sources list to open.
    func testSourcesPillOnlyWhereTheChatCanOpenThem() throws {
        let steps = [ChatFeed.Step(name: "search_knowledge", outcome: .succeeded, summary: "s", sources: sources)]
        XCTAssertNoThrow(try row(reply("Answer", steps: steps)).inspect().find(text: "3 sources"))
        var embedded = ChatPartActions()
        embedded.showsSources = false
        XCTAssertThrowsError(try row(reply("Answer", steps: steps), partActions: embedded).inspect().find(text: "3 sources"))
    }

    /// CHAT-05 (#737): a published page's card appears only for a claude.ai page, from the reply's steps.
    func testPublishedLinkCardOnlyForAClaudeAIPage() throws {
        func steps(_ url: String) -> [ChatFeed.Step] {
            [ChatFeed.Step(name: "Artifact", outcome: .succeeded, summary: "Published",
                           sources: [ChatFeed.Source(kind: PublishedLink.sourceKind, title: "Plan", url: url)])]
        }
        var opened: [URL] = []
        var actions = ChatPartActions()
        actions.openURL = { opened.append($0) }
        let page = row(reply("Done", steps: steps("https://claude.ai/public/artifacts/abc")), partActions: actions)
        try page.inspect().find(button: "Open in Browser").tap()
        XCTAssertEqual(opened.map(\.absoluteString), ["https://claude.ai/public/artifacts/abc"])
        for other in ["https://example.com/x", "http://claude.ai/artifact/abc", "file:///tmp/x.html"] {
            XCTAssertThrowsError(try row(reply("Done", steps: steps(other))).inspect().find(button: "Open in Browser"), other)
        }
    }
}
