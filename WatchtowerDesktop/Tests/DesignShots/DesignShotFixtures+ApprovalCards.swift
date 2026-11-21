import AppKit
@testable import ChatUI
import ChatWire
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Mac's approval card in every state it draws (unified chat T15): the same names before and after the card
/// moved to ChatUI, so a by-eye comparison of `make desktop-shots` shows the move changed nothing on the Mac.
/// Synthetic data only.
@MainActor
enum ApprovalCardShotFixtures {
    /// The card every shot draws: the Mac's card on its own row.
    private typealias Card = MacAgentActionCard

    private static var chats: [ChatViewModel] = []
    private static var poolPaths: [String] = []

    static func cleanUp() {
        chats = []
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
    }

    /// The shot names a T15 comparison covers: these and the older approval shots (`DesignShotsTests`).
    static let comparedNames: Set<String> = [
        "approval-card-target-stuck", "automation-save-card", "automation-editor-review", "inbox-decision-card",
        "inbox-chat-decision-card"
    ]

    static var shots: [DesignShot] {
        let cards: [(String, () -> AnyView)] = [
            ("approval-plain-pending", { card(row(tool: "create_target", args: targetArgs)) }),
            ("approval-jira-pending", { card(row(tool: "create_jira_issue", external: true, args: jiraArgs)) }),
            ("approval-linear-pending", { card(row(tool: "create_linear_issue", external: true, args: linearArgs)) }),
            ("approval-slack-pending-edit", {
                card(row(tool: "send_slack_message", external: true, args: slackArgs), editable: true)
            }),
            ("approval-slack-workspace-pick", {
                card(row(tool: "send_slack_message", external: true, args: slackCandidates), editable: true)
            }),
            ("approval-slack-reconnect", {
                card(row(tool: "send_slack_message", external: true, args: slackArgs, status: "failed", error: scopeError),
                     reconnect: true)
            }),
            ("approval-confluence-diff", { card(row(tool: "edit_confluence_page", external: true, args: confluenceArgs)) }),
            ("approval-confluence-applied", {
                card(row(tool: "edit_confluence_page", external: true, args: confluenceArgs, status: "applied",
                         result: #"{"version":8,"url":"https://example.atlassian.net/wiki/x/98765"}"#))
            }),
            ("approval-connector-pending", {
                card(row(tool: ConnectorCallProposal.tool, external: true, args: connectorArgs), editable: true, holds: true)
            }),
            ("approval-connector-editing", { connectorEditing() }),
            ("approval-connector-session-ended", {
                card(row(tool: ConnectorCallProposal.tool, external: true, args: connectorArgs), editable: true)
            }),
            ("approval-connector-dismiss", {
                card(row(tool: ConnectorCallProposal.tool, external: true, args: connectorArgs, status: "failed",
                         error: ConnectorCallProposal.sessionEndedWhileRunning), dismiss: true)
            }),
            ("approval-executing", { card(row(tool: "create_jira_issue", external: true, args: jiraArgs, status: "executing")) }),
            ("approval-in-flight", { card(row(tool: "create_target", args: targetArgs), inFlight: true) }),
            ("approval-applied-link-warning", {
                card(row(tool: "create_jira_issue", external: true, args: jiraArgs, status: "applied",
                         result: #"{"url":"https://example.atlassian.net/browse/ACME-12","key":"ACME-12","#
                             + #""warning":"The issue was created, but its local mirror did not refresh."}"#),
                     open: true)
            }),
            ("approval-failed-retry-note", {
                card(row(tool: "create_jira_issue", external: true, args: jiraArgs, status: "failed",
                         error: "jira: 503 Service Unavailable"))
            }),
            ("approval-gesture-error", {
                card(row(tool: "create_target", args: targetArgs),
                     gestureError: .init(verb: "approve", message: "database is locked (5) (SQLITE_BUSY)"))
            }),
            ("approval-rejected", { card(row(tool: "create_target", args: targetArgs, status: "rejected")) }),
            ("approval-context-label", {
                card(row(tool: "create_target", args: targetArgs), context: "⚙ Release review · run #12")
            }),
            ("approval-save-automation", { AutomationShotFixtures.saveCard() })
        ]
        return cards.map { name, make in
            DesignShot(name: name, size: NSSize(width: 560, height: 0)) {
                AnyView(make().padding(Spacing.large).frame(maxWidth: .infinity, alignment: .topLeading).detailBackground())
            }
        } + [
            DesignShot(name: "approval-chat-awaited-outline", size: NSSize(width: 640, height: 420)) { awaitedOutline() },
            DesignShot(name: "approval-chat-approve-all", size: NSSize(width: 640, height: 520)) { approveAll() },
            DesignShot(name: "approval-chat-interrupted-turn", size: NSSize(width: 640, height: 360)) { interruptedTurn() }
        ]
    }

    /// The failed send's card while its **Reconnect Slack** sign-in waits (#2132 S2): the line the screen hands every
    /// card (`AppState.cardSlackSignInWait`), for `sign-in-wait-built-chat-card`.
    static func slackReconnectWaiting() -> AnyView {
        AnyView(Card(
            action: row(tool: "send_slack_message", external: true, args: slackArgs, status: "failed", error: scopeError),
            inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
            onReconnectSlack: { _ in .cancelled },
            reconnectSlackWait: { _ in Card.SlackSignInWait(copy: .slack) {} }
        ))
    }

    // MARK: - Cards

    private static func card(
        _ action: AgentAction,
        editable: Bool = false,
        holds: Bool = false,
        inFlight: Bool = false,
        gestureError: AgentActionFeed.RowError? = nil,
        reconnect: Bool = false,
        dismiss: Bool = false,
        open: Bool = false,
        context: String? = nil
    ) -> AnyView {
        AnyView(Card(
            action: action, inFlight: inFlight, onApprove: {}, onReject: {}, onRetry: {}, gestureError: gestureError,
            onOpen: open ? { _ in } : nil, onApproveEdited: editable ? { _ in } : nil,
            onReconnectSlack: reconnect ? { _ in .signedIn } : nil, contextLabel: context, onOpenContext: context.map { _ in {} },
            onDismiss: dismiss ? {} : nil, sessionHoldsCall: holds
        ))
    }

    /// The connector input while the owner edits it: the details the card shows with Edit Input pressed.
    private static func connectorEditing() -> AnyView {
        let action = row(tool: ConnectorCallProposal.tool, external: true, args: connectorArgs)
        guard let proposal = ConnectorCallProposal(action: action) else { return AnyView(Text("unreadable")) }
        let edited = proposal.inputJSON.replacingOccurrences(of: "ACME", with: "ACME-OPS")
        return AnyView(VStack(alignment: .leading, spacing: Spacing.regular) {
            card(action, editable: true, holds: true)
            ConnectorCallDetails(proposal: proposal, draft: .constant(edited),
                                 approval: proposal.approval(editedInput: edited))
        })
    }

    private static func row(
        tool: String,
        external: Bool = false,
        args: String,
        status: String = "pending",
        result: String = "",
        error: String = "",
        turn: String = "t1",
        id: Int64 = 41
    ) -> AgentAction {
        AgentAction(row: Row([
            "id": id, "tool": tool, "external": external, "args_json": args, "status": status, "surface": "main",
            "conversation_id": 7, "turn_id": turn, "reason": "From the release thread", "result_json": result,
            "error": error, "created_at": "2026-11-03T09:00:00Z"
        ]))
    }

    // MARK: - The chat (awaited outline, Approve all, an interrupted turn)

    /// A turn that waits on its card: the card is outlined.
    private static func awaitedOutline() -> AnyView {
        chat(actions: [(tool: "create_target", args: targetArgs, turn: "t1")], messageTurns: ["t1"], runningTurn: "t1")
    }

    /// Two cards of one reply: Approve all under it.
    private static func approveAll() -> AnyView {
        chat(actions: [(tool: "create_target", args: targetArgs, turn: "t1"),
                       (tool: "create_jira_issue", args: jiraArgs, turn: "t1")], messageTurns: ["t1"], runningTurn: nil)
    }

    /// A turn that stored no message: its card sits in the feed's footer.
    private static func interruptedTurn() -> AnyView {
        chat(actions: [(tool: "create_target", args: targetArgs, turn: "t9")], messageTurns: [], runningTurn: nil)
    }

    private static func chat(
        actions: [(tool: String, args: String, turn: String)], messageTurns: [String], runningTurn: String?
    ) -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            poolPaths.append(path)
            var ids: [Int64] = []
            try pool.write { db in
                for action in actions {
                    ids.append(try TestDatabase.insertAgentAction(
                        db, tool: action.tool, external: action.tool != "create_target", argsJSON: action.args,
                        reason: "From the release thread", conversationID: 7, turnID: action.turn
                    ))
                }
                for turn in messageTurns {
                    try db.execute(sql: """
                        INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (7, 'Release', 0, 0)
                        ON CONFLICT DO NOTHING
                        """)
                    try db.execute(sql: """
                        INSERT INTO chat_messages (conversation_id, role, text, turn_id, created_at)
                        VALUES (7, 'assistant', 'x', ?, 0)
                        """, arguments: [turn])
                }
            }
            let vm = ChatViewModel(client: ApprovalShotChatClient(), dbPool: pool)
            chats.append(vm)
            let parts: [ChatPart] = messageTurns.isEmpty ? [] : zip(actions, ids).map { action, id in
                ChatPart(kind: ChatPartKind.approval, payload: .object([
                    "id": .integer(id), "tool": .string(action.tool), "status": .string("pending"),
                    "args_display": .string(action.args), "turn_id": .string(action.turn)
                ]), fallback: ChatPartFallback(text: "An action waits for your approval"))
            }
            let reply = ChatFeed.Message(
                id: 2, role: "assistant", text: "I drafted the follow-ups from the release thread.",
                status: runningTurn == nil ? "complete" : "pending", createdAt: Date(timeIntervalSince1970: 1_794_000_000),
                parts: parts.isEmpty ? nil : [ChatPart(kind: ChatPartKind.text, payload: .object([
                    "text": .string("I drafted the follow-ups from the release thread.")
                ]), fallback: ChatPartFallback(text: ""))] + parts
            )
            let question = ChatFeed.Message(id: 1, role: "user", text: "Plan the release follow-ups",
                                            createdAt: Date(timeIntervalSince1970: 1_794_000_000))
            let feed = ChatFeed(
                conversation: ChatFeed.Conversation(
                    id: 7, title: "Release", lease: runningTurn.map { ChatFeed.Lease(owner: "hub", turnID: $0) }
                ),
                messages: [question, reply]
            )
            vm.select(conversationID: 7)
            vm.conversation.stop()
            vm.conversation.store.apply(.snapshot(feed))
            vm.actionFeed.refresh()
            // The message turns load on a task: let it land before the shot draws.
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return AnyView(ChatThreadView(chatVM: vm, ownerName: "Alex")
                .environment(AppState())
                .macChatStyle(hooks: ChatMacArtifactHooks())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    // MARK: - Samples

    private static let targetArgs = #"{"text":"Sign off the release checklist","due":"2026-11-07","priority":"high"}"#
    private static let jiraArgs = #"{"project_key":"ACME","issue_type":"Task","summary":"Pin the rollout window","#
        + #""description":"Agree the window with the on-call team.","labels":["release"]}"#
    private static let linearArgs = #"{"team":"ACME","title":"Pin the rollout window","state":"Todo","priority":"High"}"#
    private static let slackArgs = ##"{"text":"The 4.2 release is out — notes in the thread.","##
        + ##""target":{"account_id":3,"workspace":"Acme","channel_id":"C1","label":"#releases"}}"##
    private static let slackCandidates = ##"{"text":"The 4.2 release is out.","candidates":["##
        + ##"{"account_id":1,"workspace":"Acme","channel_id":"C1","label":"#releases"},"##
        + ##"{"account_id":2,"workspace":"Acme Labs","channel_id":"C2","label":"#releases"}]}"##
    private static let scopeError = "slack workspace Acme has not granted Watchtower permission to send messages — "
        + "sign in again to grant send"
    private static let connectorArgs = #"{"server":"Linear","tool":"create_issue","#
        + #""input":{"team":"ACME","title":"Pin the rollout window"}}"#
    private static let confluenceArgs = #"""
    {"account_id":1,"base_version":7,
     "changes":[{"kind":"replace_text","locator":"text in Plan",
                 "before":"Owner ⟦1:@Colleague A⟧ ships on Friday.","after":"Ships on Monday.",
                 "removed":["⟦1:@Colleague A⟧"]}],
     "edits":[],"kind":"page","new_storage":"<p>Ships on Monday.</p>",
     "page_id":"98765","title":"Rollout plan",
     "url":"https://example.atlassian.net/wiki/spaces/ENG/pages/98765/Rollout"}
    """#
}

/// A client that never answers: the chat shots set the conversation's state themselves.
private final class ApprovalShotChatClient: ChatClient, @unchecked Sendable {
    func send(_ op: ChatOperation) async throws -> ChatEcho { .applied(.none) }
    func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> { AsyncStream { _ in } }
    func list() -> AsyncStream<ChatListUpdate> { AsyncStream { _ in } }
    var reachability: AsyncStream<ChatReachability> { AsyncStream { _ in } }
}
