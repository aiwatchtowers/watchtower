import Foundation
import GRDB
import WatchtowerCore

extension AppState {
    /// Hands the recorder Center its real meetings provider (the Center is
    /// created before the dbPool exists — the `wireMeetingRecorderLoaders`
    /// precedent) and starts the warm-engine policy poll. A read failure is
    /// treated as "no meetings" and logged (the MeetingReminder convention):
    /// the worst outcome is a missed prewarm or a one-tick-late unload, both
    /// self-correcting — never a crash, never an unload mid-recording (the
    /// policy never touches a busy engine regardless of the window).
    func startWarmEnginePolicy(dbPool: DatabasePool) {
        meetingRecorderCenter.configureWarmPolicy { now in
            do {
                // Candidate events overlapping the prewarm lookahead:
                // fetchEvents matches start_time <= to AND end_time >= from,
                // so this returns both ongoing meetings and ones starting
                // within the lead; the pure logic sorts out which is which.
                let events = try dbPool.read { db in
                    try CalendarQueries.fetchEvents(
                        db,
                        from: now,
                        to: now.addingTimeInterval(WarmEnginePolicy.prewarmLead)
                    )
                }
                return WarmEnginePolicy.window(events: events, now: now)
            } catch {
                print("[AppState] warm-policy event read failed, treating as no meetings: "
                      + error.localizedDescription)
                return .noMeetings
            }
        }
        meetingRecorderCenter.startWarmPolicy()
    }
}
