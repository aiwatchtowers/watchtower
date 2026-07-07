import os
import SwiftUI

@main
struct WatchtowerMobileApp: App {
    /// Boot outcome: the live environment, or why the replica pool could not
    /// open. Every tab is useless without the store, so a pool-open failure
    /// is a degraded state the user can read and report — a full-screen
    /// error instead of the tabs — never a `fatalError` (Task 9).
    private enum Boot {
        case ready(AppEnvironment)
        case failed(String)

        @MainActor
        static func make() -> Boot {
            do {
                return .ready(try AppEnvironment())
            } catch {
                Logger(subsystem: "WatchtowerMobile", category: "Boot")
                    .critical("replica store failed to open: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        }
    }

    @State private var boot = Boot.make()

    var body: some Scene {
        WindowGroup {
            switch boot {
            case .ready(let env):
                RootTabView()
                    .environment(env)
            case .failed(let message):
                BootFailureView(message: message)
            }
        }
    }
}

/// Minimal full-screen degraded state for an unopenable replica store.
struct BootFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Watchtower can't start", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text("The on-device database could not be opened.\n\(message)")
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
