import Foundation

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

    /// `List.onMove`'s `destination` (an offset in the list before the move)
    /// as the registry index of the moved row; nil when it stays in place.
    static func targetIndex(from: Int, destination: Int) -> Int? {
        let target = destination > from ? destination - 1 : destination
        return target == from ? nil : target
    }
}
