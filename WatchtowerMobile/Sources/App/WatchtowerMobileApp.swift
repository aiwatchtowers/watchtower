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
    enum Tab: String {
        case today, chat, inbox, tasks, tracks, settings
    }

    @State private var selection: Tab = .today

    init() {
        #if DEBUG
        // Boot-check hook (DEBUG only): `simctl launch … -boot-tab settings`
        // opens on that tab — the launch argument lands in the UserDefaults
        // argument domain — so screenshot verification can reach non-first
        // tabs; simctl cannot script a tab tap.
        if let raw = UserDefaults.standard.string(forKey: "boot-tab"), let tab = Tab(rawValue: raw) {
            _selection = State(initialValue: tab)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(Tab.today)
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray") }
                .tag(Tab.inbox)
            TasksView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(Tab.tasks)
            TracksView()
                .tabItem { Label("Tracks", systemImage: "list.bullet.rectangle") }
                .tag(Tab.tracks)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}
