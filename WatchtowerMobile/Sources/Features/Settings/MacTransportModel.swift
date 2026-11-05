import Foundation
import WatchtowerHostedRelay
import WatchtowerSync

/// A Mac's Connection section (relay client Phase 4 Task 8, mockup S08–S19, S49, S52, S54, S56): the per-Mac choice between
/// iCloud and Relay, first match wins (`Decision`). Every text lives here (or on the refusals' own `message`) and is
/// asserted in `MacTransportModelTests`. The state comes from the hub's row, so a relaunch shows the same frame.
struct MacTransportModel: Equatable {
    struct Row: Equatable {
        let kind: TransportKind
        let title: String
        let line: String?
        let chosen: Bool
        let enabled: Bool
        let action: Action?
        /// The switch runs toward this row.
        var busy = false
    }

    enum Action: Equatable {
        case chooseRelay, chooseICloud, openSubscription, manageMacs, tryAgain
    }

    static let sectionTitle = "Connection"
    static let relayTitle = "Relay"
    static let iCloudTitle = "iCloud"
    static let forgetTitle = "Forget This Mac"
    static let relayLine = "Instant, encrypted end to end"
    static let iCloudLine = "Free, slower"
    static let relayOnly = "This hub works over Relay only"
    static let needsRelay = "This hub needs Relay"
    static let checking = "Checking…"
    static let needsUpdate = "Update Watchtower on this Mac to use Relay"
    static let notConfirmed = "Your purchase isn't confirmed yet."
    static let subscribe = "Subscribe to use Relay"
    static let unreachable = "Couldn't reach Relay."
    static let switchingToRelay = "Switching to Relay…"
    static let switchingToICloud = "Switching to iCloud…"
    static let appliesToEveryPhone = "Applies to every phone of this Mac."

    static func slotsFull(_ limit: Int) -> String { "Your subscription already has \(limit) Macs." }
    static func gettingReady(_ macName: String) -> String { "Getting \(macName) ready…" }
    static func waitingFor(_ macName: String) -> String { "Waiting for \(macName). It switches when it's back." }

    /// The link row's title under a row's line; nil when the row itself is the press.
    static func title(for action: Action) -> String? {
        switch action {
        case .tryAgain: "Try Again"
        case .manageMacs: "Manage Macs"
        case .chooseRelay, .chooseICloud, .openSubscription: nil
        }
    }

    /// Empty on an unavailable relay: there is no screen then (`MacsView.opensDetail`).
    let rows: [Row]
    let footnote: String?
    let busyLine: String?
    let toneUses: [ToneUse]

    init(
        link: LinkRecord,
        grant: DeviceGrant?,
        phase: RelayAccountCenter.Phase,
        unconfirmedPurchase: Bool,
        availability: RelayAvailability,
        session: SessionTransportFacts,
        macName: String,
        ownDeviceID: String?,
        now: Date
    ) {
        guard case .available = availability else {
            rows = []
            footnote = nil
            busyLine = nil
            toneUses = []
            return
        }
        let choice = Decision(
            link: link, grant: grant, phase: phase, unconfirmedPurchase: unconfirmedPurchase, session: session,
            macName: macName, ownDeviceID: ownDeviceID, now: now
        ).choice
        rows = choice.rows
        footnote = choice.footnote
        busyLine = choice.busyLine
        toneUses = Self.tones(choice)
    }

    private static func tones(_ choice: Choice) -> [ToneUse] {
        var uses: [ToneUse] = choice.rows.compactMap { row in
            guard row.line != nil else { return nil }
            let tone: PhoneTone = choice.failing == row.kind ? .red : .secondary
            return ToneUse(element: "connection \(row.title) line", tone: tone, role: .info)
        }
        if choice.rows.contains(where: \.chosen) {
            uses.append(ToneUse(element: "connection choice mark", tone: .accent, role: .info))
        }
        if choice.rows.contains(where: { $0.action.flatMap(title(for:)) != nil }) {
            uses.append(ToneUse(element: "connection action", tone: .accent, role: .info))
        }
        return uses
    }

    /// A line's tone, as `toneUses` declares it.
    func tone(of row: Row) -> PhoneTone {
        toneUses.first { $0.element == "connection \(row.title) line" }?.tone ?? .secondary
    }

    private struct Choice {
        let rows: [Row]
        var footnote: String?
        var busyLine: String?
        /// The row whose line reports a failure (red).
        var failing: TransportKind?
    }

    /// The decision table of Task 8's brief, one rule per method, in its order. A rule returns nil when it does not
    /// match. The rules that name one route only read a record on that route: a record left from before a move paints
    /// nothing.
    private struct Decision {
        let link: LinkRecord
        let grant: DeviceGrant?
        let phase: RelayAccountCenter.Phase
        let unconfirmedPurchase: Bool
        let session: SessionTransportFacts
        let macName: String
        let ownDeviceID: String?
        let now: Date

        private var onRelay: Bool { link.transport == .relay }

        private var paying: Bool {
            if case .paying = phase { return true }
            return false
        }

