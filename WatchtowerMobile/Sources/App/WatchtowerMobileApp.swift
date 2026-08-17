import os
import SwiftUI
import UIKit

/// Minimal delegate for the silent-push wake path (Plan 6 Decision 6):
/// CKSyncEngine owns subscriptions/push registration internally; the app
/// side only turns a `content-available` push into a sync nudge.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `Boot.make()` once the environment exists. Static because a
    /// background push launch reaches the delegate without any view having
    /// appeared; weak because the Boot state is the owner.
    @MainActor static weak var environment: AppEnvironment?

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Silent CloudKit push: nudge the engine (refresh → hydrateOnce →
        // pull hook) and let the hydrator hook raise any local alerts.
        Task { @MainActor in
            guard let env = Self.environment else {
                // Degraded boot (unopenable replica) — nothing to hydrate.
                Self.logger.warning("remote notification with no environment — degraded boot?")
                completionHandler(.noData)
                return
            }
            await env.refresh()
            completionHandler(.newData)
        }
    }
}

@main
struct WatchtowerMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                let env = try AppEnvironment()
                AppDelegate.environment = env
                // Silent pushes need an APNs registration, but only the live
                // transport has an engine to wake — the demo path must stay
                // free of ANY push machinery (and of prompts; registering for
                // remote notifications never prompts, but the discipline is
                // cheap). CKSyncEngine creates its own zone subscriptions.
                if env.transportKind == .cloudKit {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                return .ready(env)
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

/// Programmatic jump to the Settings tab — the chat banner's "Set up offline
/// agent…" destination (Plan 5 Task 7). An environment closure rather than
/// AppEnvironment state because tab selection is view state owned by
/// RootTabView; the no-op default keeps previews and tests rendering.
private struct OpenSettingsTabKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openSettingsTab: () -> Void {
        get { self[OpenSettingsTabKey.self] }
        set { self[OpenSettingsTabKey.self] = newValue }
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
/// Feature-gated tabs (Chat, Inbox, Tasks, Tracks) render only while their
/// desktop Feature Manager feature is enabled — the `FeatureGate` mirrors
/// the synced `feature_state` slice (absent slice = everything visible).
/// Today and Settings are never hideable; a hidden selection falls back to
/// Today, mirroring the desktop's navigation fallback.
struct RootTabView: View {
    enum Tab: String {
        case today, chat, inbox, tasks, tracks, settings
    }

    @Environment(AppEnvironment.self) private var env
    @State private var selection: Tab = .today
    /// Owned here — the root view never leaves the hierarchy, so the gate's
    /// replica observation survives all tab navigation.
    @State private var gate = FeatureGate()

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
            if gate.isVisible(.tab(.chat)) {
                ChatView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(Tab.chat)
            }
            if gate.isVisible(.tab(.inbox)) {
                InboxView()
                    .tabItem { Label("Inbox", systemImage: "tray") }
                    .tag(Tab.inbox)
            }
            if gate.isVisible(.tab(.tasks)) {
                TasksView()
                    .tabItem { Label("Tasks", systemImage: "checklist") }
                    .tag(Tab.tasks)
            }
            if gate.isVisible(.tab(.tracks)) {
                TracksView()
                    .tabItem { Label("Tracks", systemImage: "list.bullet.rectangle") }
                    .tag(Tab.tracks)
            }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // Settings folds under "More" on iPhone (six tabs) — this jump keeps
        // "Set up offline agent…" a one-tap path regardless.
        .environment(\.openSettingsTab) { selection = .settings }
        .environment(gate)
        .onAppear { gate.start(store: env.store) }
        // Desktop navigation-fallback semantics: the selected tab
        // disappearing (feature disabled on the Mac) lands the user on
        // Today, never on an empty selection.
        .onChange(of: gate.visibility) {
            selection = gate.resolvedSelection(selection)
        }
    }
}
