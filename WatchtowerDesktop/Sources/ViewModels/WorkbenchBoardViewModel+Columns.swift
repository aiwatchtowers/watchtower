import Foundation
import GRDB
import WatchtowerCore

/// Columns edited on the Kanban's header row (#713 AI-14 §1, replacing the
/// Board Columns… sheet): every edit applies one `BoardColumnsDraft`
/// operation to the stored definition and saves the whole definition at
/// once. A refusal — the draft's own check or Go's — leaves the stored
/// definition as it was and shows under the header row.
extension WorkbenchBoardViewModel {
    /// The stored definition as a draft, for the header menus' enabled
    /// states (`canAdd`, `canMove`, `canHide`).
    var columnsDraft: BoardColumnsDraft { BoardColumnsDraft(boardColumns) }

    /// Applies `edit` to the definition read right before the write and
    /// saves it. `edit` returns the draft id of a column it added, which
    /// opens in rename mode once saved.
    /// - Returns: whether the definition was saved.
    @discardableResult
    func editColumns(_ edit: @escaping @MainActor (inout BoardColumnsDraft) -> Int?) async -> Bool {
        await columnWrites.run { [weak self] in
            guard let self else { return false }
            return await self.applyColumnEdit(edit)
        }
    }

    private func applyColumnEdit(_ edit: (inout BoardColumnsDraft) -> Int?) async -> Bool {
        let pid = projectID
        let stored: WorkbenchBoardColumns
        do {
            // Read again: another window, or the previous edit, may have
            // saved since the board's last load.
            stored = try await dbPool.read { try WorkbenchQueries.boardColumns($0, projectID: pid) }
        } catch {
            columnsError = "Could not read the board columns: \(error.localizedDescription)"
            return false
        }
        var draft = BoardColumnsDraft(stored)
        let added = edit(&draft)
        guard draft.definition != stored else {
            columnsError = nil
            return true
        }
        if !draft.errors.isEmpty {
            columnsError = draft.errors.joined(separator: "\n")
            return false
        }
        guard let saveColumns else {
            columnsError = WorkbenchesViewModel.boardColumnsMessage(WorkbenchBoardColumnsError.cliUnavailable)
            return false
        }
        do {
            let saved = try await saveColumns(draft.definition)
            columnsError = nil
            load()
            if let added, let id = draft.storedID(of: added, in: saved) {
                renamingColumnKey = BoardColumnLayout.key(id)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            columnsError = WorkbenchesViewModel.boardColumnsMessage(error)
            return false
        }
    }

    /// What Delete Column asks before it goes: "N cards move to …", nil for
    /// an empty column. A failed count read still asks, without the number.
    func columnDeleteNotice(_ columnID: Int64) -> String? {
        let pid = projectID
        do {
            let counts = try dbPool.read { try WorkbenchQueries.boardColumnCardCounts($0, projectID: pid) }
            return columnsDraft.deleteNotice(forStored: columnID, cardCounts: counts)
        } catch {
            return "Its cards move to the status's first column."
        }
    }
}
