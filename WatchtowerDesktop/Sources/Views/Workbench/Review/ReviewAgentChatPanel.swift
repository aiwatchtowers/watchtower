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

    var body: some View {
        if chat.workchat != nil {
            SessionChatView(vm: chat.vm, sessionID: chat.sessionID, projectID: chat.projectID,
                            composerFocus: composerFocus)
                .id(chat.sessionID)
        } else {
            Text("The session is not running")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Spacing.medium)
        }
    }
}
