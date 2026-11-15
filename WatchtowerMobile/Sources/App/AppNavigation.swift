import Observation
import SwiftUI

/// A screen pushed on the Calendar tab's stack.
enum CalendarRoute: Hashable {
    case event(String)
    case recordings
    /// The recap and transcript of one `meeting_transcript`.
    case recap(Int)
}

/// Settings → Towers → one hub's screen, pushed on Now's stack (the Chats tab's Switch to Relay…).
struct MacDetailRoute: Hashable {
    let hubID: String
}

/// The selected tab and the Calendar stack, owned by `AppEnvironment` so a
/// screen outside the tab (the recorder's "See recordings") can route.
@MainActor
@Observable
final class AppNavigation {
    var tab: RootTabView.Tab = .now
    var calendarPath: [CalendarRoute] = []
    /// The Chats tab's stack: a conversation, a new chat.
    var chatsPath: [ChatRoute] = []
    /// Now's stack, so another tab can open Settings on it.
    var nowPath = NavigationPath()
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

    /// The Chats tab with one conversation on top, from the root (a chat push, a search hit); `messageID` is the
    /// message to scroll to.
    func show(conversation id: Int64, messageID: Int64? = nil) {
        tab = .chats
        chatsPath = [ChatRoute(id: id, messageID: messageID)]
    }

    /// Now's stack at Settings → Towers, then this hub's screen when `detail` (`MacsView.opensDetail`): the
    /// Chats tab's Switch to Relay… (mockup 1e).
    func showTowerSettings(hubID: String, detail: Bool) {
        tab = .now
        var path = NavigationPath()
        path.append(NowRoute.settings)
        path.append(NowRoute.macs)
        if detail { path.append(MacDetailRoute(hubID: hubID)) }
        nowPath = path
    }

    /// The Calendar tab with the Recordings list on top: one list, never a
    /// stack of them.
    func showRecordings() {
        tab = .calendar
        calendarPath = [.recordings]
    }

    /// Every stack this object owns back at its root, the tab kept: a hub
    /// switch (multi-hub spec §5.6), which also rebuilds the tab tree.
    func resetStacks() {
        calendarPath = []
        chatsPath = []
        nowPath = NavigationPath()
        workbenchPath = NavigationPath()
        openedAlert = nil
        visibleAlertScreen = nil
    }
}
