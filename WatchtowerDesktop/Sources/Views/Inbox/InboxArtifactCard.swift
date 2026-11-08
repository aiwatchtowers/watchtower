import SwiftUI
import WatchtowerCore

/// How the reading pane draws an automation card's body (spec "Today's
/// Inbox"): a card without blocks keeps its markdown body and its own button
/// row (`InboxCardButtons`); a card with blocks is drawn by `ArtifactCardBody`
/// from what the Kit decodes — the blocks, or for a newer version or a
/// layout that can't be read, the plain-text body and the line saying why.
/// The card's own buttons are decoded with its blocks (`decodeCard`), so
/// undecodable buttons fall back to unreadable instead of shifting every
/// block button's press index.
enum InboxCardLayout: Equatable {
    case markdown
    case artifact(ArtifactDecodeResult, cardActions: [ArtifactAction])

    static func of(_ card: AutomationOutputCard) -> Self {
        guard !card.blocksJSON.isEmpty else { return .markdown }
        let decoded = ArtifactDocument.decodeCard(blocksJSON: card.blocksJSON, actionsJSON: card.actionsJSON)
        return .artifact(decoded.result, cardActions: decoded.cardActions)
    }

    /// Every button the card draws, by its flattened index (the press
    /// address `automations reply --action` takes); nothing for `.markdown`,
    /// whose buttons `InboxCardButtons` reads itself.
    var pressable: [InboxCardAction] {
        guard case let .artifact(result, cardActions) = self else { return [] }
        let all: [ArtifactAction]
        if case let .document(document) = result {
            all = document.flattenedActions(cardActions: cardActions)
        } else {
            all = cardActions
        }
        return all.enumerated().compactMap { InboxCardAction($0.element, index: $0.offset) }
    }

    /// The card has a Reply button: its one-press state is said under the body.
    var hasReply: Bool {
        pressable.contains { if case .reply = $0.kind { true } else { false } }
    }
}

/// A card drawn from blocks in the reading pane: `ArtifactCardBody` with the
/// app's `ArtifactEnvironment` — the chat's markdown renderer, people from
/// the local `users` table, presses routed through `InboxCardPress` like the
/// card's own button row — then the Reply state and the common row.
struct InboxArtifactCard: View {
    let card: AutomationOutputCard
    let result: ArtifactDecodeResult
    let cardActions: [ArtifactAction]
    /// `users` id → best name (`InboxFeedSnapshot.artifactPeople`).
    let people: [String: String]
    let navScreens: Set<String>
    let isWriting: Bool
    let onCommand: (InboxCardCommand) -> Void
    let onDone: () -> Void
    let onDismiss: () -> Void
    let workbenches: [Workbench]
    /// The target buttons' state, from the Inbox center.
    var targets = InboxTargetButtonSource()
    /// False: no Done or Dismiss (`InboxCardButtons.showsDoneDismiss`).
    var showsDoneDismiss = true
    /// The native row actions of rows with a `ref` (`InboxRefHooks`).
    var refHooks = ArtifactRefHooks()

    /// An agent press waiting for the owner's workbench.
    @State private var pickingTask: String?

    private var layout: InboxCardLayout { .artifact(result, cardActions: cardActions) }

    var body: some View {
        let reply = InboxCardAction.replyState(card)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ArtifactCardBody(result: result, text: card.body, cardActions: cardActions, mode: .inbox)
                .environment(\.artifactEnvironment, environment(reply: reply))
                .environment(\.openURL, OpenURLAction { url in
                    // Links in blocks go through the card's link rules at press time.
                    onCommand(.openLink(url))
                    return .handled
                })
                .popover(isPresented: isPicking, arrowEdge: .bottom) {
                    InboxWorkbenchPicker(workbenches: workbenches, onPick: pick).popoverSurface()
                }
            if layout.hasReply, let caption = Self.replyCaption(reply) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            InboxCardButtons(card: card, navScreens: navScreens, isWriting: isWriting, onCommand: onCommand,
                             onDone: onDone, onDismiss: onDismiss, workbenches: workbenches,
                             drawsOwnActions: false, showsDoneDismiss: showsDoneDismiss)
                .padding(.top, Spacing.small)
        }
    }

    /// The Reply state in words: "Sent — run #N" once pressed (the buttons
    /// drawn in blocks keep their labels), else why it cannot send.
    static func replyCaption(_ reply: InboxReplyState) -> String? {
        if case let .sent(runID) = reply { return runID.map { "Sent — run #\($0)" } ?? "Sent" }
        return InboxCardButtons.caption(reply)
    }

    /// The chat's markdown renderer for a block's `md` text: the Inbox
    /// card's, and the editor's Look preview's ("drawn as the Inbox draws it").
    static func markdown(_ text: String) -> AnyView {
        AnyView(MarkdownView(text: text))
    }

    private func environment(reply: InboxReplyState) -> ArtifactEnvironment {
        let byIndex = Dictionary(layout.pressable.map { ($0.index, $0) }) { first, _ in first }
        // Labeled: with several closures a trailing one would be ambiguous.
        // swiftlint:disable trailing_closure
        return ArtifactEnvironment(
            markdown: Self.markdown,
            avatar: { Self.avatar(people[$0]) },
            onAction: { index in
                guard let action = byIndex[index] else { return }
                if case .target(let target) = action.kind {
                    if let command = targets.command(target, index: index, card: card) { onCommand(command) }
                    return
                }
                switch InboxCardPress.resolve(action, card: card, reply: reply, workbenches: workbenches) {
                case .command(let command): onCommand(command)
                case .pick(let task): pickingTask = task
                case .nothing: break
                }
            },
            refHooks: refHooks,
            targetButtonState: { index in
                guard case .target(let target)? = byIndex[index]?.kind else { return .idle }
                return targets.button(target, index: index, card: card).state
            },
            isActionEnabled: { index in
                guard let action = byIndex[index] else { return false }
                if case .target(let target) = action.kind {
                    return !targets.isProposing(targets.button(target, index: index, card: card).context)
                }
                return !InboxCardPress.isDisabled(action, reply: reply, isWriting: isWriting, navScreens: navScreens)
            }
        )
        // swiftlint:enable trailing_closure
    }

    /// A person the local `users` table knows: the initials of their Slack
    /// name on the accent fill. Nil (an unknown user) leaves the block's
    /// own initials of the name the recipe wrote.
    static func avatar(_ name: String?) -> AnyView? {
        guard let name else { return nil }
        let words = name.split(whereSeparator: \.isWhitespace).prefix(2)
        let initials = words.compactMap(\.first).map(String.init).joined().uppercased()
        return AnyView(
            Text(initials)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Fill.on)
        )
    }

    private var isPicking: Binding<Bool> {
        Binding(get: { pickingTask != nil }, set: { if !$0 { pickingTask = nil } })
    }

    private func pick(_ workbenchID: Int64) {
        guard let task = pickingTask else { return }
        pickingTask = nil
        onCommand(.agent(InboxCardSubject(card), task: task, workbench: .id(workbenchID)))
    }
}
