import Foundation
import Observation
import os

/// Which groups and lanes the owner opened or folded on one workbench's
/// board under All (#1781). Groups start folded, lanes open except Backlog
/// and Done; only the owner's flips are stored.
struct BoardFolds: Codable, Equatable {
    /// Groups the owner opened.
    var openGroups: Set<Int64> = []
    /// Lanes the owner flipped, by `BoardLane.id`: true = open.
    var lanes: [String: Bool] = [:]

    func isGroupOpen(_ id: Int64) -> Bool {
        openGroups.contains(id)
    }

    func isLaneOpen(_ lane: BoardLane) -> Bool {
        lanes[lane.id] ?? !lane.isFoldedByDefault
    }

    mutating func toggleGroup(_ id: Int64) {
        if openGroups.remove(id) == nil { openGroups.insert(id) }
    }

    mutating func toggleLane(_ lane: BoardLane) {
        lanes[lane.id] = !isLaneOpen(lane)
    }
}

/// The phone's fold memory for every board, one UserDefaults entry per hub
/// (`key(hubID:)`, removed with the hub's other choices,
/// `DeviceSettings.removeChoices`). Phone-local and written only by the
/// board view: last write wins. An unreadable entry reads as no flips.
@MainActor
@Observable
final class BoardFoldStore {
    private var byHub: [String: [Int64: BoardFolds]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    nonisolated static func key(hubID: String?) -> String {
        "board.folds.\(hubID ?? "none")"
    }

    func folds(hubID: String?, workbenchID: Int64) -> BoardFolds {
        load(hubID)[workbenchID] ?? BoardFolds()
    }

    func update(hubID: String?, workbenchID: Int64, _ change: (inout BoardFolds) -> Void) {
        var hub = load(hubID)
        change(&hub[workbenchID, default: BoardFolds()])
        byHub[hubID ?? ""] = hub
        let stored = Dictionary(uniqueKeysWithValues: hub.map { (String($0.key), $0.value) })
        do {
            defaults.set(try JSONEncoder().encode(stored), forKey: Self.key(hubID: hubID))
        } catch {
            // The fold still holds on screen; only the memory is lost.
            Self.logger.error("board folds not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load(_ hubID: String?) -> [Int64: BoardFolds] {
        if let cached = byHub[hubID ?? ""] { return cached }
        guard let data = defaults.data(forKey: Self.key(hubID: hubID)) else { return [:] }
        do {
            let stored = try JSONDecoder().decode([String: BoardFolds].self, from: data)
            return Dictionary(stored.compactMap { key, value in Int64(key).map { ($0, value) } }) { first, _ in first }
        } catch {
            Self.logger.error("board folds unreadable, starting over: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "BoardFoldStore")
}
