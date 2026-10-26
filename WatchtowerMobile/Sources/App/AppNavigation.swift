import Observation
import SwiftUI

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
    /// The Workbench tab's stack: a tapped alert pushes its screen here.
    /// Once it is shallower than the alert's screen, that screen is gone for good: a different screen later at the
    /// same depth must not stand in for it.
    var workbenchPath = NavigationPath() {
        didSet {
            if let openedAlert, workbenchPath.count < openedAlert.depth { self.openedAlert = nil }
        }
    }
    /// The screen the last alert tap pushed and the stack depth right after, so an alert for the screen still on
    /// top is not shown again (`AlertDestination.foregroundOptions`).
    private(set) var openedAlert: (destination: AlertDestination, depth: Int)?
    /// The workchat or ask form on screen, however it was opened: the screen sets it when it appears and clears it
    /// when it goes (covered, popped or another tab).
    private(set) var visibleAlertScreen: AlertDestination?

    /// The alert screen on top: the visible workchat or ask form, else the screen the last alert tap pushed while it
    /// is still the top of the Workbench tab.
    var alertOnScreen: AlertDestination? {
        if let visibleAlertScreen { return visibleAlertScreen }
        guard tab == .workbench, let openedAlert, workbenchPath.count == openedAlert.depth else { return nil }
        return openedAlert.destination
    }

    func screenAppeared(_ screen: AlertDestination) {
        visibleAlertScreen = screen
    }

    /// Clears only its own screen: the next screen's appear can land before the covered one's disappear.
    func screenDisappeared(_ screen: AlertDestination) {
        if visibleAlertScreen == screen { visibleAlertScreen = nil }
    }

    /// Selects the Workbench tab and pushes the destination on its stack, from the root.
    func show(_ destination: AlertDestination) {
        tab = .workbench
        workbenchPath = NavigationPath()
        switch destination {
        case let .ask(_, askID): workbenchPath.append(AskRoute(id: askID))
        case let .session(_, sessionID): workbenchPath.append(SessionRoute(id: sessionID))
        }
        openedAlert = (destination, workbenchPath.count)
    }

    /// The Calendar tab with the Recordings list on top: one list, never a
    /// stack of them.
    func showRecordings() {
        tab = .calendar
        calendarPath = [.recordings]
    }

    /// Every stack this object owns back at its root, the tab kept: a hub
    /// switch (multi-hub spec §5.6). The Now and Workbench stacks are the
    /// tabs' own and start over with the tab tree the switch rebuilds.
    func resetStacks() {
        calendarPath = []
        workbenchPath = NavigationPath()
        openedAlert = nil
        visibleAlertScreen = nil
    }
}
