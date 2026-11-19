import WatchtowerKit

/// The session's subagents for the agents sheet (#2065, spec §2): the markers leave the dialog and sort into
/// Working and Done. The phone has no live snapshot, so a row is only type, description and "Running".
struct WorkchatAgents: Equatable {
    struct Row: Identifiable, Equatable {
        let id: String
        let type: String
        let description: String
        /// nil for a marker without its agent id or tool_use id: nothing to open.
        let route: SessionChatRoute?
    }

    /// The toolbar button's face.
    enum Badge: Equatable {
        case working(Int)
        case done(Int)
    }

    /// The owner's choice for the Done section; `automatic` until they toggle it.
    enum DoneDisclosure: Equatable {
        case automatic, open, closed
    }

    let working: [Row]
    /// Newest first.
    let done: [Row]

    init(entries: [SessionChat.Entry], sessionID: Int64) {
        var working: [Row] = []
        var done: [Row] = []
        for entry in entries where entry.kind == .subagent {
            guard let subagent = entry.subagent else { continue }
            let row = Row(
                id: entry.id,
                type: subagent.type.isEmpty ? "Subagent" : subagent.type,
                description: subagent.description,
                route: SessionChatEntryRow.route(for: subagent, sessionID: sessionID)
            )
            // A status a newer Mac adds lands in neither section.
            switch subagent.status {
            case "running": working.append(row)
            case "finished": done.append(row)
            default: break
            }
        }
        self.working = working
        self.done = done.reversed()
    }

    /// The dialog without the subagent markers.
    static func dialog(_ entries: [SessionChat.Entry]) -> [SessionChat.Entry] {
        entries.filter { $0.kind != .subagent }
    }

    var badge: Badge? {
        if !working.isEmpty { return .working(working.count) }
        if !done.isEmpty { return .done(done.count) }
        return nil
    }

    /// Done opens by itself when nothing works.
    var doneOpenByDefault: Bool { working.isEmpty && !done.isEmpty }

    /// Whether Done shows: the owner's choice wins over the default.
    func doneIsOpen(_ disclosure: DoneDisclosure) -> Bool {
        switch disclosure {
        case .automatic: doneOpenByDefault
        case .open: true
        case .closed: false
        }
    }
}

/// The agents button's and sheet's fixed strings.
enum WorkchatAgentsText {
    static let title = "Agents"
    static let working = "Working"
    static let running = "Running"
    static let close = "Close"

    static func done(_ n: Int) -> String { "Done · \(n)" }
    static func doneBadge(_ n: Int) -> String { "✓ \(n)" }
    /// The toolbar button's spoken value.
    static func badgeValue(_ badge: WorkchatAgents.Badge) -> String {
        switch badge {
        case let .working(n): "\(n) working"
        case let .done(n): "\(n) done"
        }
    }
}
