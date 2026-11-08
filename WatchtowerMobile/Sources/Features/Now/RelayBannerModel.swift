import Foundation
import WatchtowerSync

/// Now's Relay banner (relay client Phase 4 Task 10, mockup S30–S36, S47, S50, S51, S53): one at most (Open decision 17), and
/// never orange, as Relay is no waiting-for-you element. Every text lives here and is asserted in `RelayBannerModelTests`.
///
/// While `unconfirmedPurchase` is set the owner has been charged, so nothing says "Subscribe" or "ended": those frames name
/// the purchase instead (S55's words, opening the same screen). The relay's own word on a move stays, as on the card.
struct RelayBannerModel: Equatable {
    enum Action: Hashable {
        case switchToICloud, subscribe, restore, ok
        /// Opens the subscription screen, which says where a charged purchase stands.
        case confirmPurchase
        /// S59: the phone left behind forgets the Mac (today's Forget, `LinkingViewModel.forget`).
        case forget
    }

    /// Where a refused link's term line shows (relay client Phase 5, Task 17, S61): the Relay banner on Now, Now's quiet
    /// row for a Mac, or that Mac's row in Settings → Macs.
    enum TermSurface: Equatable {
        case banner, now, macs
    }

    static let forgetThisMac = "Forget This Mac"

    static let unavailableAfter: TimeInterval = 60
    static let offerAfter: TimeInterval = 600
    /// The subscription sheet's way out: its screen has no button of its own until a purchase is done.
    static let sheetClose = "Close"
    static let switching = "Switching to iCloud…"

    let text: String
    let secondLine: String?
    let secondLineTone: PhoneTone
    let actions: [Action]
    let busy: Bool
    let toneUses: [ToneUse]
    /// The banner speaks of a refused link's term itself (S59 or the needs-Relay banner of such a link), with its own
    /// line or, by design, without one: Now's row for the Mac on screen shows only when it does not.
    let speaksOfTerm: Bool
    private let macName: String

    private init(
        text: String,
        secondLine: String? = nil,
        secondLineTone: PhoneTone = .secondary,
        actions: [Action] = [],
        busy: Bool = false,
        speaksOfTerm: Bool = false,
        macName: String
    ) {
        self.speaksOfTerm = speaksOfTerm
        self.text = text
        self.secondLine = secondLine
        self.secondLineTone = secondLineTone
        self.actions = actions
        self.busy = busy
        self.macName = macName
        var uses: [ToneUse] = []
        if secondLine != nil {
            uses.append(ToneUse(element: "relay banner second line", tone: secondLineTone, role: secondLineTone == .red ? .status : .info))
        }
        if !actions.isEmpty { uses.append(ToneUse(element: "relay banner actions", tone: .accent, role: .info)) }
        toneUses = uses
    }

    func title(for action: Action) -> String {
        switch action {
        case .switchToICloud: "Switch \(macName) to iCloud"
        case .subscribe: RelayCardModel.subscribe
        case .restore: RelayCardModel.restore
        case .ok: "OK"
        case .confirmPurchase: RelayCardModel.notConfirmedLine
        case .forget: Self.forgetThisMac
        }
    }

