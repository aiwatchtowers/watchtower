import Foundation

/// The ⌘K palette's keyboard model (board #252), kept out of the view so it
/// is testable: which row is selected and what a key does with it.
package struct GoToPaletteSelection: Equatable, Sendable {
    package enum Key: Sendable {
        case up
        case down
        /// ↵
        case open
        /// ⌘↵
        case openInSplit
        /// esc
        case close
    }

    package enum Outcome: Equatable, Sendable {
        /// The selection moved, or there is nothing to act on.
        case ignored
        case close
        case open(GoToItem)
        /// A session of the workbench on screen, beside the focused pane.
        case openInSplit(TerminalSession)
    }

    /// nil, or a row no longer listed = the first row.
    package private(set) var selectedID: String?

    package init() {}

    package func selected(in items: [GoToItem]) -> GoToItem? {
        items.first { $0.id == selectedID } ?? items.first
    }

    /// A hovered or clicked row.
    package mutating func select(_ id: String) {
        selectedID = id
    }

    /// A query edit: back to the first row.
    package mutating func reset() {
        selectedID = nil
    }

    /// ↑↓ stop at the ends; ⌘↵ on another workbench's row, or without a
    /// workbench page, opens it like ↵.
    package mutating func handle(_ key: Key, items: [GoToItem], currentWorkbenchID: Int64?) -> Outcome {
        switch key {
        case .up:
            move(by: -1, in: items)
            return .ignored
        case .down:
            move(by: 1, in: items)
            return .ignored
        case .close:
            return .close
        case .open:
            return selected(in: items).map(Outcome.open) ?? .ignored
        case .openInSplit:
            guard let item = selected(in: items) else { return .ignored }
            if case let .session(session, workbench) = item, workbench.id == currentWorkbenchID {
                return .openInSplit(session)
            }
            return .open(item)
        }
    }

    private mutating func move(by step: Int, in items: [GoToItem]) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(max(index + step, 0), items.count - 1)].id
    }
}
