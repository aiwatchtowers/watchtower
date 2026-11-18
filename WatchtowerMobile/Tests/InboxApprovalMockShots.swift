import ChatUI
import ChatWire
import SwiftUI
import WatchtowerDesign
import XCTest
@testable import WatchtowerMobile

/// The phone Inbox's approval card drawn by `ChatUI`'s shared card, with Retry and Dismiss (board #2018, mobile Inbox
/// spec addendum §12): every state as a mockup, before the build. The states the card already draws come from the real
/// `AgentActionCard` with the services the Inbox will wire; the rows it does not draw yet (Approve's note with a live
/// Reject, the settled row without the grant, Not delivered, the Mac-only rows) are drawn by `MockRow` through the
/// card's `decisionOverride`, in the card's own button style. Phase B replaces `MockRow` with the card's model and
/// renders these names again for the by-eye comparison. Synthetic data only.
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
        for (name, view) in InboxApprovalMocks.frames {
            try await host.captureThree(name, view)
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: path)
            .filter { name in InboxApprovalMocks.frames.contains { name.hasPrefix($0.0 + "-") } && name.hasSuffix(".png") }
        XCTAssertEqual(written.count, 3 * InboxApprovalMocks.frames.count)
    }
}

@MainActor
private enum InboxApprovalMocks {
    static let hub = "Acme Mac"
    static let source = "ϟ Release notes · run #4"

    static var frames: [(String, AnyView)] {
        [
            ("inbox-approval-pending", page(
                card(jira(), label: "With the permissions grant"),
                card(jira(id: 42), label: "Without the grant", override: .approveNote("Approve on the Mac"))
            )),
            ("inbox-approval-failed", page(
                card(failedJira(), label: "Failed — Retry", override: .retry),
                card(failedJira(id: 42), label: "Failed, without the grant", override: .note("Retry on the Mac", retryNote: true))
            )),
            ("inbox-approval-sending", page(
                card(jira(), label: "Approve on its way",
                     state: ChatApprovalState(showsButtons: true, canAnswer: false, line: "Approving…", inFlight: true)),
                card(failedJira(id: 42), label: "Retry on its way", override: .busy("Retrying…", retryNote: true)),
                card(jira(id: 43), label: "Waiting to send (the Mac is away)",
                     state: ChatApprovalState(showsButtons: true, canAnswer: false,
                                              line: "Waiting to send — it applies when \(hub) wakes."))
            )),
            ("inbox-approval-refused", page(
                card(jira(), label: "Refused with the tower's sentence", state: ChatApprovalState(
                    showsButtons: true, canAnswer: true, line: nil,
                    gestureError: "This proposal changed on the Mac — look again before approving."
                )),
                card(jira(id: 42), label: "Not delivered",
                     override: .resend(line: "Not delivered — \(hub) didn't get it.", title: "Retry Approve")),
                card(jira(id: 43), label: "Didn't confirm (the hub stopped mid-way)",
                     state: ChatApprovalState(showsButtons: true, canAnswer: false, line: "Didn't confirm — check on the Mac."))
            )),
            ("inbox-approval-settled", page(
                card(jira(status: "executing"), label: "Approved — the Mac runs it"),
                card(jira(id: 42, status: "applied",
                          result: #"{"url":"https://example.atlassian.net/browse/ACME-12","key":"ACME-12"}"#),
                     label: "Done, or already done on the Mac (until the publish drops it)"),
                card(connector(id: 53, dismissed: true), label: "Dismissed (until the publish drops it)")
            )),
            ("inbox-approval-dismiss", page(
                card(connector(), label: "Outcome unknown — Dismiss", dismiss: true),
                card(connector(id: 52), label: "Dismiss on its way", override: .busy("Dismissing…", retryNote: false)),
                card(connector(id: 54), label: "Outcome unknown, without the grant", override: .note("Dismiss on the Mac", retryNote: false))
            )),
            ("inbox-approval-mac-only", page(
                card(ChatAgentAction(id: 61, tool: "save_automation", argsJSON: #"{"name": "Weekly mail roundup"}"#,
                                     argsStored: false, argsSHA256: "e5", argsComplete: true),
                     label: "A recipe draft", override: .approveNote("Open Draft — on your Mac"),
                     title: "Save automation “Weekly mail roundup”",
                     summary: "“Every Monday, collect the week's unread mail into one roundup.”"),
                card(ChatAgentAction(id: 62, tool: "create_target",
                                     argsJSON: #"{"text": "Pin the rollout window", "priority": "high"}"#,
                                     argsStored: false, argsSHA256: "f6", argsComplete: true, status: "executing"),
                     label: "An Inbox button's task that didn't finish", override: .tryAgain)
            ))
        ]
    }

    // MARK: - Actions

    static func jira(id: Int64 = 41, status: String = "pending", error: String = "", result: String = "") -> ChatAgentAction {
        ChatAgentAction(
            id: id, tool: "create_jira_issue", external: true,
            argsJSON: #"{"project_key": "ACME", "issue_type": "Task", "summary": "Pin the rollout window", "labels": ["release"]}"#,
            argsStored: false, argsSHA256: "b2", argsComplete: true, reason: "From the release thread",
            status: status, resultJSON: result, error: error
        )
    }

    /// A failed external proposal. The card's own retry note is orange today; on the phone it is drawn in the secondary
    /// tone (§12.4, orange only waits for you), so the mock leaves `external` off, which hides the card's note, and
    /// `MockRow` draws the note in the secondary tone. The phone's header never shows `external`.
    static func failedJira(id: Int64 = 41) -> ChatAgentAction {
        let failed = jira(id: id, status: "failed", error: "jira: 503 Service Unavailable")
        return ChatAgentAction(
            id: failed.id, tool: failed.tool, external: false, argsJSON: failed.argsJSON, argsStored: false,
            argsSHA256: failed.argsSHA256, argsComplete: true, reason: failed.reason, status: failed.status, error: failed.error
        )
    }

    static func connector(id: Int64 = 51, dismissed: Bool = false) -> ChatAgentAction {
        ChatAgentAction(
            id: id, tool: ConnectorCallProposal.tool, external: true,
            argsJSON: #"{"server": "Linear", "tool": "create_issue", "input": {"team": "ACME", "title": "Pin the rollout window"}}"#,
            argsStored: false, argsSHA256: "d4", argsComplete: true, status: "failed",
            error: ConnectorCallProposal.sessionEndedWhileRunning, dismissedAt: dismissed ? "2026-11-18T09:00:00Z" : ""
        )
    }

    // MARK: - The page and the card

    static func page(_ cards: AnyView...) -> AnyView {
        AnyView(ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text("Needs approval").font(TypeScale.rowEmphasis)
                ForEach(Array(cards.enumerated()), id: \.offset) { $0.element }
            }
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(uiColor: .systemBackground))
        .environment(\.chatUIStyle, PhoneChatStyle())
        .environment(\.chatHostText, .phone(hub)))
    }

    static func card(
        _ action: ChatAgentAction,
        label: String,
        state: ChatApprovalState? = nil,
        dismiss: Bool = false,
        override: MockRow.Kind? = nil,
        title: String? = nil,
        summary: String? = nil
    ) -> AnyView {
        let services = ChatApprovalServices(
            state: { _ in state },
            dismiss: dismiss ? { _ in } : nil,
            title: { _ in title },
            details: { _ in summary.map { AnyView(Text($0).font(.callout).fixedSize(horizontal: false, vertical: true)) } },
            decisionOverride: { _ in override.map { AnyView(MockRow(kind: $0)) } }
        )
        return AnyView(VStack(alignment: .leading, spacing: Spacing.small) {
            Text(label).font(TypeScale.meta).foregroundStyle(.secondary)
            AgentActionCard(action: action, services: services, contextLabel: source)
        })
    }
}

