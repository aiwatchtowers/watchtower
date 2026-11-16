import Foundation

/// One card as both clients draw it (mobile Inbox spec §7, mockup §4): its
/// lines with the time in the client's zone, its buttons with the platform's
/// rules, and its open ref rows. Holds no client state: a press's busy,
/// refused and unknown states come from `TowerClient`.
public struct InboxCardModel: Equatable, Sendable {
    public let card: Card
    public let id: String
    public let title: String
    /// The source, then " · " and the card's time in the client's zone.
    public let sourceLine: String
    public let preview: String
    /// The card's time alone ("9:14", or "Nov 12, 9:14" on another day).
    public let stamp: String
    /// Set when this app cannot read the card's blocks: its text is shown.
    public let unsupportedBanner: String?
    /// Unread is a dot only: the title keeps its weight.
    public let showsUnreadDot: Bool
    public let actions: [InboxCardActionModel]
    /// The open ref rows not hidden on `ok`, in document order.
    public let refRows: [InboxRefRowModel]

    public init(
        card: Card,
        platform: Platform,
        grants: Grants,
        blocksReadable: Bool,
        now: Date,
        timeZone: TimeZone = .current,
        hidden: InboxHiddenRows = InboxHiddenRows()
    ) {
        self.card = card
        id = card.id
        title = card.title
        preview = card.preview
        stamp = InboxTime.parse(card.stamp).map { InboxTime.clock($0, now: now, timeZone: timeZone) } ?? ""
        sourceLine = [card.sourceLine, stamp].filter { !$0.isEmpty }.joined(separator: " · ")
        unsupportedBanner = blocksReadable ? nil : TowerText.unsupportedCard
        showsUnreadDot = card.unread
        actions = card.actions.map { InboxCardActionModel($0, platform: platform, grants: grants, now: now) }
        refRows = card.refFacts
            .filter { $0.open && !hidden.isHidden(InboxRefRowModel.key($0)) }
            .map { InboxRefRowModel(facts: $0, platform: platform, grants: grants) }
    }

    /// The card's own verbs (`read` on open, Done, Dismiss, Run Now): each
    /// guarded by the drawn version (`content_hash`).
    public func request(_ verb: ActVerb, requestID: String) -> ActRequest {
        ActRequest(requestID: requestID, target: id, verb: verb, params: ActParams(contentHash: card.contentHash))
    }

    /// A button press: it names the drawn button's kind (`action_kind`),
    /// without which the tower refuses `changed`. `text` is a Reply's.
    public func press(_ action: InboxCardActionModel, requestID: String, text: String? = nil) -> ActRequest {
        ActRequest(
            requestID: requestID,
            target: id,
            verb: .press,
            params: ActParams(contentHash: card.contentHash, index: action.index, actionKind: action.kind, text: text)
        )
    }
}

/// One button of a card.
public struct InboxCardActionModel: Equatable, Sendable {
    public let index: Int
    /// The button's kind as drawn (`reply`, `target`, `link`, `chat`, `agent`).
    public let kind: String
    public let label: String
    public let enabled: Bool
    /// The line drawn with it: `TowerText.onYourMac` for a Mac-only action on
    /// the phone, "Didn't finish" on a stuck target, else the Mac's caption.
    public let note: String?
    /// The button's own state (`CardAction.detail`), with a creating target
    /// past its `until` read as `stuck` by the client's clock.
    public let detail: String

    /// The kinds whose handoff stays on the Mac.
    static let macOnlyKinds: Set = ["chat", "agent", "save_automation"]

    init(_ action: CardAction, platform: Platform, grants: Grants, now: Date) {
        index = action.index
        kind = action.kind
        label = action.label
        let stuck = action.kind == "target" && action.detail == "creating"
            && InboxTime.parse(action.until).map { now >= $0 } == true
        detail = stuck ? "stuck" : action.detail
        let macOnly = action.state == .macOnly || Self.macOnlyKinds.contains(action.kind)
        if platform == .phone, macOnly || !Self.granted(action.kind, grants) {
            enabled = false
            note = TowerText.onYourMac
            return
        }
        if stuck {
            enabled = true
            note = TowerText.didntFinish
            return
        }
        switch action.state {
        case .enabled, .macOnly: enabled = true
        case .disabled, .pressed, .unknown: enabled = false
        }
        note = action.note.isEmpty ? nil : action.note
    }

    /// The phone's grant a press of `kind` needs (`inboxfeed.ActGrant`):
    /// `typing` for a Reply, `permissions` for a target.
    private static func granted(_ kind: String, _ grants: Grants) -> Bool {
        switch kind {
        case "reply": grants.typing
        case "target": grants.permissions
        default: true
        }
    }
}
