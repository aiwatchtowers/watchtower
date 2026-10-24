import SwiftUI
import WatchtowerCore

/// The reviewed session's agent, for Branch review's chat panel and Ask
/// agent (board #962, spec §4): its Workchat model is the one the Workchat
/// pane uses, so both show one conversation and one draft.
@MainActor
struct ReviewAgentChat {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let sessionID: Int64

    /// The panel's open state, per workbench; its width sits under `widthKey`.
    var openKey: String { "review.chatPanel.\(projectID)" }
    var widthKey: String { "review.chatPanel.\(projectID).width" }

    /// The session's Workchat; nil without session control or once the session is gone.
    var workchat: WorkchatModel? {
        guard vm.session(sessionID, projectID: projectID) != nil else { return nil }
        return vm.workchat(sessionID: sessionID)
    }

    /// The session's ask drawer, when this review hosts it: the session's
    /// terminal and Workchat are not on screen (either would host it there).
    var drawerAsk: OwnerAsk? {
        guard !vm.layout(projectID: projectID).showsSession(sessionID) else { return nil }
        return vm.asks.drawerAsk(projectID: projectID).flatMap { $0.sessionID == sessionID ? $0 : nil }
    }

    /// Puts `quote` at the top of the draft; nothing while the session is not running.
    func ask(_ quote: String) {
        guard let workchat else { return }
        workchat.draft = ReviewAskQuote.prepend(quote, to: workchat.draft)
    }
}

/// The right-hand panel of Branch review: the session's Workchat, or one
/// line when there is no session to talk to.
struct ReviewAgentChatPanel: View {
    let chat: ReviewAgentChat
    /// Each new value puts the keyboard in the composer.
    let composerFocus: UUID?
    /// The panel opened for Ask agent: the composer takes the keyboard as it
    /// is made (a focus request made with the field is not acted on).
    let focusOnOpen: Bool
    /// The panel is on screen: `focusOnOpen` was used.
    let onShown: () -> Void

    var body: some View {
        Group {
            if chat.workchat != nil {
                SessionChatView(vm: chat.vm, sessionID: chat.sessionID, projectID: chat.projectID,
                                composerFocus: composerFocus, composerAutoFocus: focusOnOpen)
                    .id(chat.sessionID)
            } else {
                Text("The session is not running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Spacing.medium)
            }
        }
        .onAppear(perform: onShown)
    }
}