        private var notPaying: Bool {
            switch phase {
            case .free, .moved: true
            case .checking, .unknown, .paying: false
            }
        }

        private var isRelayOnly: Bool {
            let cloudKit = TransportKind.cloudKit.rawValue
            return link.hubTransports?.contains(cloudKit) == false || grant?.transports?.contains(cloudKit) == false
        }

        var choice: Choice {
            relayOnlyRule() ?? refusedRequestRule() ?? openRequestRule() ?? upgradeRule() ?? checkingRule()
                ?? keptRefusalRule() ?? grantRule() ?? unconfirmedRule() ?? accountRule() ?? slotsRule() ?? settledRule()
        }

        private func relayOnlyRule() -> Choice? {
            guard isRelayOnly else { return nil }
            let line = notPaying ? MacTransportModel.needsRelay : MacTransportModel.relayOnly
            return Choice(rows: [relayRow(line: line, chosen: !notPaying)])
        }

        private func refusedRequestRule() -> Choice? {
            guard onRelay, let request = session.request, let refusal = request.refusal else { return nil }
            // A lapse's copy still waits for the Mac: the line promises the move, and there is nothing to press.
            let waits = refusal == .lapseNoAnswer
            return Choice(
                rows: [
                    relayRow(chosen: true),
                    iCloudRow(line: refusal.message(macName: macName), enabled: !waits, action: waits ? nil : .tryAgain)
                ],
                failing: waits ? nil : .cloudKit
            )
        }

        private func openRequestRule() -> Choice? {
            guard onRelay, session.request?.isOpen == true else { return nil }
            return Choice(
                rows: [relayRow(), iCloudRow(line: MacTransportModel.iCloudLine, busy: true)],
                busyLine: session.macReachable ? MacTransportModel.switchingToICloud : MacTransportModel.waitingFor(macName)
            )
        }

        private func upgradeRule() -> Choice? {
            guard !onRelay, let step = session.upgradeStep, step != .switched else { return nil }
            let rows = [relayRow(busy: true), iCloudRow(line: MacTransportModel.iCloudLine)]
            guard session.macReachable else { return Choice(rows: rows, busyLine: MacTransportModel.waitingFor(macName)) }
            return Choice(
                rows: rows, footnote: MacTransportModel.gettingReady(macName), busyLine: MacTransportModel.switchingToRelay
            )
        }

        private func checkingRule() -> Choice? {
            guard phase == .checking else { return nil }
            if onRelay {
                return Choice(rows: [
                    relayRow(line: MacTransportModel.checking, chosen: true),
                    iCloudRow(line: MacTransportModel.iCloudLine, enabled: true, action: .chooseICloud)
                ])
            }
            return Choice(rows: [
                relayRow(line: MacTransportModel.checking),
                iCloudRow(line: MacTransportModel.checking, chosen: true, enabled: true)
            ])
        }

        /// A refusal whose line would now be false or whose button could only be refused again (slots freed since, the
        /// subscription gone) falls through to the state underneath, which says what helps.
        private func keptRefusalRule() -> Choice? {
            guard !onRelay, let refusal = session.upgradeRefusal else { return nil }
            if refusal == .vouch(.slotsFull) { return slotsRule() }
            guard let message = refusal.message(macName: macName, now: now) else { return nil }
            switch refusal {
            case .tooSoon(let retryAt):
                guard now < retryAt else { return nil }
                return Choice(rows: [relayRow(line: message), chosenICloud], footnote: refusal.footnote)
            case .notPaying, .vouch(.notPaying):
                if notPaying { return nil }
            default:
                break
            }
            return Choice(
                rows: [relayRow(line: message, enabled: true, action: .tryAgain), chosenICloud], failing: .relay
            )
        }

        private func grantRule() -> Choice? {
            guard !onRelay else { return nil }
            guard let grant else {
                // Not read (a locked keychain): nothing proves the Mac old.
                return Choice(rows: [relayRow(line: MacTransportModel.checking), chosenICloud])
            }
            let coherent = grant.relayDeviceID.flatMap { mac in
                grant.relayAuthPub.map { LinkPayload.relayIdentityIsCoherent(deviceID: mac, authPub: $0) }
            } ?? false
            guard !grant.runsOrderedActions || !coherent else { return nil }
            return Choice(rows: [relayRow(line: MacTransportModel.needsUpdate), chosenICloud])
        }

        private func unconfirmedRule() -> Choice? {
            guard !onRelay, unconfirmedPurchase else { return nil }
            switch phase {
            case .free, .unknown:
                return Choice(rows: [
                    relayRow(line: MacTransportModel.notConfirmed, enabled: true, action: .openSubscription), chosenICloud
                ])
            case .checking, .paying, .moved:
                return nil
            }
        }

        private func accountRule() -> Choice? {
            guard !onRelay else { return nil }
            if notPaying {
                return Choice(rows: [
                    relayRow(line: MacTransportModel.subscribe, enabled: true, action: .openSubscription),
                    iCloudRow(line: MacTransportModel.iCloudLine, chosen: true, enabled: true)
                ])
            }
            guard phase == .unknown else { return nil }
            return Choice(rows: [relayRow(line: MacTransportModel.unreachable), chosenICloud], failing: .relay)
        }

