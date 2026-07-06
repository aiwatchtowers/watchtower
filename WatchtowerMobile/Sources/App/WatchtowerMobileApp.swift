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

/// The five read-only tabs over the replica.
struct RootTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max") }
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
