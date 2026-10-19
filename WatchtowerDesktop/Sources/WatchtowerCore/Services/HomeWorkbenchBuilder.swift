import Foundation

/// One workbench in Home's Workbench zone: its sessions that need a look and
/// its open asks.
package struct HomeWorkbenchBlock: Equatable, Sendable {
    package let workbenchID: Int64
    package let name: String
    package let sessions: [SessionAgentStatus]
    package let asks: [WorkbenchAskRow]
}

/// Groups the live session statuses and the open owner asks by workbench for
/// Home (spec 2026-10-19-home-zones §6). Pure: no reads, no clock.
package enum HomeWorkbenchBuilder {
    /// The session states Home shows, in the order they sort within a block.
    private static let kindOrder: [SessionSwitcherPresentation.State.Kind] = [
        .needsApproval, .failed, .readyToCheck, .background, .working
    ]
    package static let shownKinds: Set<SessionSwitcherPresentation.State.Kind> = Set(kindOrder)

    /// Sessions in `shownKinds` that belong to a workbench, plus the asks,
    /// grouped per workbench: blocks by name, sessions by kind, asks in the
    /// order given (oldest first). A workbench with only an ask still shows.
    package static func blocks(sessions: [SessionAgentStatus], asks: WorkbenchAskRows) -> [HomeWorkbenchBlock] {
        var sessionsByID: [Int64: [SessionAgentStatus]] = [:]
        var names: [Int64: String] = [:]
        for status in sessions where shownKinds.contains(status.state.kind) {
            guard let id = status.workbenchID else { continue }
            sessionsByID[id, default: []].append(status)
            if let name = status.workbenchName { names[id] = names[id] ?? name }
        }
        var asksByID: [Int64: [WorkbenchAskRow]] = [:]
        for row in asks.rows {
            asksByID[row.ask.projectID, default: []].append(row)
            names[row.ask.projectID] = row.workbenchName
        }
        let ids = Set(sessionsByID.keys).union(asksByID.keys)
        let blocks = ids.map { id in
            HomeWorkbenchBlock(
                workbenchID: id,
                name: names[id] ?? "",
                sessions: (sessionsByID[id] ?? []).sorted { lhs, rhs in
                    let l = rank(lhs), r = rank(rhs)
                    return l != r ? l < r : lhs.sessionID < rhs.sessionID
                },
                asks: asksByID[id] ?? []
            )
        }
        return blocks.sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return order != .orderedSame ? order == .orderedAscending : lhs.workbenchID < rhs.workbenchID
        }
    }

    /// A session row's click: its terminal; nil for a session outside a workbench.
    package static func link(for status: SessionAgentStatus) -> HomeLink? {
        status.workbenchID.map {
            .workbench(WorkbenchRoute(projectID: $0, pane: .terminal, subjectID: status.sessionID))
        }
    }

    /// An ask row's click: its session's terminal, or the board.
    package static func link(for row: WorkbenchAskRow) -> HomeLink {
        .workbench(.forAsk(projectID: row.ask.projectID, sessionID: row.ask.sessionID, askID: row.ask.id))
    }

    private static func rank(_ status: SessionAgentStatus) -> Int {
        kindOrder.firstIndex(of: status.state.kind) ?? kindOrder.count
    }
}
