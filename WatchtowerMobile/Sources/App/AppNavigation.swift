import Observation

/// A screen pushed on the Calendar tab's stack.
enum CalendarRoute: Hashable {
    case event(String)
    case recordings
    /// The recap and transcript of one `meeting_transcript`.
    case recap(Int)
}

/// The selected tab and the Calendar stack, owned by `AppEnvironment` so a
/// screen outside the tab (the recorder's "See recordings") can route.
@MainActor
@Observable
final class AppNavigation {
    var tab: RootTabView.Tab = .now
    var calendarPath: [CalendarRoute] = []

    /// The Calendar tab with the Recordings list on top: one list, never a
    /// stack of them.
    func showRecordings() {
        tab = .calendar
        calendarPath = [.recordings]
    }
}
