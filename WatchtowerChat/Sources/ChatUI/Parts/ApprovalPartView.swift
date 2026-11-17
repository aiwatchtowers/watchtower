import ChatWire
import SwiftUI

/// An agent action waiting for the owner, or its outcome (the `approval` part; for a Mac one version behind, a feed
/// action), drawn by the one card both devices share (`AgentActionCard`). The Mac resolves the part to its loaded row
/// (`ChatApprovalServices.resolve`); the phone, and a Mac card whose row is not loaded yet, draw it from the payload.
/// A card the running turn waits on is outlined.
struct ApprovalPartView: View {
    let payload: ChatApprovalPayload
    let context: ChatPartContext

    var body: some View {
        let services = context.actions.approvals
        let action = services.resolve?(payload) ?? ChatAgentAction(payload: payload)
        AgentActionCard(
            action: action, services: services,
            outlined: AgentActionCard.isAwaited(action, runningTurnID: context.runningTurnID)
                || services.highlighted?(action) == true,
            fallbackTitle: payload.title, drafts: nil
        )
        .accessibilityIdentifier("chat.approval.\(payload.id)")
    }
}
