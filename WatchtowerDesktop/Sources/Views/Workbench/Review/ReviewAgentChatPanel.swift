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

    /// The panel's open state, per workbench; its width sits under `widthKey`
    /// and the Reviewer | Author switch under `sideKey`.
    var openKey: String { "review.chatPanel.\(projectID)" }
    var widthKey: String { "review.chatPanel.\(projectID).width" }
    var sideKey: String { "review.chatPanel.\(projectID).side" }

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

/// Which side of the panel is shown (board #1025, mockup frame 5).
enum ReviewChatSide: String {
    case reviewer, author
}

/// The right-hand panel of Branch review: a **Reviewer | Author** switch
/// (when the app has a reviewer) over the branch's independent reviewer or
/// the session's Workchat — unchanged — or one line when there is no session
/// to talk to.
struct ReviewAgentChatPanel: View {
    let chat: ReviewAgentChat
    /// The round the reviewer reads and Send to author writes into.
    let model: ReviewChangesModel
    let identity: ReviewSessionIdentity
    @Binding var side: ReviewChatSide
    /// Each new value puts the keyboard in the composer.
    let composerFocus: UUID?
    /// The panel opened for Ask agent: the composer takes the keyboard as it
    /// is made (a focus request made with the field is not acted on).
    let focusOnOpen: Bool
    /// The panel is on screen: `focusOnOpen` was used.
    let onShown: () -> Void

    /// What the author side shows: the Workchat with its composer, or one line.
    enum Content: Equatable {
        case workchat
        case notRunning
    }

    static let notRunningText = "The session is not running"

    static func content(_ chat: ReviewAgentChat) -> Content {
        chat.workchat == nil ? .notRunning : .workchat
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reviewer = chat.vm.reviewer {
                HStack(spacing: Spacing.cozy) {
                    KitSegmentedPicker(title: "Chat", selection: $side, segments: [
                        KitSegment(value: ReviewChatSide.reviewer, title: "Reviewer"),
                        KitSegment(value: .author, title: "Author")
                    ])
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.small)
                Divider()
                if side == .reviewer {
                    ReviewerPanel(center: reviewer, model: model, context: ReviewerSurface.context(
                        projectID: chat.projectID, sessionID: chat.sessionID, round: model.round,
                        place: identity.place, mainStatus: identity.mainStatus
                    ))
                } else {
                    author
                }
            } else {
                author
            }
        }
        .onAppear(perform: onShown)
    }

    @ViewBuilder private var author: some View {
        switch Self.content(chat) {
        case .workchat:
            SessionChatView(vm: chat.vm, sessionID: chat.sessionID, projectID: chat.projectID,
                            composerFocus: composerFocus, composerAutoFocus: focusOnOpen)
                .id(chat.sessionID)
        case .notRunning:
            Text(Self.notRunningText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Spacing.medium)
        }
    }
}
