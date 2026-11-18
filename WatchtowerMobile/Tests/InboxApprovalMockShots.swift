import ChatUI
import ChatWire
import SwiftUI
import WatchtowerDesign
import WatchtowerInterface
import XCTest
@testable import WatchtowerMobile

/// The approval card's states on the phone (board #2018, mobile Inbox spec §12): the phone Inbox's and the phone
/// chat's, each drawn by the real `ChatUI.AgentActionCard` in `PhoneChatStyle` with the state its screen's model
/// builds (`InboxApprovalState.make`, `ChatApprovalCardModel.state`) and the Inbox's target row
/// (`InboxTargetRow`). Rendered under the mockups' names (`docs/design/mockups/mobile-inbox/approval-card/`) for the
/// by-eye comparison with them. Synthetic data only.
extension ScreenshotTourTests {
    func testTheInboxApprovalMockShots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"],
              ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "inbox-approval" else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=inbox-approval")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "inbox-approval-mocks-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let env = AppEnvironment(backend: .inMemoryDemo, defaults: defaults)
        let root = try AppRoot.demo(env, defaults: defaults)
        let host = ScreenshotHost(directory: dir, env: root.env, linking: root.linking)
        let frames = InboxApprovalShots.frames
        for (name, view) in frames {
            try await host.captureThree(name, view)
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: path)
            .filter { name in frames.contains { name.hasPrefix($0.0 + "-") } && name.hasSuffix(".png") }
        XCTAssertEqual(written.count, 3 * frames.count)
    }
}

@MainActor
private enum InboxApprovalShots {
    static let hub = "Acme Mac"
    static let source = "ϟ Release notes · run #4"
    static let now = Date()