        private func slotsRule() -> Choice? {
            guard !onRelay, case .paying(_, let macs) = phase, macs.count >= HostedRelayLimits.maxMacSlots else { return nil }
            if let mac = grant?.relayDeviceID, macs.contains(mac) { return nil }
            return Choice(rows: [
                relayRow(line: MacTransportModel.slotsFull(HostedRelayLimits.maxMacSlots), enabled: true, action: .manageMacs), chosenICloud
            ])
        }

        /// Paying on iCloud (S09), or on the relay whatever the account says (S08): the way back stays open.
        private func settledRule() -> Choice {
            let footnote = MacTransportModel.footnote(link, ownDeviceID: ownDeviceID, now: now)
            if onRelay {
                return Choice(
                    rows: [
                        relayRow(chosen: true, enabled: true),
                        iCloudRow(line: MacTransportModel.iCloudLine, enabled: true, action: .chooseICloud)
                    ],
                    footnote: footnote
                )
            }
            return Choice(
                rows: [
                    relayRow(enabled: true, action: .chooseRelay),
                    iCloudRow(line: MacTransportModel.iCloudLine, chosen: true, enabled: true)
                ],
                footnote: footnote
            )
        }

        private var chosenICloud: Row { iCloudRow(line: nil, chosen: true, enabled: true) }

        private func relayRow(
            line: String = MacTransportModel.relayLine, chosen: Bool = false, enabled: Bool = false, action: Action? = nil, busy: Bool = false
        ) -> Row {
            Row(kind: .relay, title: MacTransportModel.relayTitle, line: line, chosen: chosen, enabled: enabled, action: action, busy: busy)
        }

        private func iCloudRow(
            line: String?, chosen: Bool = false, enabled: Bool = false, action: Action? = nil, busy: Bool = false
        ) -> Row {
            Row(kind: .cloudKit, title: MacTransportModel.iCloudTitle, line: line, chosen: chosen, enabled: enabled, action: action, busy: busy)
        }
    }

    /// "Applies to every phone of this Mac.", then who changed it last and when, when anyone did.
    private static func footnote(_ link: LinkRecord, ownDeviceID: String?, now: Date) -> String {
        guard let who = MacsModel.switchedByText(link, ownDeviceID: ownDeviceID) else { return appliesToEveryPhone }
        guard let at = link.switchedAt else { return "\(appliesToEveryPhone) Last changed \(who)." }
        let moment = RecordingsFormat(calendar: .current, now: now).inSentence(at)
        return "\(appliesToEveryPhone) Last changed \(who) \(moment)."
    }
}

/// What the row and the replica say about a Mac's switch: rebuilt from them, so a restart shows the same frame.
struct SessionTransportFacts: Equatable {
    let upgradeStep: RelayUpgradeStep?
    let upgradeRefusal: RelayUpgradeRefusal?
    let request: TransportRequestRecord?
    let macReachable: Bool
}

extension SessionTransportFacts {
    /// A locked keychain proves nothing, so it reads as reachable: the row says "Switching…" and never blames the Mac.
    static func macReachable(_ reachability: DesktopReachability) -> Bool {
        reachability != .unreachable
    }

    /// `pressedRelay`: the owner's press is running and its first decision is not on the row yet.
    init(link: LinkRecord, store: ReplicaStore, now: Date, pressedRelay: Bool = false) {
        let upgrade = link.relayUpgrade
        let pending = upgrade?.isPending == true ? upgrade?.step : nil
        self.init(
            upgradeStep: pending ?? (pressedRelay ? .namingRelayID : nil),
            upgradeRefusal: pressedRelay ? nil : upgrade?.refusal,
            request: link.transportRequest,
            macReachable: Self.macReachable(RelayFeed.desktopReachability(store: store, now: now))
        )
    }
}

/// A press on the Connection section, apart from the view. The state it leaves is on the hub's row, which the model reads:
/// `requestTransport`'s `.refused(.unavailable)` on a call with nothing to ask is no failure and shows nothing.
@MainActor
enum MacTransportPress {
    /// `.openSubscription` and `.manageMacs` open a screen: the view's.
    static func run(_ action: MacTransportModel.Action, session: HubSession, center: RelayAccountCenter?) async {
        switch action {
        case .chooseRelay:
            await upgrade(session, center)
        case .chooseICloud:
            _ = await session.requestTransport(reason: center?.switchReason)
        case .tryAgain:
            if let request = session.transportRequest, !request.isOpen {
                _ = await session.requestTransport(reason: request.reason)
            } else {
                await upgrade(session, center)
            }
        case .openSubscription, .manageMacs:
            break
        }
    }

    /// An upgrade that decided nothing (the relay did not answer) goes on by itself at the next pass, and its row has
    /// nothing to show: reading the account again makes the row say so when the relay really is out.
    private static func upgrade(_ session: HubSession, _ center: RelayAccountCenter?) async {
        if await session.upgradeToRelay() == .waiting {
            await center?.refresh()
        }
    }
}