    // swiftlint:disable function_parameter_count
    /// First match wins: update the app, this hub relay-only and not paying, moved, ended, free on a relay Mac, relay
    /// unavailable. An unavailable relay shows the free-on-a-relay-Mac one only.
    static func banner(
        availability: RelayAvailability,
        phase: RelayAccountCenter.Phase,
        unconfirmedPurchase: Bool,
        updateRequired: Bool,
        wasPaying: Bool,
        route: HubRoute?,
        relayOnly: Bool,
        hubOnRelayAt: Date?,
        unansweredSince: Date?,
        request: TransportRequestRecord?,
        pressRefusal: TransportRequestRefusal?,
        lastUpdate: Date?,
        macName: String,
        now: Date,
        link: LinkRecord? = nil,
        termHold: RelayTermHold = .none
    ) -> Self? {
        let onRelayLine = lastUpdate.map { lastUpdateLine($0, macName: macName, now: now) }
        guard case .available = availability else {
            guard hubOnRelayAt != nil else { return nil }
            return Self(text: macOnRelay(macName, canSubscribe: false), secondLine: onRelayLine, macName: macName)
        }
        if updateRequired {
            // A phone that never paid has nothing to keep: S43's words.
            let goal = wasPaying ? "keep using" : "use"
            return Self(text: "Update Watchtower from the App Store to \(goal) Relay.", macName: macName)
        }
        if let link, let gone = linkGone(link, termHold: termHold, macName: macName, now: now) {
            return gone
        }
        let term = link.flatMap { termLine(for: $0, surface: .banner, now: now, heldPurchase: termHold) }
        let held = termHold == .held && link.map(RelayTerm.purchaseHolds) == true
        if relayOnly, let needs = needsRelay(
            phase, charged: unconfirmedPurchase, macName: macName,
            term: link?.relayRefused == nil ? nil : NeedsRelayTerm(line: term, held: held)
        ) {
            return needs
        }
        let onRelay = isOnRelay(route)
        let elapsed = unansweredSince.map { now.timeIntervalSince($0) } ?? 0
        let inOutage = elapsed >= unavailableAfter
        // On an outage the outage row says why nothing moves.
        if wasPaying, !(onRelay && inOutage),
           let lost = lost(phase, charged: unconfirmedPurchase, onRelay: onRelay, request: request, macName: macName) {
            return lost
        }
        if hubOnRelayAt != nil, let free = freeOnRelayMac(phase, charged: unconfirmedPurchase, line: onRelayLine, macName: macName) {
            return free
        }
        guard onRelay else { return nil }
        if inOutage {
            return outage(for: elapsed, relayOnly: relayOnly, request: request, pressRefusal: pressRefusal, macName: macName)
        }
        // The relay answers and the owner's press still goes on: the Mac moves, so say that alone. A lapse's request is S34b's,
        // and its OK has to end the banner.
        guard !relayOnly, let request, request.isOpen, request.reason != TransportFollowerPolicy.lapseReason else { return nil }
        return Self(text: switching, busy: true, macName: macName)
    }
    // swiftlint:enable function_parameter_count

    /// Whether the banner's words can change with no state changing: only an outage's do, and it shows only on a relay route
    /// that stopped answering. The view runs its clock on this alone, so a phone with no relay pays nothing recurring.
    static func needsClock(route: HubRoute?, unansweredSince: Date?) -> Bool {
        isOnRelay(route) && unansweredSince != nil
    }

    private static func isOnRelay(_ route: HubRoute?) -> Bool {
        if case .hostedRelay = route { return true }
        return false
    }

    /// A refused link's term on its needs-Relay banner (S61): the line, if any, and whether a held purchase gains
    /// **Restore Purchases** on `.free` (ask #1104).
    private struct NeedsRelayTerm {
        let line: String?
        let held: Bool
    }

    /// S47, S53: no **OK**, as the hub gets nothing until the owner pays or unlinks. A phone that never had a subscription, or
    /// has just been charged for one, is not told it ended. On a link the relay refuses, the term's line goes under it (S61).
    private static func needsRelay(_ phase: RelayAccountCenter.Phase, charged: Bool, macName: String, term: NeedsRelayTerm?) -> Self? {
        let needs = "\(macName) needs Relay."
        let line = term?.line
        let speaks = term != nil
        switch phase {
        case .moved:
            return Self(text: "\(needs) \(RelayCardModel.movedLine)", secondLine: line, actions: [.restore], speaksOfTerm: speaks, macName: macName)
        case .free where charged:
            return Self(text: needs, secondLine: line, actions: [.confirmPurchase], speaksOfTerm: speaks, macName: macName)
        case .free(let ended):
            let text = ended ? "\(needs) \(RelayCardModel.endedLine)" : needs
            let actions: [Action] = term?.held == true ? [.subscribe, .restore] : [.subscribe]
            return Self(text: text, secondLine: line, actions: actions, speaksOfTerm: speaks, macName: macName)
        case .checking, .unknown, .paying:
            return nil
        }
    }

