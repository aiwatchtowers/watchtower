import Foundation

/// One defined column of a workbench board (board #267, PROJ-19): a named
/// place inside one status. Twin of Go `db.BoardColumn`; the coding keys are
/// the `watchtower workbench columns --json` wire shape (a new column has no
/// `id`).
package struct WorkbenchBoardColumnDef: Codable, Equatable, Identifiable {
    package var id: Int64?
    package var status: String
    package var title: String
    package var description: String
    package var position: Int

    package init(id: Int64?, status: String, title: String, description: String, position: Int) {
        self.id = id
        self.status = status
        self.title = title
        self.description = description
        self.position = position
    }

    package enum CodingKeys: String, CodingKey {
        case id, status, title, description, position
    }
}

/// A workbench's column definition. Twin of Go `db.BoardColumns`: columns
/// in status order, then position; `hidden` a subset of `hideableStatuses`.
package struct WorkbenchBoardColumns: Codable, Equatable {
    package var columns: [WorkbenchBoardColumnDef]
    package var hidden: [String]

    /// The statuses a workbench may hide (Go `db.HideableStatuses`).
    package static let hideableStatuses = ["in_review", "blocked"]
    /// No columns, nothing hidden: today's board.
    package static let empty = Self(columns: [], hidden: [])

    package init(columns: [WorkbenchBoardColumnDef], hidden: [String]) {
        self.columns = columns
        self.hidden = hidden
    }

    package enum CodingKeys: String, CodingKey {
        case columns, hidden
    }

    package var isEmpty: Bool { columns.isEmpty && hidden.isEmpty }

    package func isHidden(_ status: String) -> Bool { hidden.contains(status) }

    /// `status`'s defined columns by position.
    package func columns(of status: String) -> [WorkbenchBoardColumnDef] {
        columns.filter { $0.status == status }.sorted { ($0.position, $0.id ?? 0) < ($1.position, $1.id ?? 0) }
    }
}
