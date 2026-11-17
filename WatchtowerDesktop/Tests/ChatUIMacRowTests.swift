import ChatUI
import ChatWire
import DesignKit
import SwiftUI
import ViewInspector
import WatchtowerChatText
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport
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

    // MARK: - The Mac looks (review I1: each surface keeps its look)

    func testEachMacSurfaceKeepsItsLook() throws {
        let embedded = DesignKitChatStyle(look: .embedded)
        XCTAssertTrue(embedded.actionsOnHover, "Copy and the caption show on hover and on the last row")
        XCTAssertEqual(embedded.rowSpacing, Spacing.small)
        XCTAssertEqual(try embedded.copyButton {}.inspect().find(ViewType.Button.self).accessibilityLabel().string(),
                       "Copy message")
        XCTAssertNoThrow(try embedded.ownerBubble(AnyView(Text("hi"))).inspect().find(ViewType.Spacer.self))
        let standard = DesignKitChatStyle()
        XCTAssertFalse(standard.actionsOnHover, "the main chat is unchanged")
        XCTAssertEqual(standard.rowSpacing, Spacing.regular)
        XCTAssertNoThrow(try standard.copyButton {}.inspect().find(button: "Copy"))
        XCTAssertEqual(DesignKitChatStyle(look: .workchat).rowSpacing, Spacing.tight)
    }

    /// Steps that carry their times (an embedded chat's) say how long the turn worked, as before.
    func testStepTimesGiveTheWorkedForHeader() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let steps = [ChatFeed.Step(name: "a", outcome: .succeeded, startedAt: start, endedAt: start.addingTimeInterval(12)),
                     ChatFeed.Step(name: "b", outcome: .succeeded, startedAt: start.addingTimeInterval(2),
                                   endedAt: start.addingTimeInterval(5))]
        XCTAssertNoThrow(try row(reply("Done", steps: steps)).inspect().find(text: "Worked for 12s · 2 steps"))
        XCTAssertNoThrow(try row(reply("Done", steps: [ChatFeed.Step(name: "a", outcome: .succeeded)]))
            .inspect().find(text: "Worked · 1 step"), "the engine's wire has no times")
    }

    /// An embedded chat's step lines are the app's (review I1): the catalog's icon and label from the arguments, the
    /// arguments behind a disclosure, and a waiting call's note; ChatUI's own line (main chat, phone) keeps the raw name.
    func testEmbeddedStepLinesNameTheCallFromItsArguments() throws {
        let args = #"{"name":"digest.channel"}"#
        let steps = [
            ChatFeed.Step(name: "get_prompt", outcome: .running, summary: "Waiting for your approval", argsJSON: args,
                          isWaiting: true)
        ]
        let message = ChatFeed.Message(id: 4, role: "assistant", text: "", status: "pending", createdAt: .distantPast,
                                       steps: steps)
        let label = ChatToolCatalog.label(name: "get_prompt", args: args)
        let embedded = row(message).environment(\.chatUIStyle, DesignKitChatStyle(look: .embedded))
        XCTAssertNoThrow(try embedded.inspect().find(text: label))
        XCTAssertNoThrow(try embedded.inspect().find(EmbeddedStepRow.self))
        XCTAssertNoThrow(try embedded.inspect().find(text: "Waiting for your approval — see the approval card below."))
        XCTAssertNoThrow(try embedded.inspect().find(text: args), "the arguments behind the disclosure")
        XCTAssertThrowsError(try row(message).inspect().find(EmbeddedStepRow.self), "the default style keeps ChatUI's line")
    }

    /// The Mac keeps its own line for a cut reply (#1783 is the phone's rule: ChatUI names no machine itself).
    func testACutReplySaysTheMacOnTheMac() throws {
        let cut = ChatFeed.Message(id: 4, role: "assistant", text: "body", textCut: true, status: "complete",
                                   createdAt: .distantPast)
        let mac = row(cut).environment(\.chatHostText, .mac)
        XCTAssertNoThrow(try mac.inspect().find(text: "This message is cut here; the whole text is on your Mac."))
        XCTAssertNoThrow(try row(cut).inspect().find(text: ChatHostText.plain.messageCut), "ChatUI's own line names no Mac")
        XCTAssertFalse(ChatHostText.plain.messageCut.contains("Mac"))
        XCTAssertEqual(ChatHostText.mac.artifactCut, "This artifact is cut here; the whole text is on your Mac.")
        XCTAssertEqual(ChatHostText.mac.chooseSlackWorkspace, "Choose a workspace in Inbox › Needs approval before approving")
    }

    /// The Chats panel's row says what it said before the unified chat (final re-review I5): the waiting tool by its
    /// card title, the age from the last answer (not a later rename), the title bold while an answer is unread.
    func testSidebarRowNamesTheToolAndAgesFromTheLastAnswer() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let waiting = ChatList.Conversation(id: 1, title: "Send it", updatedAt: now.addingTimeInterval(-60), state: .waiting,
                                            lastAnswerAt: now.addingTimeInterval(-120), pendingTool: "send_slack_message",
                                            unread: true)
        let title = try XCTUnwrap(ReactionToolCatalog.info(for: "send_slack_message")?.title)
        let row = ChatSidebarRow(content: ChatSidebarRow.content(waiting, now: now, showsProject: true))
        XCTAssertNoThrow(try row.inspect().find(text: "Waiting for approval: \(title)"))
        let renamed = ChatList.Conversation(id: 2, title: "Plan", updatedAt: now.addingTimeInterval(-60), state: .read,
                                            lastLine: "Done.", lastAnswerAt: now.addingTimeInterval(-3 * 86_400))
        let content = ChatSidebarRow.content(renamed, now: now, showsProject: true)
        XCTAssertEqual(content.age, "3d", "the age counts from the last answer")
        XCTAssertTrue(ChatSidebarRow.content(waiting, now: now, showsProject: true).unread)
        XCTAssertFalse(content.unread)
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

    // MARK: - The approval card (unified chat T15)

    private func approvalChat(actions: Int, runner: FakeCLIRunner) throws -> (ChatViewModel, String) {
        let (pool, path) = try TestDatabase.createPool()
        try pool.write { db in
            for _ in 0..<actions {
                _ = try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true,
                                                       argsJSON: #"{"project_key":"ACME","summary":"x"}"#,
                                                       conversationID: 7, turnID: "t1")
            }
        }
        let vm = ChatViewModel(client: RecordingChatClient(), dbPool: pool, cliRunner: runner)
        vm.select(conversationID: 7)
        vm.actionFeed.start(conversationID: 7)
        vm.actionFeed.refresh()
        return (vm, path)
    }

    private func approvalReply(_ ids: [Int64]) -> ChatFeed.Message {
        let parts = ids.map { id in
            ChatPart(kind: ChatPartKind.approval, payload: .object([
                "id": .integer(id), "tool": .string("create_jira_issue"), "status": .string("pending"),
                "args_display": .string("{}"), "args_sha256": .string("p1n"), "turn_id": .string("t1")
            ]), fallback: ChatPartFallback(text: "An action waits for your approval"))
        }
        return ChatFeed.Message(id: 4, role: "assistant", text: "", createdAt: .distantPast, parts: parts)
    }

    private func approvalFeed(_ message: ChatFeed.Message, services: ChatApprovalServices) -> some View {
        ChatUI.ChatFeedRows(messages: [message], context: ChatFeedContext(partActions: ChatPartActions(approvals: services)))
            .macChatStyle(hooks: ChatMacArtifactHooks())
    }

    /// The Mac approves through `watchtower actions` (D12), never `chat.sock`: with the chat's socket unreachable, a
    /// pending card's Approve is live and runs the CLI with the shown args' digest.
    func testMacApprovalLiveWhileChatUnreachable() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
        let (vm, path) = try approvalChat(actions: 1, runner: runner)
        defer { TestDatabase.cleanup(path: path) }
        vm.conversation.reachability = .unavailable
        let action = try XCTUnwrap(vm.actionFeed.rows.first)
        let services = ChatThreadView(chatVM: vm, ownerName: "Alex").approvals
        let card = ChatUI.AgentActionCard(action: action, services: services)
            .environment(\.chatUIStyle, DesignKitChatStyle())
        let approve = try card.inspect().find(button: "Approve")
        XCTAssertFalse(approve.isDisabled())
        try approve.tap()
        for _ in 0..<1000 where runner.invocations.isEmpty { await Task.yield() }
        XCTAssertEqual(runner.invocations.first,
                       ["actions", "approve", String(action.id), "--args-sha256", ChatAgentAction.digest(of: action.argsJSON),
                        "--json"])
    }

    /// An approval part whose row the Mac has not loaded (or no longer has) is drawn from the payload, with the
    /// decision row from the services: the card never disappears.
    func testApprovalPartWithoutMacRowDrawsFromPayload() throws {
        let runner = FakeCLIRunner()
        let (vm, path) = try approvalChat(actions: 0, runner: runner)
        defer { TestDatabase.cleanup(path: path) }
        let services = ChatThreadView(chatVM: vm, ownerName: "Alex").approvals
        let feed = approvalFeed(approvalReply([99]), services: services)
        XCTAssertNoThrow(try feed.inspect().find(text: "Create a Jira issue"))
        XCTAssertNoThrow(try feed.inspect().find(text: "Awaiting your approval"))
        XCTAssertNoThrow(try feed.inspect().find(button: "Approve"))
        XCTAssertNoThrow(try feed.inspect().find(button: "Reject"))
    }

    /// **Approve all** shows under a reply with two or more bulk-approvable cards, and approves the turn's rows.
    func testApproveAllShowsForTwoBulkApprovable() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
        let (vm, path) = try approvalChat(actions: 2, runner: runner)
        defer { TestDatabase.cleanup(path: path) }
        let services = ChatThreadView(chatVM: vm, ownerName: "Alex").approvals
        let ids = vm.actionFeed.rows.map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertThrowsError(try approvalFeed(approvalReply([ids[0]]), services: services).inspect().find(button: "Approve all"))
        try approvalFeed(approvalReply(ids), services: services).inspect().find(button: "Approve all").tap()
        for _ in 0..<1000 where runner.invocations.count < 2 { await Task.yield() }
        XCTAssertEqual(runner.invocations.map { $0.prefix(3) }, ids.map { ["actions", "approve", String($0)] })
    }

    /// Approve hands the screen the exact action the card was drawn from — its args and its digest (AGENT-07): a card
    /// drawn from the part's payload sends the payload's digest, a card on a resolved row sends that row.
    func testApproveCarriesTheShownSnapshot() throws {
        var answers: [(ChatAgentAction, ChatApprovalAnswer)] = []
        let payload = ChatApprovalPayload(id: 7, tool: "create_target", title: "", argsDisplay: #"{"text":"Call"}"#,
                                          argsSHA256: "d1g", status: "pending", turnID: "t1", argsComplete: true)
        var services = ChatApprovalServices()
        services.decide = { answers.append(($0, $1)) }
        let reply = ChatFeed.Message(id: 4, role: "assistant", text: "", createdAt: .distantPast, parts: [
            ChatPart(kind: ChatPartKind.approval, payload: .object([
                "id": .integer(7), "tool": .string("create_target"), "status": .string("pending"),
                "args_display": .string(#"{"text":"Call"}"#), "args_sha256": .string("d1g"), "turn_id": .string("t1"),
                "args_complete": .bool(true)
            ]), fallback: ChatPartFallback(text: "An action waits for your approval"))
        ])
        try approvalFeed(reply, services: services).inspect().find(button: "Approve").tap()
        XCTAssertEqual(answers.map(\.0), [ChatAgentAction(payload: payload)])
        XCTAssertEqual(answers.first?.0.argsSHA256, "d1g")
        XCTAssertEqual(answers.first?.0.approveDigest, "d1g")
        XCTAssertEqual(answers.first?.1, .approve(patch: nil))

        // The screen's own row wins over the payload: the card shows it, and Approve carries it.
        let row = ChatAgentAction(id: 7, tool: "create_target", argsJSON: #"{"text":"Call Vasya"}"#, turnID: "t1")
        services.resolve = { _ in row }
        answers = []
        try approvalFeed(reply, services: services).inspect().find(button: "Approve").tap()
        XCTAssertEqual(answers.map(\.0), [row])
        XCTAssertEqual(answers.first?.0.approveDigest, ChatAgentAction.digest(of: #"{"text":"Call Vasya"}"#))
    }
}
