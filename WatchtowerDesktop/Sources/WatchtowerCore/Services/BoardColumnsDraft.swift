import Foundation

/// The Board Columns… sheet's editable state (board #267, spec 2026-10-16
/// §6): a workbench's column definition being edited, never fed to the
/// Kanban (an unsaved column has no id). `errors` mirrors Go
/// `validateBoardColumns` (internal/db/board_columns.go) plus the
/// hide-with-columns refusal, so the sheet shows a refusal before Save;
/// change both together. Go stays the judge: Save shows its message too.
package struct BoardColumnsDraft: Equatable {
    /// One column being edited. `id` is the draft's own (a new column has
    /// no stored id yet); `columnID` the stored column it edits.
    package struct Column: Identifiable, Equatable {
        package let id: Int
        package let columnID: Int64?
        package let status: String
        package var title: String
        package var description: String
    }

    /// Every status in board order (Go `db.BoardStatusOrder`).
    package static let statuses = BoardColumnLayout.openStatusOrder + ["dismissed"]
    static let maxPerStatus = 6
    static let maxPerWorkbench = 20
    static let maxTitleLength = 40
    static let maxDescriptionLength = 500

    /// Grouped by status in board order, each status's in position order.
    package private(set) var columns: [Column]
    package private(set) var hidden: Set<String>
    private var nextID: Int

    package init(_ def: WorkbenchBoardColumns) {
        var columns: [Column] = []
        for status in Self.statuses {
            for column in def.columns(of: status) {
                columns.append(Column(
                    id: columns.count, columnID: column.id, status: status,
                    title: column.title, description: column.description
                ))
            }
        }
        self.columns = columns
        hidden = Set(def.hidden)
        nextID = columns.count
    }

    package func columns(of status: String) -> [Column] {
        columns.filter { $0.status == status }
    }

    // MARK: - Edits

    /// Adds a column at the end of `status` under a free "New Column" title.
    /// - Returns: the new column's draft id.
    @discardableResult
    package mutating func add(to status: String) -> Int {
        let taken = Set(columns.map { Self.fold($0.title) })
        var title = "New Column"
        var n = 2
        while taken.contains(Self.fold(title)) {
            title = "New Column \(n)"
            n += 1
        }
        let id = nextID
        nextID += 1
        columns.append(Column(id: id, columnID: nil, status: status, title: title, description: ""))
        columns = Self.statuses.flatMap { columns(of: $0) }
        return id
    }

    package mutating func setTitle(_ title: String, of id: Int) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].title = title
    }

    package mutating func setDescription(_ description: String, of id: Int) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].description = description
    }

    /// The sheet's drag reorder inside one status (`onMove` offsets).
    package mutating func move(in status: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        var own = columns(of: status)
        let moving = source.filter { own.indices.contains($0) }.map { own[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where own.indices.contains(index) { own.remove(at: index) }
        own.insert(contentsOf: moving, at: min(max(destination - before, 0), own.count))
        columns = Self.statuses.flatMap { $0 == status ? own : columns(of: $0) }
    }

    package mutating func delete(_ id: Int) {
        columns.removeAll { $0.id == id }
    }

    package mutating func setHidden(_ isHidden: Bool, for status: String) {
        guard WorkbenchBoardColumns.hideableStatuses.contains(status) else { return }
        if isHidden { hidden.insert(status) } else { hidden.remove(status) }
    }

    /// Hide is offered on `in_review`/`blocked` while they have no columns.
    package func canHide(_ status: String) -> Bool {
        WorkbenchBoardColumns.hideableStatuses.contains(status) && columns(of: status).isEmpty
    }

    /// A column can be added below the limits, to a status not hidden.
    package func canAdd(to status: String) -> Bool {
        !hidden.contains(status) && columns(of: status).count < Self.maxPerStatus
            && columns.count < Self.maxPerWorkbench
    }

    // MARK: - Checks

    /// Every refusal Go would answer the draft with, in board order; empty
    /// means Save may run.
    package var errors: [String] {
        var out: [String] = []
        for status in WorkbenchBoardColumns.hideableStatuses
        where hidden.contains(status) && !columns(of: status).isEmpty {
            out.append("\(WorkbenchBoardCard.statusLabel(status)) cannot be hidden while it has columns")
        }
        if columns.count > Self.maxPerWorkbench {
            out.append("At most \(Self.maxPerWorkbench) columns per workbench (\(columns.count) now)")
        }
        for status in Self.statuses where columns(of: status).count > Self.maxPerStatus {
            out.append("\(WorkbenchBoardCard.statusLabel(status)): at most \(Self.maxPerStatus) columns")
        }
        var seen: Set<String> = []
        for column in columns {
            let title = Self.trimmed(column.title)
            let label = WorkbenchBoardCard.statusLabel(column.status)
            if title.isEmpty {
                out.append("A \(label) column has no title")
                continue
            }
            if title.unicodeScalars.count > Self.maxTitleLength {
                out.append("“\(title)”: the title is longer than \(Self.maxTitleLength) characters")
            }
            if title.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) {
                out.append("“\(title)”: a title cannot be only digits")
            }
            if Self.trimmed(column.description).unicodeScalars.count > Self.maxDescriptionLength {
                out.append("“\(title)”: the description is longer than \(Self.maxDescriptionLength) characters")
            }
            if let other = Self.statuses.first(where: {
                $0 != column.status && Self.fold(WorkbenchBoardCard.statusLabel($0)) == Self.fold(title)
            }) {
                out.append("“\(title)” is the name of another status (\(WorkbenchBoardCard.statusLabel(other)))")
            }
            if !seen.insert(Self.fold(title)).inserted {
                out.append("“\(title)” is used twice")
            }
        }
        return out
    }

    /// What Save sends: titles and descriptions trimmed, positions 0…n per
    /// status, hidden statuses in the hideable order.
    package var definition: WorkbenchBoardColumns {
        var positions: [String: Int] = [:]
        let defs = columns.map { column -> WorkbenchBoardColumnDef in
            let position = positions[column.status, default: 0]
            positions[column.status] = position + 1
            return WorkbenchBoardColumnDef(
                id: column.columnID, status: column.status, title: Self.trimmed(column.title),
                description: Self.trimmed(column.description), position: position
            )
        }
        return WorkbenchBoardColumns(
            columns: defs, hidden: WorkbenchBoardColumns.hideableStatuses.filter(hidden.contains)
        )
    }

    /// The JSON `watchtower workbench columns <id> --set -` reads
    /// (`WorkbenchCLI.setBoardColumns` encodes `definition` the same way).
    package func encoded() throws -> Data {
        try JSONEncoder().encode(definition)
    }

    /// What deleting column `id` does to the cards in it: they fall to the
    /// status's first column left (its standard one when none is). nil for
    /// an empty or unsaved column. `cardCounts` is
    /// `WorkbenchQueries.boardColumnCardCounts`.
    package func deleteNotice(for id: Int, cardCounts: [Int64: Int]) -> String? {
        guard let column = columns.first(where: { $0.id == id }),
              let stored = column.columnID,
              let count = cardCounts[stored], count > 0 else { return nil }
        let first = columns(of: column.status).first { $0.id != id }.map { Self.trimmed($0.title) }
        let destination = first.flatMap { $0.isEmpty ? nil : $0 } ?? WorkbenchBoardCard.statusLabel(column.status)
        return count == 1 ? "1 card moves to \(destination)." : "\(count) cards move to \(destination)."
    }

    // MARK: - Helpers

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fold(_ text: String) -> String {
        trimmed(text).lowercased()
    }
}
