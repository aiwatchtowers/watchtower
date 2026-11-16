/// A list row that carries a ref (a Waiting for me ping, a track, an idea,
/// a reminder, a plan item) and its native actions (mobile Inbox spec §7,
/// mockup §2): swipe left for Done and Snooze, swipe right for Hide; a
/// track gets Done and Stop, a reminder Done and Snooze 1h. The context
/// menu holds every verb of the kind, Make a Task included, and is also the
/// accessibility path. A closed ref's row is never built (`ref_facts.open`).
public struct InboxRefRowModel: Equatable, Sendable {
    public let facts: RefFacts
    /// The row's optimistic-hide key (`InboxHiddenRows`).
    public let key: String
    /// Swipe right.
    public let leadingSwipe: [RefVerb]
    /// Swipe left.
    public let trailingSwipe: [RefVerb]
    public let menu: [RefVerb]
    /// Reply… (an inbox item with a Reply and none open); on the phone it
    /// needs the `typing` grant.
    public let canReply: Bool

    public init(facts: RefFacts, platform: Platform, grants: Grants) {
        self.facts = facts
        key = Self.key(facts)
        let verbs = Self.verbs(facts.kind)
        leadingSwipe = verbs.leading
        trailingSwipe = verbs.trailing
        // Make a Task is an owner gesture the hub grants with permissions.
        let mayPropose = platform == .mac || grants.permissions
        menu = verbs.menu.filter { $0 != .makeTask || mayPropose }
        canReply = facts.kind == .inboxItem && facts.reply && !facts.replyWaiting
            && (platform == .mac || grants.typing)
    }

    public static func key(_ facts: RefFacts) -> String {
        "\(facts.kind.rawValue):\(facts.id)"
    }

    /// The `inbox.act` request of `verb` on this row of card `cardID`.
    /// `until` is a snooze's end (RFC 3339 UTC); `eventID` the track event a
    /// track's Make a Task applies.
    public func request(
        _ verb: RefVerb,
        cardID: String,
        requestID: String,
        until: String? = nil,
        eventID: Int64? = nil
    ) -> ActRequest {
        ActRequest(
            requestID: requestID,
            target: cardID,
            verb: .ref,
            params: ActParams(refKind: facts.kind, refID: facts.id, refVerb: verb, eventID: eventID, until: until)
        )
    }

    /// Reply…'s Propose: the reply goes to Needs approval.
    public func replyRequest(text: String, cardID: String, requestID: String) -> ActRequest {
        ActRequest(
            requestID: requestID,
            target: cardID,
            verb: .replyPropose,
            params: ActParams(text: text, refID: facts.id)
        )
    }

    /// A verb's label on this kind's row.
    public static func label(_ verb: RefVerb, kind: RefKind) -> String {
        switch verb {
        case .resolve, .done, .check: TowerText.done
        case .uncheck: TowerText.notDone
        case .snooze: kind == .reminder ? TowerText.snoozeOneHour : TowerText.snooze
        case .dismiss: TowerText.hide
        case .stop: TowerText.stopWatching
        case .restore: TowerText.restore
        case .makeTask: TowerText.makeATask
        case .approve: TowerText.approve
        case .reject: TowerText.reject
        case .notNow: TowerText.notNow
        case .unknown(let raw): raw
        }
    }

    /// Each kind's verbs (`inbox.act`'s ref table, spec §4.3).
    private static func verbs(_ kind: RefKind) -> (leading: [RefVerb], trailing: [RefVerb], menu: [RefVerb]) {
        switch kind {
        case .inboxItem: ([.dismiss], [.resolve, .snooze], [.resolve, .snooze, .dismiss])
        case .track: ([], [.done, .stop], [.done, .stop, .makeTask])
        case .reminder: ([], [.done, .snooze], [.done, .snooze])
        case .idea: ([.reject], [.approve, .notNow], [.approve, .notNow, .reject])
        case .planItem: ([], [.check], [.check, .uncheck])
        case .action, .unknown: ([], [], [])
        }
    }
}
