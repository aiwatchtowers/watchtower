import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Kanban's header row while columns are edited on it (#713 AI-14 §1):
/// To Do implicit, In Progress split into two defined columns with the
/// second in rename mode, In Review hidden, and a refused edit under the row.
@MainActor
enum BoardColumnsShotFixtures {
    private static var poolPath: String?

    static func kanbanColumns() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            if let poolPath { TestDatabase.cleanup(path: poolPath) }
            poolPath = path
            let (pid, code) = try pool.write { db -> (Int64, Int64) in
                let pid = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme")
                try db.execute(sql: "UPDATE projects SET board_hidden_statuses = '[\"in_review\"]' WHERE id = ?",
                               arguments: [pid])
                try db.execute(sql: """
                    INSERT INTO workbench_board_columns (project_id, status, title, description, position, created_at)
                    VALUES (?, 'in_progress', 'Spec', 'Agreed and written down', 0, '2026-10-16T10:00:00Z'),
                           (?, 'in_progress', 'Code', '', 1, '2026-10-16T10:00:00Z')
                    """, arguments: [pid, pid])
                let code = db.lastInsertedRowID
                try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Fix the login redirect", priority: "low")
                try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Billing export for acme",
                                                       status: "in_progress", priority: "high")
                return (pid, code)
            }
            let vm = WorkbenchBoardViewModel(dbPool: pool, projectID: pid,
                                             defaults: UserDefaults(suiteName: "BoardColumnsShot-\(UUID().uuidString)") ?? .standard)
            vm.lanesMode = .none
            vm.load()
            vm.renamingColumnKey = BoardColumnLayout.key(code)
            vm.columnsError = "“Done” is the name of another status (Done)"
            return AnyView(WorkbenchBoardKanbanView(
                board: vm.kanban, vm: vm, selectedTargetID: nil,
                onSelect: { _ in }, onEnter: { _ in }, onOpenGroup: { _ in }, onMove: { _, _ in false }
            ).environment(AppState()))
        } catch {
            XCTFail("board columns shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))"))
        }
    }
}
