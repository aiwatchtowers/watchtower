import Foundation

/// The add-site sheet's board step (#572): Jira syncs only selected boards
/// (`internal/jira/sync.go`), and a new site's boards arrive unselected, so
/// the sheet asks which ones to sync right after the connect. Pure: which
/// boards to list and the `jira boards select|deselect` calls a choice needs.
package enum JiraBoardPicker {
    /// The boards of the enabled sites among `accounts` (removed ones already
    /// dropped by `JiraAccountQueries.fetchAll`), in the given order — the
    /// same sites `JiraAccountFanOut` fetches boards for.
    package static func boards(_ boards: [JiraBoard], of accounts: [JiraAccount]) -> [JiraBoard] {
        let ids = Set(accounts.filter(\.enabled).map(\.id))
        return boards.filter { ids.contains(Int($0.accountID)) }
    }

    /// The sites the step fetches and lists: the enabled sites a connect
    /// added (not in `before`, the ids read before it). Every enabled site
    /// when there is no such site: the before-read failed (`before` nil), or
    /// the added row is disabled.
    package static func sites(_ accounts: [JiraAccount], before: Set<Int>?) -> [JiraAccount] {
        let enabled = accounts.filter(\.enabled)
        guard let before else { return enabled }
        let added = enabled.filter { !before.contains($0.id) }
        return added.isEmpty ? enabled : added
    }

    /// The `rowID`s selected now: the picker's starting choice.
    package static func selected(_ boards: [JiraBoard]) -> Set<String> {
        Set(boards.filter(\.isSelected).map(\.rowID))
    }

    /// One `jira --account <id> boards select|deselect <ids…>` per site and
    /// direction, only for boards whose state differs from `chosen`. Sites in
    /// ascending id order, select before deselect, board ids ascending.
    package static func invocations(for boards: [JiraBoard], chosen: Set<String>) -> [[String]] {
        var select: [Int64: [Int]] = [:]
        var deselect: [Int64: [Int]] = [:]
        for board in boards {
            let want = chosen.contains(board.rowID)
            guard want != board.isSelected else { continue }
            if want {
                select[board.accountID, default: []].append(board.id)
            } else {
                deselect[board.accountID, default: []].append(board.id)
            }
        }
        var calls: [[String]] = []
        for account in Set(select.keys).union(deselect.keys).sorted() {
            for (action, ids) in [("select", select[account]), ("deselect", deselect[account])] {
                guard let ids, !ids.isEmpty else { continue }
                calls.append(["jira", "--account", String(account), "boards", action] + ids.sorted().map(String.init))
            }
        }
        return calls
    }
}
