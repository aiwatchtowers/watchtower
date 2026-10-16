import Foundation

/// One column of the Kanban built from a workbench's definition: a defined
/// column, or a status's implicit one under its standard label.
package struct BoardColumnSlot: Equatable, Identifiable {
    /// The status for an implicit column, "c<id>" for a defined one.
    package let key: String
    package let status: String
    /// The defined column; nil for an implicit one (a drop there writes a
    /// NULL column — the status's first column).
    package let columnID: Int64?
    package let title: String
    package let description: String
    /// The status's standard label, set only when `title` differs from it.
    package let categoryLabel: String?

    package var id: String { key }
}

/// The Kanban's columns from a workbench's column definition (board #267,
/// spec 2026-10-16 §3/§6). Pure; no I/O.
///
/// For each status in board order, its defined columns by position or its
/// implicit column. A hidden status shows no column while empty; with cards
/// it keeps one implicit column under its standard label until they move
/// out. A card's stored column that is NULL or not one of its status's
/// shown columns lands in the status's first column — Go's
/// `firstColumnTitle` rule (`internal/db/board_columns.go`); change both
/// together.
package enum BoardColumnLayout {
    /// The board's status order without `dismissed`, which shows only with
    /// "Show done" or "Archive" on (Go `db.BoardStatusOrder`).
    package static let openStatusOrder = ["todo", "in_progress", "in_review", "blocked", "done"]

    package static func slots(
        _ def: WorkbenchBoardColumns,
        occupiedStatuses: Set<String>,
        showDismissed: Bool
    ) -> [BoardColumnSlot] {
        let statuses = showDismissed ? openStatusOrder + ["dismissed"] : openStatusOrder
        return statuses.flatMap { status -> [BoardColumnSlot] in
            if def.isHidden(status) {
                return occupiedStatuses.contains(status) ? [implicitSlot(status)] : []
            }
            let defined = def.columns(of: status)
            guard !defined.isEmpty else { return [implicitSlot(status)] }
            return defined.map { column in
                let label = WorkbenchBoardCard.statusLabel(status)
                return BoardColumnSlot(
                    key: key(column.id), status: status, columnID: column.id, title: column.title,
                    description: column.description, categoryLabel: column.title == label ? nil : label
                )
            }
        }
    }

    /// The key of the slot a card of `status` stored in `columnID` shows in.
    package static func slotKey(status: String, columnID: Int64?, def: WorkbenchBoardColumns) -> String {
        guard !def.isHidden(status) else { return status }
        let defined = def.columns(of: status)
        guard let first = defined.first else { return status }
        let column = defined.first { $0.id != nil && $0.id == columnID } ?? first
        return key(column.id)
    }

    private static func key(_ columnID: Int64?) -> String {
        "c\(columnID ?? 0)"
    }

    private static func implicitSlot(_ status: String) -> BoardColumnSlot {
        BoardColumnSlot(
            key: status, status: status, columnID: nil, title: WorkbenchBoardCard.statusLabel(status),
            description: "", categoryLabel: nil
        )
    }
}
