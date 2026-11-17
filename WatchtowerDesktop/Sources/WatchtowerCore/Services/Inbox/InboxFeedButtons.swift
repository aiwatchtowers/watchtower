import Foundation
import WatchtowerInterface

/// An artifact card's buttons as the tower's feed draws them
/// (`Card.actions`, Go `inboxfeed.cardActions`), by press index. Go decides
/// a Reply's state, label and caption; the Mac only draws them, and keeps
/// its own link rules (`InboxCardLinkPolicy`) and handoffs.
package struct InboxFeedButtons: Equatable, Sendable {
    package let actions: [CardAction]

    package init(_ card: Card?) {
        actions = card?.actions ?? []
    }

    /// The feed's action at press `index`; nil when the feed has none there.
    package func action(at index: Int) -> CardAction? {
        actions.first { $0.index == index }
    }

    /// The label the button draws: Go's ("Sent — run #N" on the pressed
    /// Reply), else the recipe's own.
    package func label(at index: Int, recipe: String) -> String {
        action(at: index)?.label ?? recipe
    }

    /// The Reply at `index` sends now (Go's `ready`); any other Reply opens
    /// its automation, where the recipe is confirmed or turned on.
    package func replySends(at index: Int) -> Bool {
        action(at: index)?.detail == Self.ready
    }

    /// The Reply at `index` cannot be pressed: already sent, its recipe
    /// removed, or not in the feed.
    package func replyClosed(at index: Int) -> Bool {
        action(at: index)?.state != .enabled
    }

    /// Why the card's Reply buttons will not send now (Go's caption: "Needs
    /// confirmation", "Off", …); nil when they will or were sent.
    package var replyCaption: String? {
        replies.first { !$0.note.isEmpty }?.note
    }

    /// The line under a card drawn from blocks, whose buttons keep their
    /// recipe labels: the pressed Reply's label once sent (`pressed` is its
    /// index), else the caption.
    package func replyLine(pressed: Int?) -> String? {
        guard replies.contains(where: { $0.detail == Self.sent }) else { return replyCaption }
        return pressed.flatMap { action(at: $0)?.label } ?? Self.sentLabel
    }

    /// A sent Reply's line when the pressed one is not drawn.
    package static let sentLabel = "Sent"

    private static let ready = "ready"
    private static let sent = "sent"

    private var replies: [CardAction] {
        actions.filter { $0.kind == "reply" }
    }
}