    static var frames: [(String, AnyView)] {
        [
            ("inbox-approval-pending", page(
                card(jira(), label: "With the permissions grant", inbox(jiraCard(), nil)),
                card(jira(id: 42), label: "Without the grant", inbox(jiraCard(), nil, grants: noGrant))
            )),
            ("inbox-approval-failed", page(
                card(failedJira(), label: "Failed — Retry", inbox(failedCard(), nil)),
                card(failedJira(id: 42), label: "Failed, without the grant", inbox(failedCard(), nil, grants: noGrant))
            )),
            ("inbox-approval-sending", page(
                card(jira(), label: "Approve on its way", inbox(jiraCard(), .busy(request(.approve)))),
                card(failedJira(id: 42), label: "Retry on its way", inbox(failedCard(), .busy(request(.retry)))),
                card(jira(id: 43), label: "Waiting to send (the Mac is away)", inbox(jiraCard(), .busy(request(.approve)), away: true))
            )),
            ("inbox-approval-refused", page(
                card(jira(), label: "Refused with the tower's sentence", inbox(jiraCard(), .refused(
                    "This proposal changed on the Mac — look again before approving.", .resend(request(.approve), dismiss: nil)))),
                card(jira(id: 42), label: "Not delivered", inbox(jiraCard(), .refused(
                    InboxPhoneText.notDelivered(hub: hub), .outbox(actionID: "act-1", request(.approve))))),
                card(jira(id: 43), label: "Didn't confirm (the hub stopped mid-way)", inbox(jiraCard(), .unknown))
            )),
            ("inbox-approval-settled", page(
                card(jira(status: "executing"), label: "Approved — the Mac runs it", nil),
                card(jira(id: 42, status: "applied",
                          result: #"{"url":"https://example.atlassian.net/browse/ACME-12","key":"ACME-12"}"#),
                     label: "Done, or already done on the Mac (until the publish drops it)", nil),
                card(connector(id: 53, dismissed: true), label: "Dismissed (until the publish drops it)", nil)
            )),
            ("inbox-approval-dismiss", page(
                card(connector(), label: "Outcome unknown — Dismiss", inbox(connectorCard(), nil)),
                card(connector(id: 52), label: "Dismiss on its way", inbox(connectorCard(), .busy(request(.dismiss)))),
                card(connector(id: 54), label: "Outcome unknown, without the grant", inbox(connectorCard(), nil, grants: noGrant))
            )),
            ("inbox-approval-mac-only", page(
                card(draft(), label: "A recipe draft", inbox(draftCard(), nil),
                     title: "Save automation “Weekly mail roundup”",
                     summary: "“Every Monday, collect the week's unread mail into one roundup.”"),
                card(stuckTarget(), label: "An Inbox button's task that didn't finish", nil, override: InboxTargetRow.view(.stuck, canRetry: true) {})
            )),
            ("chat-approval-failed", chatPage(
                card(failedJira(), label: "Failed — Retry", chat(failedFeedAction())),
                card(failedJira(id: 42), label: "Failed, without the grant or on an older hub",
                     chat(failedFeedAction(), permissions: false))
            )),
            ("chat-approval-dismiss", chatPage(
                card(connector(), label: "Outcome unknown — Dismiss", chat(unknownFeedAction())),
                card(connector(id: 52), label: "Without the grant or on an older hub", chat(unknownFeedAction(), retryDismiss: false)),
                card(connector(id: 53, dismissed: true), label: "Dismissed (the feed's dismissed_at)",
                     chat(unknownFeedAction(dismissed: true)))
            )),
            ("chat-approval-sending", chatPage(
                card(failedJira(), label: "Retry on its way", chat(failedFeedAction(), inFlight: true)),
                card(failedJira(id: 42), label: "The hub is away (nothing queues)", chat(failedFeedAction(), online: false))
            )),
            ("chat-approval-refused", chatPage(
                card(failedJira(), label: "Refused with the hub's sentence",
                     chat(failedFeedAction(), failure: ChatActionFailure(reason: .notPending, message: "Already approved"))),
                card(failedJira(id: 42), label: "Couldn't send",
                     chat(failedFeedAction(), failure: ChatActionFailure(reason: nil, message: "")))
            )),
            ("chat-approval-header-today", header(stacked: false)),
            ("chat-approval-header-stacked", header(stacked: true)),
            ("chat-approval-unconfirmed", chatPage(
                card(failedJira(id: 43), label: "Didn't confirm (the hub stopped mid-way)",
                     chat(failedFeedAction(), failure: ChatActionFailure(reason: .outcomeUnknown, message: "")))
            ))
        ]
    }

    // MARK: - States from the screens' models

    static let noGrant = Grants(permissions: false, typing: true)

    static func inbox(_ card: InboxCard, _ row: InboxRowState?, grants: Grants = .all, away: Bool = false) -> ChatApprovalState {
        InboxApprovalState.make(card: card, rowState: row, grants: grants, hubAway: away, hubName: hub, now: now)
    }

    static func chat(
        _ action: ChatFeed.Action,
        permissions: Bool = true,
        retryDismiss: Bool = true,
        online: Bool = true,
        inFlight: Bool = false,
        failure: ChatActionFailure? = nil
    ) -> ChatApprovalState {
        ChatApprovalCardModel(payload: ChatApprovalPayload(action: action), permissions: permissions, online: online,
                              inFlight: inFlight, failure: failure, host: .mac, retryDismiss: retryDismiss).state
    }

    static func request(_ verb: ApprovalVerb) -> ActRequest {
        ActRequest(requestID: "r", target: "a41", verb: .approval, params: ActParams(approvalVerb: verb, argsSHA256: "b2"))
    }

    // MARK: - Actions and their entries

    static let jiraArgs = #"{"project_key": "ACME", "issue_type": "Task", "summary": "Pin the rollout window", "labels": ["release"]}"#
    static let connectorArgs = #"{"server": "Linear", "tool": "create_issue", "input": {"team": "ACME", "title": "Pin the rollout window"}}"#

    static func jira(id: Int64 = 41, status: String = "pending", result: String = "") -> ChatAgentAction {
        ChatAgentAction(id: id, tool: "create_jira_issue", external: true, argsJSON: jiraArgs, argsStored: false, argsSHA256: "b2",
                        argsComplete: true, reason: "From the release thread", status: status, resultJSON: result)
    }

    static func failedJira(id: Int64 = 41) -> ChatAgentAction {
        ChatAgentAction(id: id, tool: "create_jira_issue", external: true, argsJSON: jiraArgs, argsStored: false, argsSHA256: "b2",
                        argsComplete: true, reason: "From the release thread", status: "failed", error: "jira: 503 Service Unavailable")
    }

    static func connector(id: Int64 = 51, dismissed: Bool = false) -> ChatAgentAction {
        ChatAgentAction(id: id, tool: ConnectorCallProposal.tool, external: true, argsJSON: connectorArgs, argsStored: false,
                        argsSHA256: "d4", argsComplete: true, status: "failed", error: ConnectorCallProposal.sessionEndedWhileRunning,
                        dismissedAt: dismissed ? "2026-11-18T09:00:00Z" : "")
    }

    static func draft() -> ChatAgentAction {
        ChatAgentAction(id: 61, tool: "save_automation", argsJSON: #"{"name": "Weekly mail roundup"}"#, argsStored: false,
                        argsSHA256: "e5", argsComplete: true)
    }

    static func stuckTarget() -> ChatAgentAction {
        ChatAgentAction(id: 62, tool: "create_target", argsJSON: #"{"text": "Pin the rollout window", "priority": "high"}"#,
                        argsStored: false, argsSHA256: "f6", argsComplete: true, status: "executing")
    }

    static func entry(_ tool: String, status: String = "pending", error: String = "") -> InboxCard {
        var card = DemoSeed.Inbox.approvalCards(now: now)[0]
        card.approval = DemoSeed.Inbox.approval(tool, "", "", "b2", status: status, error: error, args: "{}")
        return card
    }

    static func jiraCard() -> InboxCard { entry("create_jira_issue") }
    static func failedCard() -> InboxCard { entry("create_jira_issue", status: "failed", error: "jira: 503") }
    static func connectorCard() -> InboxCard {
        entry(ConnectorCallProposal.tool, status: "failed", error: ConnectorCallProposal.sessionEndedWhileRunning)
    }
    static func draftCard() -> InboxCard { entry("save_automation") }

    static func failedFeedAction() -> ChatFeed.Action {
        ChatFeed.Action(id: 41, tool: "create_jira_issue", title: "", argsDisplay: jiraArgs, argsSHA256: "b2", status: "failed",
                        external: true, error: "jira: 503 Service Unavailable", argsComplete: true)
    }

    static func unknownFeedAction(dismissed: Bool = false) -> ChatFeed.Action {
        ChatFeed.Action(id: 51, tool: ConnectorCallProposal.tool, title: "", argsDisplay: connectorArgs, argsSHA256: "d4",
                        status: "failed", external: true, error: ConnectorCallProposal.sessionEndedWhileRunning, argsComplete: true,
                        dismissedAt: dismissed ? "2026-11-18T09:00:00Z" : "")
    }

    // MARK: - The page and the card

    static func page(_ cards: AnyView...) -> AnyView { page(header: "Needs approval", cards) }

    /// The phone chat's frames (§12.9): the same card under the chat's title.
    static func chatPage(_ cards: AnyView...) -> AnyView { page(header: "Chat · Release plan", cards) }

    static func page(header: String, _ cards: [AnyView]) -> AnyView {
        AnyView(ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text(header).font(TypeScale.rowEmphasis)
                ForEach(Array(cards.enumerated()), id: \.offset) { $0.element }
            }
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(uiColor: .systemBackground))
        .environment(\.chatUIStyle, PhoneChatStyle())
        .environment(\.chatHostText, .phone(hub)))
    }

    /// The header change (§12.5), as a pair of shots in the chat: the header the phone drew before (the shared
    /// default) and the phone's stacked one. Only the narrow shot (the largest text size) tells them apart.
    static func header(stacked: Bool) -> AnyView {
        let dismiss: (ChatAgentAction) -> Void = { _ in }
        let card = AgentActionCard(action: connector(), services: ChatApprovalServices(dismiss: dismiss))
        return AnyView(ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text("Chat · Release plan").font(TypeScale.rowEmphasis)
                if stacked {
                    card.environment(\.chatUIStyle, PhoneChatStyle())
                } else {
                    card.environment(\.chatUIStyle, PreviousHeaderStyle())
                }
            }
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(uiColor: .systemBackground))
        .environment(\.chatHostText, .phone(hub)))
    }

    static func card(
        _ action: ChatAgentAction,
        label: String,
        _ state: ChatApprovalState?,
        title: String? = nil,
        summary: String? = nil,
        override: AnyView? = nil
    ) -> AnyView {
        let noop: (ChatAgentAction) -> Void = { _ in }
        let services = ChatApprovalServices(
            state: { _ in state },
            retry: noop,
            dismiss: noop,
            title: { _ in title },
            details: { _ in summary.map { AnyView(Text($0).font(.callout).fixedSize(horizontal: false, vertical: true)) } },
            decisionOverride: { _ in override },
            resend: noop
        )
        return AnyView(VStack(alignment: .leading, spacing: Spacing.small) {
            Text(label).font(TypeScale.meta).foregroundStyle(.secondary)
            AgentActionCard(action: action, services: services, contextLabel: source)
        })
    }
}

/// The phone's chat style with the header it drew before §12.5 (the shared default, the title cut beside its
/// status): the "today" half of the header pair. Everything else is `PhoneChatStyle`.
private struct PreviousHeaderStyle: ChatUIStyle {
    private let phone = PhoneChatStyle()

    func primaryButton(_ title: String, action: @escaping () -> Void) -> AnyView { phone.primaryButton(title, action: action) }
    func secondaryButton(_ title: String, action: @escaping () -> Void) -> AnyView { phone.secondaryButton(title, action: action) }
    func card<C: View>(@ViewBuilder _ content: () -> C) -> AnyView { phone.card(content) }
    func chip(_ title: String) -> AnyView { phone.chip(title) }
    func attachmentChip(_ chip: ChatAttachmentChipContent) -> AnyView { phone.attachmentChip(chip) }
    func approvalRetryNote(_ text: String) -> AnyView { phone.approvalRetryNote(text) }
}