    /// S59 (ask #1081): the phone left behind. Its Mac is in none of this phone's slots while the subscription stands
    /// (`relayRefused` `.slot`), or it read the Mac's move to iCloud (`macMoved`). Only a new link brings it back, so
    /// it says that, with **Forget This Mac**; the term's line goes under it when the link has one. No purchase holds
    /// either, so no held line.
    private static func linkGone(_ link: LinkRecord, termHold: RelayTermHold, macName: String, now: Date) -> Self? {
        guard link.transport == .relay, link.relayRefused?.cause == .slot || link.macMoved != nil else { return nil }
        return Self(
            text: "\(macName) can't be reached over Relay any more. Link this iPhone to it again.",
            secondLine: termLine(for: link, surface: .banner, now: now, heldPurchase: termHold),
            actions: [.forget], speaksOfTerm: true, macName: macName
        )
    }

    /// The term's line for a link the relay refuses (relay client Phase 5, Task 17, S61), on `surface`, in the secondary
    /// tone; nil for a link with no term (routed, never refused, or only moved). The date is `since` plus 21 days, fixed.
    /// A held purchase replaces it on a needs-Relay link (the cause `.lapse` with no known move); past the date, a row the
    /// relay refused for a reason not about the payment says why the link waits on Now's row and the Settings row, and
    /// nothing on the banner, whose own words say where that purchase stands. "Restore Purchases" is named only beside
    /// its button: on the banner.
    static func termLine(for link: LinkRecord, surface: TermSurface, now: Date, heldPurchase: RelayTermHold) -> String? {
        guard link.transport == .relay, let refused = link.relayRefused else { return nil }
        let mac = link.macName
        let needsRelay = RelayTerm.purchaseHolds(link)
        if needsRelay, heldPurchase == .held {
            let lead = "This iPhone paid, but Relay hasn't seen it."
            switch surface {
            case .banner: return "\(lead) Tap Restore Purchases to keep the link to \(mac)."
            case .now: return "\(lead) \(seeMacs)"
            case .macs: return "\(lead) \(openRelayCard)"
            }
        }
        let goes = "Its history and unsent actions on this iPhone will go."
        let date = RelayTerm.date(of: refused)
        guard now >= date else {
            return "If this stays as it is, the link to \(mac) ends on \(termDay(date)). \(goes)"
        }
        if needsRelay, heldPurchase == .refusedRow {
            let lead = "This iPhone paid, but Relay hasn't accepted it. The link to \(mac) stays while that purchase is current."
            switch surface {
            case .banner: return nil
            case .now: return "\(lead) \(seeMacs)"
            case .macs: return "\(lead) \(openRelayCard)"
            }
        }
        return "The link to \(mac) will end the next time this iPhone can confirm Relay still refuses it. \(goes)"
    }

    private static let seeMacs = "See Settings → Macs."
    private static let openRelayCard = "Open the Relay card on this screen."

