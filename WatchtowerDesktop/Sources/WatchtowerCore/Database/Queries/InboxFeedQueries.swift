import Foundation
import GRDB

/// The one read behind the Inbox list: every kind of card, each source on its
/// own query. A table missing mid-migration reads as that source being empty
/// (only "no such table"); any other error throws.
package enum InboxFeedQueries {
    /// Tables the read uses, for the Inbox's ValueObservation region.
    package static let observedTables: [String] = [
        "briefings", "day_plans", "day_plan_items", "tracks", "track_events", "ideas", "inbox_items", "users",
        "channels", "agent_actions", "reminders", "automation_outputs", "automations"
    ]

    private static let terminalTailHours = 24.0

    /// `nowUTC` is an RFC 3339 UTC string, `dayLimit` the Day pages' size. `today`
    /// is the caller's local day; the list builder places it, the read needs no bound from it.
    package static func read(_ db: Database, nowUTC: String, today: String, dayLimit: Int) throws -> InboxFeedSnapshot {
        var snapshot = InboxFeedSnapshot()
        let now = AutomationDates.parse(nowUTC) ?? Date()
        let terminalSince = AutomationDates.format(now.addingTimeInterval(-terminalTailHours * 3600))
        snapshot.proposals = try emptyIfTableMissing { try AgentActionQueries.fetchStrip(db, terminalSince: terminalSince) }
        snapshot.reminders = try emptyIfTableMissing { try ReminderQueries.fetchDue(db, nowUTC: nowUTC) }
        snapshot.outputs = try emptyIfTableMissing { try AutomationQueries.fetchInboxOutputs(db, includeRead: true) }
        // One date past the page tells whether an older one exists.
        let days = try emptyIfTableMissing { try BriefingQueries.fetchDayCards(db, limit: dayLimit + 1) }
        snapshot.days = Array(days.prefix(dayLimit))
        snapshot.hasOlderDays = days.count > dayLimit
        snapshot.ownerKnown = try OwnerQueries.resolve(db).isKnown
        snapshot.tracks = try emptyIfTableMissing { try TrackQueries.fetchInboxCards(db) }
        snapshot.stoppedTracks = try emptyIfTableMissing { try TrackQueries.fetchInboxCards(db, stopped: true) }
        snapshot.ideas = try emptyIfTableMissing { try IdeaQueries.fetchInboxRegistry(db) }
        snapshot.messages = try emptyIfTableMissing { try InboxQueries.fetchOpenMessages(db, nowUTC: nowUTC) }
        return snapshot
    }

    private static func emptyIfTableMissing<T>(_ read: () throws -> [T]) throws -> [T] {
        do {
            return try read()
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return []
        }
    }
}