/// A decision row the shared card does not draw yet, in the card's own style.
private struct MockRow: View {
    enum Kind {
        /// Approve is not offered here: its note in its place, Reject stays live.
        case approveNote(String)
        /// No button: the line says where to act (after the retry note, on a failed external proposal).
        case note(String, retryNote: Bool)
        /// The press on its way: its busy title with a spinner, the rest off.
        case busy(String, retryNote: Bool)
        /// A failed external proposal: the retry note in the secondary tone, and Retry.
        case retry
        /// Not delivered: the line in red and the press's named Retry, the row's one action.
        case resend(line: String, title: String)
        /// An Inbox button's stuck task: Didn't finish and Try again.
        case tryAgain
    }

    let kind: Kind

    static var retryNoteText: some View {
        Text("Retrying re-sends the request — check Jira for a duplicate first.").font(.caption).foregroundStyle(.secondary)
    }
    @Environment(\.chatUIStyle) private var style

    var body: some View {
        switch kind {
        case let .approveNote(note):
            HStack(spacing: Spacing.regular) {
                Text(note).font(.caption).foregroundStyle(.secondary)
                style.approvalButton("Reject", prominent: false) {}
            }
        case let .note(line, retryNote):
            VStack(alignment: .leading, spacing: Spacing.regular) {
                if retryNote { Self.retryNoteText }
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        case let .busy(title, retryNote):
            VStack(alignment: .leading, spacing: Spacing.regular) {
                if retryNote { Self.retryNoteText }
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .retry:
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Self.retryNoteText
                Button("Retry") {}
            }
        case let .resend(line, title):
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Label(line, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(PhoneTone.red.color)
                style.approvalButton(title, prominent: true) {}
            }
        case .tryAgain:
            HStack(spacing: Spacing.regular) {
                Text("Didn't finish").font(.caption).foregroundStyle(.secondary)
                style.approvalButton("Try again", prominent: true) {}
            }
        }
    }
}
