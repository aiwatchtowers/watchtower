import Foundation
import WatchtowerSync

/// Settings → Macs' decisions, apart from the view (multi-hub spec §5.6).
enum MacsModel {
    enum Action: Equatable {
        case unlink
        case forget
    }

    /// One destructive action per row: Forget for a Mac that removed this
    /// phone or is long offline, else Unlink.
    static func action(for item: HubListItem) -> Action {
        item.removedByMac || item.canForget ? .forget : .unlink
    }

    /// The confirmation of `action` on one Mac.
    struct Ask: Identifiable, Equatable {
        let action: Action
        let hubID: String
        let name: String
        let removedByMac: Bool

        init(action: Action, item: HubListItem) {
            self.action = action
            hubID = item.id
            name = item.name
            removedByMac = item.removedByMac
        }

        /// S59's **Forget This Mac** on Now (relay client Phase 5, Task 17): the Forget of a linked Mac.
        init(forgetting hubID: String, name: String) {
            action = .forget
            self.hubID = hubID
            self.name = name
            removedByMac = false
        }

        var id: String { "\(action)-\(hubID)" }

        var title: String {
            switch action {
            case .unlink: "Unlink \(name)?"
            case .forget: "Forget \(name)?"
            }
        }

        var button: String {
            action == .unlink ? "Unlink" : "Forget"
        }

        var message: String {
            switch action {
            case .unlink: "This phone forgets the Mac's data. Changes still waiting for the Mac are not sent."
            case .forget where removedByMac: "Its data on this iPhone is deleted."
            case .forget: "This unlinks the Mac and deletes its data on this iPhone."
            }
        }
    }

    // MARK: - Confirmed Relay links still finishing (relay client Phase 3 Task 10, mockup 7.4)

    /// One confirmed Relay link still finishing, as its Settings → Macs row shows it.
    struct FinishingRow: Identifiable, Equatable {
        enum Status: Equatable {
            /// An attempt is running: no actions.
            case busy
            /// Waiting for the next attempt (launch, foreground) with no failure yet.
            case finishing
            /// The last attempt failed without a definite answer.
            case failed
            /// A definite refusal: the owner decides.
            case needsOwner(PromotedLink.Reason)
        }

        enum Action: Equatable {
            case manageMacs
            case tryAgain
            case cancel

            var title: String {
                switch self {
                case .manageMacs: "Manage Macs"
                case .tryAgain: "Try Again"
                case .cancel: "Cancel"
                }
            }
        }

        /// The hub id.
        let id: String
        let name: String
        let status: Status

        var line: String {
            switch status {
            case .busy, .finishing: "Finishing the link…"
            case .failed: "Couldn't finish the link. Watchtower tries again when it opens."
            case let .needsOwner(reason): reason.message(macName: name)
            }
        }

        /// Under the line while busy.
        var note: String? {
            status == .busy ? "No actions while an attempt runs." : nil
        }

        var showsProgress: Bool { status == .busy }

        var actions: [Action] {
            switch status {
            case .busy: []
            case .needsOwner(.slotsFull): [.manageMacs, .tryAgain, .cancel]
            case .finishing, .failed, .needsOwner: [.tryAgain, .cancel]
            }
        }

        /// The row's colours (spec §14: never orange).
        var toneUses: [ToneUse] {
            [ToneUse(element: "finishing link \(id) icon", tone: .secondary, role: .mac)]
        }
    }

    /// The finishing rows, oldest link first: `running` hubs are busy, `failed` ones show the retry line.
    static func finishingRows(_ promoted: [PromotedLink], running: Set<String>, failed: Set<String>) -> [FinishingRow] {
        promoted.map { link in
            let status: FinishingRow.Status
            if running.contains(link.hubID) {
                status = .busy
            } else if case let .needsOwner(reason) = link.state {
                status = .needsOwner(reason)
            } else {
                status = failed.contains(link.hubID) ? .failed : .finishing
            }
            return FinishingRow(id: link.hubID, name: link.macName, status: status)
        }
    }

    /// The cancel confirmation of a finishing link (Settings → Macs and the slots screen).
    static func cancelQuestion(_ name: String) -> String {
        "Cancel the link to \(name)? It frees its Relay slot."
    }

    static let cancelLink = "Cancel Link"
    static let keepTrying = "Keep Trying"

    /// `List.onMove`'s `destination` (an offset in the list before the move)
    /// as the registry index of the moved row; nil when it stays in place.
    static func targetIndex(from: Int, destination: Int) -> Int? {
        let target = destination > from ? destination - 1 : destination
        return target == from ? nil : target
    }

    /// `List.onMove` over `items` (`HubListModel.items`, in the registry's
    /// order, unreadable rows in their places) as the moved Mac and its new
    /// registry index; nil when nothing moves.
    static func registryMove(_ items: [HubListItem], from source: IndexSet, to destination: Int) -> (hubID: String, index: Int)? {
        guard let from = source.first, items.indices.contains(from),
              let to = targetIndex(from: from, destination: destination) else { return nil }
        return (items[from].id, to)
    }

    // MARK: - Each Mac's transport line (relay client Phase 4 Task 7, mockup S07)

    /// The hub writes the asking phone's grant device id (`b.id.String()`, lower-case, matched by parsed UUID on its side);
    /// a link keeps the id as the phone wrote it (`UUID.uuidString`, upper-case): compare as UUIDs.
    private static func sameDevice(_ by: String, _ own: String?) -> Bool {
        guard let own else { return false }
        if let a = UUID(uuidString: by), let b = UUID(uuidString: own) { return a == b }
        return by == own
    }

    /// Who changed the Mac's transport last, inside the Connection footnote's sentence; nil when nobody did. A move
    /// for a lapse (`entitlement_expired`) is told only to a phone whose own subscription ended or moved
    /// (`subscriptionEnded`): a paying phone, or one that never subscribed, is not told it ended (nil).
    static func switchedByText(_ link: LinkRecord, ownDeviceID: String?, subscriptionEnded: Bool) -> String? {
        guard let by = link.switchedBy, !by.isEmpty else { return nil }
        if by == TransportFollowerPolicy.lapseReason { return subscriptionEnded ? "when your subscription ended" : nil }
        return sameDevice(by, ownDeviceID) ? "by this iPhone" : "by another iPhone"
    }

    /// "iCloud" or "Relay", then who switched it last and when ("switched by this iPhone, Today 10:42"); "your
    /// subscription ended" when the hub moved for a lapse and this phone's own subscription ended or moved
    /// (`subscriptionEnded`; a paying phone or one that never subscribed reads the plain name); "Switching…" while an
    /// upgrade or a request runs. Another phone's device id never shows: only "this iPhone" or "another iPhone".
    static func transportLine(
        _ link: LinkRecord, ownDeviceID: String?, inFlight: Bool, subscriptionEnded: Bool, now: Date
    ) -> String {
        if inFlight { return "Switching…" }
        let name = link.transport == .relay ? "Relay" : "iCloud"
        guard let by = link.switchedBy, !by.isEmpty else { return name }
        let who: String
        if by == TransportFollowerPolicy.lapseReason {
            guard subscriptionEnded else { return name }
            who = "your subscription ended"
        } else {
            who = sameDevice(by, ownDeviceID) ? "switched by this iPhone" : "switched by another iPhone"
        }
        guard let at = link.switchedAt else { return "\(name) · \(who)" }
        return "\(name) · \(who), \(RecordingsFormat(calendar: .current, now: now).when(at))"
    }
}