    /// "December 14": the term's day, in the phone's calendar.
    private static func termDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = .current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: date)
    }

    /// S33, S34, and while this hub's route has not moved S41b and S34b: "back on iCloud" would be false until it does. Ended is
    /// not said while charged: nothing ended then. A move is the relay's own word, as on the card.
    private static func lost(
        _ phase: RelayAccountCenter.Phase, charged: Bool, onRelay: Bool, request: TransportRequestRecord?, macName: String
    ) -> Self? {
        switch phase {
        case .moved:
            if onRelay { return notMovedYet(RelayCardModel.movedLine, actions: [.restore, .ok], request, macName: macName) }
            return Self(
                text: "Your Relay subscription moved to another iPhone. This iPhone is back on iCloud.",
                actions: [.restore, .ok], macName: macName
            )
        case .free(ended: true) where !charged:
            let ended = "Your Relay subscription ended."
            guard onRelay else {
                return Self(text: "\(ended) This iPhone is back on iCloud.", actions: [.subscribe, .ok], macName: macName)
            }
            let text = request?.awaitsAnswer == true ? "\(ended) \(macName) moves to iCloud when it's back." : ended
            return notMovedYet(text, actions: [.subscribe, .ok], request, macName: macName)
        case .checking, .unknown, .free, .paying:
            return nil
        }
    }

    /// The route has not moved: a refusal says why it won't come, and the press stays, as on S50. A request the Mac can still
    /// answer has no line.
    private static func notMovedYet(_ text: String, actions: [Action], _ request: TransportRequestRecord?, macName: String) -> Self {
        guard request?.awaitsAnswer != true, let refusal = request?.refusal else {
            return Self(text: text, actions: actions, macName: macName)
        }
        return Self(
            text: text, secondLine: refusal.message(macName: macName), secondLineTone: .red,
            actions: [.switchToICloud] + actions, macName: macName
        )
    }

    /// S30, or S51's sentence where nothing says this phone can subscribe: not read yet, or just charged.
    private static func freeOnRelayMac(_ phase: RelayAccountCenter.Phase, charged: Bool, line: String?, macName: String) -> Self? {
        if case .paying = phase { return nil }
        let knownFree: Bool
        switch phase {
        case .free, .moved: knownFree = true
        case .checking, .unknown, .paying: knownFree = false
        }
        let canSubscribe = knownFree && !charged
        let actions: [Action] = charged ? [.confirmPurchase] : canSubscribe ? [.subscribe] : []
        return Self(text: macOnRelay(macName, canSubscribe: canSubscribe), secondLine: line, actions: actions, macName: macName)
    }

    private static func macOnRelay(_ macName: String, canSubscribe: Bool) -> String {
        let lead = "\(macName) runs over Relay. This iPhone doesn't get updates from it."
        return canSubscribe
            ? "\(lead) Subscribe or switch the Mac to iCloud from a subscribed phone."
            : "\(lead) Switch the Mac to iCloud from a subscribed phone."
    }

    /// S31, S32, S36, S50. The offer needs a hub with iCloud to go to; a lapse's kept copy (`awaitsAnswer` after its day)
    /// promises the move, so it has nothing to press.
    private static func outage(
        for elapsed: TimeInterval,
        relayOnly: Bool,
        request: TransportRequestRecord?,
        pressRefusal: TransportRequestRefusal?,
        macName: String
    ) -> Self {
        let text = "Relay unavailable for \(Int(elapsed / 60)) min. Your changes wait on this iPhone."
        if relayOnly { return Self(text: text, macName: macName) }
        if let request, request.isOpen {
            return Self(text: text, secondLine: switching, busy: true, macName: macName)
        }
        if let refusal = request?.refusal ?? pressRefusal {
            let waits = refusal == .lapseNoAnswer
            return Self(
                text: text, secondLine: refusal.message(macName: macName), secondLineTone: waits ? .secondary : .red,
                actions: waits ? [] : [.switchToICloud], macName: macName
            )
        }
        return Self(text: text, actions: elapsed >= offerAfter ? [.switchToICloud] : [], macName: macName)
    }

    /// "10:41" today; an older clock alone would read as today's.
    private static func lastUpdateLine(_ date: Date, macName: String, now: Date) -> String {
        let calendar = Calendar.current
        let format = RecordingsFormat(calendar: calendar, now: now)
        let moment = calendar.isDate(date, inSameDayAs: now) ? format.clock(date) : format.when(date)
        return "Last update from \(macName): \(moment)"
    }
}

/// A press on the banner, apart from the view. Returns the work it started, for a test to await; its value is what the row
/// may not say: a request refused before anything was written, a failed write included. It shows only in an outage on a relay
/// route, so a call with nothing to ask (`.unavailable` on an iCloud route) cannot show a false line.
@MainActor
enum RelayBannerPress {
    @discardableResult
    static func run(
        _ action: RelayBannerModel.Action,
        session: HubSession?,
        center: RelayAccountCenter?,
        open: () -> Void,
        forget: () -> Void = {}
    ) -> Task<TransportRequestRefusal?, Never>? {
        switch action {
        case .forget:
            forget()
            return nil
        case .subscribe, .confirmPurchase:
            open()
            return nil
        case .restore:
            let restore = RelaySubscriptionPress.restore(center: center, open: open)
            return Task {
                await restore.value
                return nil
            }
        case .ok:
            center?.clearWasPaying()
            return nil
        case .switchToICloud:
            guard let session else { return nil }
            return Task { await switchToICloud(session, center: center) }
        }
    }

    /// **Try Again** on a refused request keeps the record's reason, as the Connection section's does.
    private static func switchToICloud(_ session: HubSession, center: RelayAccountCenter?) async -> TransportRequestRefusal? {
        let reason = session.transportRequest.flatMap { $0.isOpen ? nil : $0.reason } ?? center?.switchReason
        return await session.requestTransport(reason: reason).refusal
    }
}
