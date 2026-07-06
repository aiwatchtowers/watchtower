import SwiftUI

@main
struct WatchtowerMobileApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(env)
        }
    }
}

/// The six tabs over the replica.
///
/// Tab placement (Task 7 decision): Chat sits SECOND, right after Today —
/// it is the app's only conversational surface and earns a visible slot.
/// With six items, iPhone's tab bar shows the first four (Today, Chat,
/// Inbox, Tasks) and folds Tracks + Settings under the automatic "More"
/// item — Settings stays reachable there (and iPad shows all six). Tracks
/// is the least-touched read-only tab, so it pays the More cost, not Chat.
struct RootTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max") }
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray") }
            TasksView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
            TracksView()
                .tabItem { Label("Tracks", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
