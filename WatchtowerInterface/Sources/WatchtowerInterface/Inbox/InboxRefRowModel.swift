/// A list row that carries a ref (a Waiting for me ping, a track, an idea,
/// a reminder, a plan item) and its native actions (mobile Inbox spec §7,
/// mockup §2). `buttons` are the Mac's row buttons (`InboxRowActionsView`,
/// `InboxRowActionsContent.ideaButtons`) in its order, read from the ref's
/// facts; on the phone a button the tower cannot write is drawn disabled
/// with "On your Mac". The phone's swipes: left for Done and Snooze, right
/// for Hide; a track gets Done and Stop, a reminder Done and Snooze 1h. A
/// closed ref's row is never built (`ref_facts.open`).
public struct InboxRefRowModel: Equatable, Sendable {
    public let facts: RefFacts
    /// The row's optimistic-hide key (`InboxHiddenRows`).
    public let key: String
    /// The row's buttons in the Mac's order (`InboxRefButton.inMore`: in its ⋯ menu).
    public let buttons: [InboxRefButton]
    /// Swipe right (the phone).
    public let leadingSwipe: [RefVerb]
    /// Swipe left (the phone).
    public let trailingSwipe: [RefVerb]
    /// The tower verbs this platform may send from the row's menu, in order.
    public let menu: [RefVerb]
    /// Reply… is offered and pressable.
    public var canReply: Bool {
        buttons.contains { $0.action == .reply && $0.enabled }
    }

    public init(facts: RefFacts, platform: Platform, grants: Grants) {
        self.facts = facts
        key = Self.key(facts)
        buttons = Self.macButtons(facts).map { InboxRefButton($0, facts: facts, platform: platform, grants: grants) }
        menu = buttons.filter(\.enabled).compactMap(\.verb)
        let swipes = Self.swipes(facts)
        leadingSwipe = swipes.leading.filter(menu.contains)
        trailingSwipe = swipes.trailing.filter(menu.contains)
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

    /// Reply…'s Propose: the reply goes to Needs approval. Go's
    /// `replyPropose` reads `ref_kind` (an inbox item), `ref_id` and a
    /// non-blank `text`, and answers `unsupported` without any of them.
    public func replyRequest(text: String, cardID: String, requestID: String) -> ActRequest {
        ActRequest(
            requestID: requestID,
            target: cardID,
            verb: .replyPropose,
            params: ActParams(text: text, refKind: facts.kind, refID: facts.id)
        )
    }

    /// The Mac's buttons for the ref (`InboxRefHooks.kind` over the facts).
    static func macButtons(_ facts: RefFacts) -> [InboxRefButton.Action] {
        switch facts.kind {
        case .inboxItem:
            return (facts.link.isEmpty ? [] : [.open]) + (facts.reply ? [.reply] : [])
                + [.done, .hide, .snooze, .discussInChat, .handToAgent]
        case .track:
            return [.done, .stopWatching] + (facts.custom ? [] : [.makeTask])
                + (facts.custom && facts.linkedTargetID != 0 ? [.goToTarget] : [])
                + (facts.custom ? [.deleteTrack] : [])
        case .idea:
            return ideaButtons(kind: facts.ideaKind, status: facts.ideaStatus, awaitsVerdict: facts.waits)
        case .reminder:
            return [.done, .snoozeHour]
        case .planItem:
            return [.check, .uncheck]
        case .action, .unknown:
            return []
        }
    }

    /// `InboxRowActionsContent.ideaButtons`: awaiting a verdict → Approve,
    /// Make a Task (ideas), Not now (not notes), Reject; an active idea →
    /// Make a Task, Not now, Drop; a not-now idea → Activate, Make a Task,
    /// Drop; an active note → Drop; a rejected or dropped one (and a
    /// decision not now) → Activate.
    static func ideaButtons(kind: String, status: String, awaitsVerdict: Bool) -> [InboxRefButton.Action] {
        if awaitsVerdict {
            return [.approve] + (kind == "idea" ? [.makeTask] : []) + (kind == "note" ? [] : [.notNow]) + [.reject]
        }
        if kind == "decision" {
            return ["rejected", "dropped", "not_now"].contains(status) ? [.activate] : []
        }
        switch (kind, status) {
        case ("idea", "active"): return [.makeTask, .notNow, .drop]
        case ("idea", "not_now"): return [.activate, .makeTask, .drop]
        case ("note", "active"): return [.drop]
        case (_, "rejected"), (_, "dropped"): return [.activate]
        default: return []
        }
    }

    /// The phone's swipes by kind (filtered to the verbs the row offers).
    private static func swipes(_ facts: RefFacts) -> (leading: [RefVerb], trailing: [RefVerb]) {
        switch facts.kind {
        case .inboxItem: ([.dismiss], [.resolve, .snooze])
        case .track: ([], [.done, .stop])
        case .reminder: ([], [.done, .snooze])
        case .idea: ([.reject], [.approve, .notNow])
        case .planItem: ([], [.check])
        case .action, .unknown: ([], [])
        }
    }
}

/// One button of a ref row.
public struct InboxRefButton: Equatable, Sendable {
    /// The Mac's row presses (`InboxRowPress`) a ref row draws.
    public enum Action: Hashable, Sendable {
        case open, reply, done, hide, snooze, snoozeHour, discussInChat, handToAgent
        case stopWatching, makeTask, goToTarget, deleteTrack
        case approve, reject, notNow, activate, drop, check, uncheck
    }

