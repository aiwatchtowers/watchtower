/// Why the Calendar tab may show no events although a calendar is connected
/// (#740). The daemon syncs a Google calendar only when the account granted
/// Calendar, its grant is healthy and the global `calendar.enabled` switch is
/// on; CalDAV/ICS accounts are not behind that switch.
package enum CalendarSyncHealth: Equatable {
    /// A Google account granted Calendar, but `calendar.enabled` is off, so
    /// the daemon never syncs it.
    case syncOff
    /// A Google account granted Calendar, but its grant is broken (`status`
    /// not ok) — it needs a fresh consent.
    case needsReconnect(GoogleAccount)
    /// Everything is on, no calendar has synced yet.
    case awaitingFirstSync
    case ok

    /// Pure: the first matching reason, most actionable first. `calendarCount`
    /// is the number of `calendar_calendars` rows — a sync writes the calendar
    /// list before any event, so zero means no sync has completed yet.
    package static func evaluate(
        accounts: [GoogleAccount],
        hasCalDAVSource: Bool,
        syncSwitchOn: Bool,
        calendarCount: Int
    ) -> Self {
        let googleCalendars = accounts.filter(\.calendarEnabled)
        let healthy = googleCalendars.contains(where: \.isOK)
        if healthy && !syncSwitchOn { return .syncOff }
        if let broken = googleCalendars.first(where: { !$0.isOK }) { return .needsReconnect(broken) }
        let syncable = (healthy && syncSwitchOn) || hasCalDAVSource
        if syncable && calendarCount == 0 { return .awaitingFirstSync }
        return .ok
    }
}
