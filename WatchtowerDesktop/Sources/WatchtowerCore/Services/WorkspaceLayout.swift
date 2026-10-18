import Foundation

/// One pane of a project workspace: a terminal session, a session's report
/// (the Session view), the Board, or the code editor with its file tabs
/// (POC). A saved layout naming a pane that is gone (`documents`, spec
/// 2026-10-03 Part 8) or that this build does not know decodes to `.default`.
package enum WorkspacePane: Codable, Hashable, Sendable {
    case session(Int64)
    /// The Session view of a `claude` session (spec
    /// 2026-10-03-workbench-session-report Part 7). It follows the session
    /// put on screen (`show`, `reveal`, `replace`, `openBeside`).
    case sessionReport(Int64)
    case board
    case files
    /// The workbench's agent analytics: time, cost and hints (#298).
    case analytics
    /// The diff reviewer of a session's changes (board #328).
    case changes(Int64)
    /// The Workchat of a session: its dialog as a chat, the session's second
    /// mode beside the terminal (#711). The raw name predates Workchat;
    /// persisted, so kept.
    case sessionChat(Int64)
}

extension WorkspacePane {
    /// A session's Workchat (#711).
    package var isWorkchat: Bool {
        if case .sessionChat = self { true } else { false }
    }
}

/// The project page header's view buttons: a terminal (any session), the
/// Session view, the Board, the Files or a session's Changes.
package enum WorkspaceView: CaseIterable, Sendable {
    case terminal
    /// A session's report (the Session view).
    case report
    case board
    /// The code editor's file tabs (POC).
    case files
    /// The workbench's agent analytics (#298), project-wide like the Board.
    case analytics
    /// A session's changes under review (board #328).
    case changes
    /// A session's Workchat (#711); the raw name predates it.
    case chat

    /// What `pane` shows.
    package init(_ pane: WorkspacePane) {
        switch pane {
        case .session: self = .terminal
        case .sessionReport: self = .report
        case .board: self = .board
        case .files: self = .files
        case .analytics: self = .analytics
        case .changes: self = .changes
        case .sessionChat: self = .chat
        }
    }

    package func matches(_ pane: WorkspacePane) -> Bool {
        Self(pane) == self
    }
}