    public let action: Action
    public let label: String
    /// The tower verb it sends; nil for a press that stays local (Open,
    /// Reply… opens a sheet) or that only the Mac writes.
    public let verb: RefVerb?
    public let enabled: Bool
    /// "On your Mac" on the phone for a press only the Mac makes.
    public let note: String?
    /// Behind the Mac row's ⋯ button.
    public let inMore: Bool

    init(_ action: Action, facts: RefFacts, platform: Platform, grants: Grants) {
        self.action = action
        label = Self.label(action, facts: facts)
        verb = Self.verb(action, kind: facts.kind)
        inMore = Self.inMore(action, kind: facts.kind)
        let local = action == .open || action == .reply
        if platform == .phone, verb == nil, !local {
            enabled = false
            note = TowerText.onYourMac
            return
        }
        note = nil
        switch action {
        case .reply:
            enabled = !facts.replyWaiting && (platform == .mac || grants.typing)
        case .makeTask:
            // An owner gesture the hub grants with permissions.
            enabled = platform == .mac || grants.permissions
        default:
            enabled = true
        }
    }

    private static func verb(_ action: Action, kind: RefKind) -> RefVerb? {
        switch action {
        case .done: kind == .inboxItem ? .resolve : .done
        case .hide: .dismiss
        case .snooze, .snoozeHour: .snooze
        case .stopWatching: .stop
        // An idea's Make a Task converts it on the Mac; a track's applies its event.
        case .makeTask: kind == .track ? .makeTask : nil
        // Activate writes what Approve writes (status active).
        case .approve, .activate: .approve
        case .reject: .reject
        case .notNow: .notNow
        case .check: .check
        case .uncheck: .uncheck
        case .open, .reply, .discussInChat, .handToAgent, .goToTarget, .deleteTrack, .drop: nil
        }
    }

    private static func inMore(_ action: Action, kind: RefKind) -> Bool {
        switch action {
        case .discussInChat, .handToAgent, .goToTarget, .deleteTrack: true
        case .stopWatching, .makeTask: kind == .track
        default: false
        }
    }

    private static func label(_ action: Action, facts: RefFacts) -> String {
        action == .open ? TowerText.openLabel(trigger: facts.triggerType) : labels[action] ?? ""
    }

    private static let labels: [Action: String] = [
        .reply: TowerText.reply, .done: TowerText.done, .check: TowerText.done, .uncheck: TowerText.notDone,
        .hide: TowerText.hide, .snooze: TowerText.snooze, .snoozeHour: TowerText.snoozeOneHour,
        .discussInChat: TowerText.discussInChat, .handToAgent: TowerText.handToAgent,
        .stopWatching: TowerText.stopWatching, .makeTask: TowerText.makeATask, .goToTarget: TowerText.goToTarget,
        .deleteTrack: TowerText.deleteTrack, .approve: TowerText.approve, .reject: TowerText.reject,
        .notNow: TowerText.notNow, .activate: TowerText.activate, .drop: TowerText.drop
    ]
}
