/// Why the Calendar tab may show no events although a calendar is connected
/// (#740). The daemon syncs a Google calendar only when the account granted
/// Calendar, its grant is healthy and the global `calendar.enabled` switch is
/// on; CalDAV/ICS accounts are not behind that switch.
package enum CalendarSyncHealth: Equatable {
    /// A Google account granted Calendar, but `calendar.enabled` is off, so
    /// the daemon never syncs it.
    case syncOff
    /// A Google account granted Calendar, but its last sync or token check
    /// failed (`status` not ok) — the row carries the reason.
    case accountError(GoogleAccount)
    /// A connected calendar has never synced and no daemon is running to do it.
    case daemonStopped
    /// A connected calendar has never synced; the running daemon will.
    case awaitingFirstSync
    case ok

    /// Pure: the first matching reason, most actionable first. The counts are
    /// `calendar_calendars` rows per source kind — a sync writes the calendar
    /// list before any event, so zero means that kind has never synced. They
    /// are kept apart so a synced CalDAV calendar cannot hide a Google one
    /// that never synced.
    package static func evaluate(
        accounts: [GoogleAccount],
        hasCalDAVSource: Bool,
        syncSwitchOn: Bool,
        googleCalendarCount: Int,
        calDAVCalendarCount: Int,
        daemonRunning: Bool
    ) -> Self {
        let googleCalendars = accounts.filter(\.calendarEnabled)
        let healthy = googleCalendars.contains(where: \.isOK)
        if healthy && !syncSwitchOn { return .syncOff }
        if let broken = googleCalendars.first(where: { !$0.isOK }) { return .accountError(broken) }
        let googleWaiting = healthy && googleCalendarCount == 0
        let calDAVWaiting = hasCalDAVSource && calDAVCalendarCount == 0
        guard googleWaiting || calDAVWaiting else { return .ok }
        return daemonRunning ? .awaitingFirstSync : .daemonStopped
    }
}