/// Which panes a project page shows, persisted per project under
/// `WorkspaceLayout.key(workbenchID:)`. Pure value type: the view owns the
/// storage, this owns the rules.
package struct WorkspaceLayout: Codable, Equatable, Sendable {
    package static let dividerRange: ClosedRange<Double> = 0.2...0.8

    package var primary: WorkspacePane
    /// nil = single pane.
    package var secondary: WorkspacePane?
    /// Non-nil = that pane alone; the split is remembered underneath.
    package var expanded: WorkspacePane?
    package var dividerFraction: Double
    /// The sessions last shown in Workchat (#711); every other session opens
    /// in its terminal. Absent from a layout saved before Workchat.
    package var workchatSessions: Set<Int64> = []

    package static let `default` = Self(primary: .board, secondary: nil, expanded: nil, dividerFraction: 0.5)

    package var isSplit: Bool { secondary != nil }

    package var visiblePanes: [WorkspacePane] {
        if let expanded { return [expanded] }
        return [primary] + (secondary.map { [$0] } ?? [])
    }

    package mutating func split(with pane: WorkspacePane) {
        guard pane != primary else { return }
        secondary = pane
        expanded = nil
    }

    /// Keeps the primary pane; clears the secondary and any expansion.
    package mutating func unsplit() {
        secondary = nil
        expanded = nil
    }

    /// Only a split has something to expand; a single pane is a no-op.
    package mutating func toggleExpand(_ pane: WorkspacePane) {
        guard isSplit else { return }
        if expanded == pane {
            expanded = nil
        } else if pane == primary || pane == secondary {
            expanded = pane
        }
    }

    /// Panel click: an expansion is dropped first; then a pane already in a
    /// slot stays as is, otherwise it replaces the primary (single) or the
    /// secondary (split) — in a split a session never replaces the Session
    /// view: it takes the other slot, and the Session view follows it. Both
    /// slots never hold the same pane.
    package mutating func show(_ pane: WorkspacePane) {
        expanded = nil
        defer { follow(pane) }
        if pane == primary || pane == secondary { return }
        if isSplit {
            if Self.sessionID(of: pane) != nil, case .sessionReport? = secondary {
                primary = pane
            } else {
                secondary = pane
            }
        } else {
            primary = pane
        }
    }

    /// A pane's own picker: `slot` shows `pane` instead. A pane already in
    /// the other slot swaps places with it; an expansion follows its slot.
    /// Returns false when `slot` is in neither slot (nothing changes).
    @discardableResult
    package mutating func replace(_ slot: WorkspacePane, with pane: WorkspacePane) -> Bool {
        guard slot != pane else { return primary == slot || secondary == slot }
        let wasExpanded = expanded == slot
        if primary == slot {
            if secondary == pane { secondary = slot }
            primary = pane
        } else if secondary == slot {
            if primary == pane { primary = slot }
            secondary = pane
        } else {
            return false
        }
        if wasExpanded { expanded = pane }
        follow(pane)
        return true
    }

    /// A split pane's close button: the other pane stays, alone. A single
    /// pane cannot be removed.
    package mutating func remove(_ pane: WorkspacePane) {
        guard isSplit else { return }
        if secondary == pane {
            unsplit()
        } else if primary == pane, let next = secondary {
            primary = next
            unsplit()
        }
    }

    /// The Terminal toggle and Work on it: puts `pane` on screen without
    /// hiding `kept` (the pane the owner acted from). Visible already → nothing moves; a split
    /// replaces the other pane; a single pane switches to it.
    package mutating func reveal(_ pane: WorkspacePane, keeping kept: WorkspacePane) {
        defer { follow(pane) }
        if visiblePanes.contains(pane) { return }
        if pane == primary || pane == secondary {
            expanded = nil
        } else if isSplit {
            expanded = nil
            replace(primary == kept ? secondary ?? primary : primary, with: pane)
        } else {
            primary = pane
        }
    }

    /// ⌘↵ in the go-to palette: `pane` on screen beside `kept`. A single
    /// pane splits with it second; a split replaces the pane that is not
    /// `kept` (`reveal`); on screen already → nothing moves.
    package mutating func openBeside(_ pane: WorkspacePane, keeping kept: WorkspacePane) {
        defer { follow(pane) }
        if isSplit {
            reveal(pane, keeping: kept)
        } else {
            split(with: pane)
        }
    }

    /// Whether a header view button shows as on: that kind of pane is on screen.
    package func isShowing(_ view: WorkspaceView) -> Bool {
        visiblePanes.contains(where: view.matches)
    }

    /// The header's Board / Files button: puts `pane` on screen without
    /// hiding a terminal — a split keeps its session and swaps the other
    /// pane; a single pane switches to it (`reveal`).
    package mutating func showWorkbenchView(_ pane: WorkspacePane) {
        let session = [primary, secondary].compactMap(\.self).first { Self.sessionID(of: $0) != nil }
        reveal(pane, keeping: session ?? primary)
    }

    /// The pane the header's session menu puts a session into: the session
    /// on screen, in its terminal or its Workchat (#711), else the last pane
    /// on screen — the one the Terminal button replaces too (it keeps the
    /// first).
    package var terminalSlot: WorkspacePane {
        visiblePanes.first { Self.sessionID(of: $0) != nil } ?? visiblePanes.last ?? primary
    }

    /// A header view button turned off: in a split on screen, the pane it
    /// names closes and the other stays alone. One pane on screen (single
    /// or expanded) is never removed.
    package mutating func hide(_ view: WorkspaceView) {
        guard visiblePanes.count == 2, let pane = visiblePanes.first(where: view.matches) else { return }
        remove(pane)
    }

    package mutating func setDividerFraction(_ fraction: Double) {
        dividerFraction = min(max(fraction, Self.dividerRange.lowerBound), Self.dividerRange.upperBound)
    }

    /// The sessions in either slot, primary first.
    package var sessionIDs: [Int64] {
        [primary, secondary].compactMap { pane in
            if case let .session(id)? = pane { return id }
            return nil
        }
    }

    // MARK: - Terminal or Workchat (#711)

    /// The sessions in either slot, in their terminal or their Workchat,
    /// primary first.
    package var shownSessionIDs: [Int64] {
        [primary, secondary].compactMap { $0.flatMap(Self.sessionID(of:)) }
    }

    /// Every session the layout names: one in a slot, or one whose
    /// Workchat mode it remembers. A session gone from the list leaves all.
    package var referencedSessionIDs: Set<Int64> {
        Set(shownSessionIDs).union(workchatSessions)
    }

    /// The session of a terminal or a Workchat pane; nil for any other pane.
    package static func sessionID(of pane: WorkspacePane) -> Int64? {
        switch pane {
        case let .session(id), let .sessionChat(id): id
        default: nil
        }
    }

    /// Records the mode session `id` opens in next: Workchat (`workchat`)
    /// or its terminal. A new session records the terminal: a fresh agent
    /// may stop at a trust or login prompt only the terminal shows.
    package mutating func setMode(_ workchat: Bool, sessionID id: Int64) {
        if workchat { workchatSessions.insert(id) } else { workchatSessions.remove(id) }
    }

    /// The pane session `id` opens in: its Workchat when it was last shown
    /// there, else its terminal.
    package func pane(forSession id: Int64) -> WorkspacePane {
        workchatSessions.contains(id) ? .sessionChat(id) : .session(id)
    }

    /// ⌃` and the header's twin switch: the slot holding session `id`
    /// shows its other mode instead — same session, same slot — and that
    /// mode is recorded. With both modes side by side in a split nothing
    /// moves; an expansion moves to the other mode. Neither on screen:
    /// only the mode flips.
    package mutating func toggleMode(sessionID id: Int64) {
        let terminal = WorkspacePane.session(id)
        let chat = WorkspacePane.sessionChat(id)
        let toChat = !workchatSessions.contains(id)
        let slots = [primary, secondary].compactMap(\.self)
        let from: WorkspacePane, to: WorkspacePane
        if slots.contains(terminal), slots.contains(chat) {
            setMode(toChat, sessionID: id)
            if let shown = expanded, shown == terminal || shown == chat { expanded = shown == terminal ? chat : terminal }
            return
        } else if slots.contains(chat) {
            (from, to) = (chat, terminal)
        } else if slots.contains(terminal) {
            (from, to) = (terminal, chat)
        } else {
            setMode(toChat, sessionID: id)
            return
        }
        replace(from, with: to)
        setMode(to == chat, sessionID: id)
    }

    /// The Session view tracks the selected session: once `pane`, a
    /// session's terminal or Workchat, is put on screen, a Session view in
    /// either slot shows its report.
    private mutating func follow(_ pane: WorkspacePane) {
        guard let id = Self.sessionID(of: pane) else { return }
        let report = WorkspacePane.sessionReport(id)
        if case .sessionReport = primary { primary = report }
        if case .sessionReport? = secondary { secondary = report }
        if case .sessionReport? = expanded { expanded = report }
        if secondary == primary { unsplit() }
    }

    /// A deleted session never stays in the layout; a Session view on its
    /// report stays, with no session to show until another one is picked.
    /// Its Changes and Workchat panes go with it — its round has no session
    /// to review — and so does its remembered mode.
    package mutating func forgetSession(_ id: Int64, fallback: WorkspacePane) {
        workchatSessions.remove(id)
        for gone in [WorkspacePane.changes(id), .sessionChat(id), .session(id)] {
            if expanded == gone { expanded = nil }
            if secondary == gone { secondary = nil }
            if primary == gone {
                if let next = secondary {
                    primary = next
                    secondary = nil
                } else {
                    primary = fallback
                }
            }
        }
    }

    /// The `projects.` prefix predates the Workbench rename; persisted, so kept (spec 2026-10-02 A1).
    package static func key(workbenchID: Int64) -> String { "projects.layout.\(workbenchID)" }

    /// Bad or missing data → `.default`; the divider is clamped to its range,
    /// a secondary equal to the primary and an expansion naming neither slot
    /// are dropped.
    package static func decode(_ data: Data?) -> Self {
        guard let data, var layout = try? JSONDecoder().decode(Self.self, from: data) else { return .default }
        if layout.secondary == layout.primary { layout.secondary = nil }
        if let expanded = layout.expanded, !layout.isSplit || (expanded != layout.primary && expanded != layout.secondary) {
            layout.expanded = nil
        }
        layout.setDividerFraction(layout.dividerFraction)
        return layout
    }
}

extension WorkspaceLayout {
    /// `workchatSessions` is optional: a layout saved before Workchat has none.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primary = try c.decode(WorkspacePane.self, forKey: .primary)
        secondary = try c.decodeIfPresent(WorkspacePane.self, forKey: .secondary)
        expanded = try c.decodeIfPresent(WorkspacePane.self, forKey: .expanded)
        dividerFraction = try c.decode(Double.self, forKey: .dividerFraction)
        workchatSessions = try c.decodeIfPresent(Set<Int64>.self, forKey: .workchatSessions) ?? []
    }
}
