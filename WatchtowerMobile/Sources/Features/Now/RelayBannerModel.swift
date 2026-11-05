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
    }

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
    private let macName: String

    private init(
        text: String,
        secondLine: String? = nil,
        secondLineTone: PhoneTone = .secondary,
        actions: [Action] = [],
        busy: Bool = false,
        macName: String
    ) {
        self.text = text
        self.secondLine = secondLine
        self.secondLineTone = secondLineTone
        self.actions = actions
        self.busy = busy
        self.macName = macName
        var uses: [ToneUse] = []
        if secondLine != nil { uses.append(ToneUse(element: "relay banner second line", tone: secondLineTone, role: .info)) }
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
        now: Date
    ) -> Self? {
        let onRelayLine = lastUpdate.map { lastUpdateLine($0, macName: macName, now: now) }
        guard case .available = availability else {
            guard hubOnRelayAt != nil else { return nil }
            return Self(text: macOnRelay(macName, canSubscribe: false), secondLine: onRelayLine, macName: macName)
        }
        if updateRequired {
            return Self(text: "Update Watchtower from the App Store to keep using Relay.", macName: macName)
        }
        if relayOnly, let needs = needsRelay(phase, charged: unconfirmedPurchase, macName: macName) {
            return needs
        }
        // A lapse's move waits for the Mac: until the route moves, "back on iCloud" would be false.
        if wasPaying, !isOnRelay(route), let lost = lost(phase, charged: unconfirmedPurchase, macName: macName) {
            return lost
        }
        if hubOnRelayAt != nil, let free = freeOnRelayMac(phase, charged: unconfirmedPurchase, line: onRelayLine, macName: macName) {
            return free
        }
        guard isOnRelay(route), let unansweredSince else { return nil }
        return outage(
            for: now.timeIntervalSince(unansweredSince), relayOnly: relayOnly, request: request, pressRefusal: pressRefusal, macName: macName
        )
    }
    // swiftlint:enable function_parameter_count

    private static func isOnRelay(_ route: HubRoute?) -> Bool {
        if case .hostedRelay = route { return true }
        return false
    }

    /// S47, S53: no **OK**, as the hub gets nothing until the owner pays or unlinks. A phone that never had a subscription, or
    /// has just been charged for one, is not told it ended.
    private static func needsRelay(_ phase: RelayAccountCenter.Phase, charged: Bool, macName: String) -> Self? {
        let needs = "\(macName) needs Relay."
        switch phase {
        case .moved:
            return Self(text: "\(needs) \(RelayCardModel.movedLine)", actions: [.restore], macName: macName)
        case .free where charged:
            return Self(text: needs, actions: [.confirmPurchase], macName: macName)
        case .free(ended: true):
            return Self(text: "\(needs) \(RelayCardModel.endedLine)", actions: [.subscribe], macName: macName)
        case .free(ended: false):
            return Self(text: needs, actions: [.subscribe], macName: macName)
        case .checking, .unknown, .paying:
            return nil
        }
    }

    /// S33, S34.
    private static func lost(_ phase: RelayAccountCenter.Phase, charged: Bool, macName: String) -> Self? {
        switch phase {
        case .moved:
            Self(
                text: "Your Relay subscription moved to another iPhone. This iPhone is back on iCloud.",
                actions: [.restore, .ok], macName: macName
            )
        case .free(ended: true) where !charged:
            Self(text: "Your Relay subscription ended. This iPhone is back on iCloud.", actions: [.subscribe, .ok], macName: macName)
        case .checking, .unknown, .free, .paying:
            nil
        }
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
    ) -> Self? {
        guard elapsed >= unavailableAfter else { return nil }
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
/// cannot say: a request refused before anything was written. `.unavailable` there means nothing to ask, no failure.
@MainActor
enum RelayBannerPress {
    @discardableResult
    static func run(
        _ action: RelayBannerModel.Action, session: HubSession?, center: RelayAccountCenter?, open: () -> Void
    ) -> Task<TransportRequestRefusal?, Never>? {
        switch action {
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
        let outcome = await session.requestTransport(reason: reason)
        return outcome == .refused(.notOrdered) ? .notOrdered : nil
    }
}
