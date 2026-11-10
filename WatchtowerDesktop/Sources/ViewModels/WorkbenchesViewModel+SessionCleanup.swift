import Foundation
import GRDB
import WatchtowerCore

/// Session cleanup on the Workbench page (board #535, spec
/// 2026-10-12-session-cleanup §12, PROJ-18), driven through
/// `SessionCleanupCenter`. Every delete cleans up in the background
/// (board #1716, `WorkbenchesViewModel+AutoCleanup.swift`); a session's
/// **Clean Up…** opens the Clean Up screen on its scope
/// (`openCleanupScreen`, `WorkbenchesViewModel+CleanupSweep.swift`). Here:
/// the report's Cleanup line.
extension WorkbenchesViewModel {
    // MARK: Report line

    /// Reads session `sessionID`'s stored cleanup result. A failed read is
    /// logged and keeps the last value.
    func loadCleanupRecord(sessionID: Int64) async {
        do {
            let record = try await dbPool.read { try TerminalSessionQueries.fetchCleanupRecord($0, sessionID: sessionID) }
            cleanupRecords[sessionID] = record
        } catch {
            NSLog("WorkbenchesViewModel: reading session %lld's cleanup result failed: %@",
                  sessionID, error.localizedDescription)
        }
    }

    /// Keeps `cleanupRecords[sessionID]` in step with the database while the
    /// caller's task runs — a cleanup the agent ran (`finish_session`) while
    /// the report is open shows at once. Returns when cancelled.
    func observeCleanupRecord(sessionID: Int64) async {
        let observation = ValueObservation
            .tracking { try TerminalSessionQueries.fetchCleanupRecord($0, sessionID: sessionID) }
            .removeDuplicates()
        do {
            for try await record in observation.values(in: dbPool) {
                cleanupRecords[sessionID] = record
            }
        } catch is CancellationError {
            return
        } catch {
            NSLog("WorkbenchesViewModel: watching session %lld's cleanup result failed: %@",
                  sessionID, error.localizedDescription)
        }
    }

    /// The report's Cleanup line: Go's summary, or "Cleanup ran — result
    /// unreadable"; nil when the session has no cleanup result.
    func cleanupReportLine(sessionID: Int64) -> String? {
        cleanupRecords[sessionID].flatMap(SessionCleanupPresentation.reportLine)
    }
}
