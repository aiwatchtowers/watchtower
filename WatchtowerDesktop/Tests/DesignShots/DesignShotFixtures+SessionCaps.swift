import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// Plan 2026-11-05 Task G7: the honest Workchat composer (U2) and the
/// Notifications caption (U7), on fixture data.
@MainActor
enum SessionCapsShotFixtures {
    /// U2: a Codex session works; a line waits, dashed, above the composer's
    /// caption.
    static func workchatHoldCaption() -> AnyView {
        let model = WorkchatModel(
            sessionID: 1, control: IdleControl(), lineDelivery: SessionLineDelivery(terminalCenter: nil),
            kind: { .codex }, now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
        let line = WorkchatOutgoing(
            id: UUID(), text: "also check the migration", sentAt: Date(timeIntervalSince1970: 1_790_000_000),
            state: .queued
        )
        return AnyView(VStack(spacing: 8) {
            WorkchatOutgoingBubble(line: line, working: true, holdsUntilIdle: true, onCancel: {}, onShowTerminal: {})
                .padding(.horizontal, 16)
            WorkchatComposer(model: model, working: true)
        }
        .padding(.vertical, 12))
    }

    /// U7: Settings → Notifications' Workbench row with the idle caption
    /// from the capability rows, between two of its neighbours. (The whole
    /// screen asks the notification center on appear, which a test process
    /// cannot.)
    static func notificationSettings() -> AnyView {
        AnyView(Form {
            Section("Notifications") {
                Toggle("Briefing notifications", isOn: .constant(true))
                NotificationSettings.workbenchRow(isOn: .constant(true))
                Toggle("Claude plan limits", isOn: .constant(false))
            }
        }
        .formStyle(.grouped))
    }

    /// A Workchat control that reads nothing and sends nothing.
    private final class IdleControl: WorkchatControl {
        func lineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .hold(.agentBusy) }
        func workchatLineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .hold(.agentBusy) }
        func isWorking(_ sessionID: Int64) -> Bool { true }
        func interrupt(_ sessionID: Int64) async throws -> SessionControl.InterruptResult { .notWorking }
        func pendingPermission(_ sessionID: Int64) async throws -> SessionControl.PermissionPrompt? { nil }
        func answerPermission(requestID: Int64, sessionID: Int64, allow: Bool, decidedBy: String) async throws
            -> SessionControl.PermissionAnswer { .notFound }
    }
}
