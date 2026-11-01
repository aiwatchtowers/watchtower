import Foundation
import WatchtowerHostedRelay

/// The three-slots screen (relay spec §8, mockup sections 6 and 7.3): the relay account already holds
/// `HostedRelayLimits.maxMacSlots` Macs, so a new Mac links over Relay only after one is removed. No iCloud option:
/// the Mac being added runs over Relay. Every line of copy is here.
struct RelaySlotsModel: Equatable {
    /// What Remove does for a Mac in a slot.
    enum Kind: Equatable {
        /// Linked on this iPhone: its whole unlink (farewell, then `remove_slot`), after the unlink confirmation.
        case linkedHere(hubID: String)
        /// A confirmed link still finishing: its cancel path, after the cancel confirmation.
        case finishing(hubID: String)
        /// A Mac not on this iPhone: `remove_slot` only.
        case unknown
    }

    enum Action: Equatable {
        case remove
        case removing
        case tryAgain

        var title: String {
            switch self {
            case .remove: "Remove"
            case .removing: "Removing…"
            case .tryAgain: "Try Again"
            }
        }
    }

    struct Row: Identifiable, Equatable {
        /// The Mac's relay device id.
        let id: String
        let name: String
        /// "Finishing link" for a confirmed link still finishing.
        let sub: String?
        let kind: Kind
        let action: Action
        /// Another row's removal is running.
        let isDisabled: Bool
    }

    /// A row's name, sub line and kind kept while its removal runs or after it failed.
    struct Pinned: Equatable {
        let name: String
        let sub: String?
        let kind: Kind
    }

    /// The confirmation before a Remove (none for a Mac not on this iPhone).
    struct Ask: Identifiable, Equatable {
        let mac: String
        let title: String
        let message: String?
        let confirm: String
        let keep: String

        var id: String { mac }
    }

    static let navigationTitle = "Add Mac"
    static let cancelTitle = "Cancel"
    static let footnote = "Up to \(replacementsPer30Days) replacements in 30 days."
    static let failedTitle = "Couldn't remove the Mac. Try again."
    static let unknownMacName = "A Mac not on this iPhone"
    static let finishingSub = "Finishing link"
    /// The relay's replacement limit (Worker `slotReplacementsPer30Days`).
    static let replacementsPer30Days = 5

    let title: String
    let rows: [Row]
    let isLoading: Bool

    var footnote: String { Self.footnote }

    /// `state` from the link flow; each Mac named from the registry (its `relayMacDeviceID`), else from a confirmed
    /// link still finishing, else "A Mac not on this iPhone".
    init(state: RelaySlotsState, links: [HubRow], promoted: [PromotedLink]) {
        title = state.failed == nil
            ? "Your subscription already has \(HostedRelayLimits.maxMacSlots) Macs. Remove one to add this Mac over Relay."
            : Self.failedTitle
        isLoading = state.loading
        rows = state.macs.map { mac in
            let kind: Kind
            let name: String
            var sub: String?
            if let pinned = state.pinned[mac] {
                kind = pinned.kind
                name = pinned.name
                sub = pinned.sub
            } else if let row = links.first(where: { $0.link.relayMacDeviceID == mac }) {
                kind = .linkedHere(hubID: row.hubID)
                name = row.link.macName
            } else if let link = promoted.first(where: { $0.macDeviceID == mac }) {
                kind = .finishing(hubID: link.hubID)
                name = link.macName
                sub = Self.finishingSub
            } else {
                kind = .unknown
                name = Self.unknownMacName
            }
            let action: Action = state.removing == mac ? .removing : state.failed == mac ? .tryAgain : .remove
            return Row(
                id: mac, name: name, sub: sub, kind: kind, action: action,
                isDisabled: state.removing != nil && state.removing != mac
            )
        }
    }

    /// The screen's colours (spec §14: never orange): the Mac icons and the actions.
    var toneUses: [ToneUse] {
        rows.flatMap { row in
            [
                ToneUse(element: "slot \(row.id) icon", tone: .secondary, role: .mac),
                ToneUse(element: "slot \(row.id) action", tone: .accent, role: .info)
            ]
        }
    }

    /// The confirmation `row`'s Remove asks first; nil asks nothing (and a Try Again, whose removal was confirmed).
    static func ask(for row: Row) -> Ask? {
        guard row.action == .remove else { return nil }
        switch row.kind {
        case .linkedHere:
            return Ask(
                mac: row.id, title: "Unlink \(row.name)?",
                message: "This phone forgets the Mac's data. Changes still waiting for the Mac are not sent.",
                confirm: "Unlink", keep: "Cancel"
            )
        case .finishing:
            return Ask(mac: row.id, title: MacsModel.cancelQuestion(row.name), message: nil, confirm: MacsModel.cancelLink, keep: MacsModel.keepTrying)
        case .unknown:
            return nil
        }
    }
}
