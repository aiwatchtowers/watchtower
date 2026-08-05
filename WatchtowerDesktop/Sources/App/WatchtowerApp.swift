import SwiftUI
import AppKit
import GRDB
import UserNotifications

/// Allows notifications to display as banners even when the app is in the foreground,
/// and handles notification click actions to navigate within the running app.
/// H5 fix: uses a static shared reference to AppState that is set once the SwiftUI-managed
/// state is available (in .onAppear), avoiding the stale-copy problem with @State in init().
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Set from the SwiftUI body once the real managed AppState is live.
    static var sharedAppState: AppState?

    /// Set by a duplicate instance that lost the single-instance race: it routes
    /// nothing itself, it hands the response to the survivor and exits.
    static var forwardMode = false

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier

        if Self.forwardMode {
            NotificationForwarding.post(actionID: actionID, userInfo: userInfo)
            completionHandler()
            NSLog("NotificationDelegate: forwarded response for action %@ to the running instance; exiting", actionID)
            // The response is what this process was waiting for — no reason to
            // sit out the rest of the grace window.
            exit(0)
        }

        // Bring the running app to front
        NSApplication.shared.activate(ignoringOtherApps: true)

        Task { @MainActor in
            await Self.route(actionID: actionID, userInfo: userInfo, appState: Self.sharedAppState)
        }

        completionHandler()
    }

    /// The notification-response routing table. Shared by a response this instance
    /// received itself and one forwarded from a duplicate that deferred to it.
    @MainActor
    static func route(actionID: String, userInfo: [AnyHashable: Any], appState: AppState?) async {
        switch userInfo["type"] as? String {
        case "decision":
            if let digestID = userInfo["digestId"] as? Int {
                appState?.navigateToDigest(digestID)
            } else {
                appState?.selectedDestination = .digests
            }
        case "track", "track_update":
            appState?.selectedDestination = .tracks
        case "task_overdue", "target_extract":
            appState?.selectedDestination = .targets
        case "daily_summary":
            appState?.selectedDestination = .digests
        case "meeting_reminder":
            await handleMeetingReminderAction(actionID: actionID, userInfo: userInfo, appState: appState)
        case "meeting_stop_recording":
            if actionID == NotificationService.stopRecordingActionID {
                if let appState {
                    await appState.meetingRecorderCenter.stopAndProcess(config: .fromDefaults())
                } else {
                    // appState not wired yet (tap raced app launch): never
                    // drop an explicit Stop-recording intent silently.
                    print("[MeetingReminder] stop-recording action dropped: appState unavailable")
                }
            } else {
                appState?.selectedDestination = .calendar
            }
        default:
            break
        }
    }

    /// Pre-meeting push actions: Join / Join + Record route through the shared
    /// `JoinMeetingAction` ("Join + Record" forces recording regardless of the
    /// auto-record setting); a plain tap navigates to the Calendar tab.
    /// `openURL` is an injectable seam (the `JoinMeetingAction` convention);
    /// internal rather than private so tests can drive the fallback branches.
    @MainActor
    static func handleMeetingReminderAction(
        actionID: String,
        userInfo: [AnyHashable: Any],
        appState: AppState?,
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) async {
        guard actionID == NotificationService.joinActionID
            || actionID == NotificationService.joinRecordActionID else {
            appState?.selectedDestination = .calendar
            return
        }

        var event: CalendarEvent?
        if let appState, let pool = appState.databaseManager?.dbPool,
           let eventID = userInfo["eventId"] as? String {
            do {
                event = try await pool.read { db in try CalendarQueries.fetchEvent(db, id: eventID) }
            } catch {
                // A DB error must not silently drop an explicit Join(+Record)
                // tap — log, then fall through to the conferenceUrl fallback.
                print("[MeetingReminder] action event fetch error: \(error.localizedDescription)")
            }
        }

        if let appState, let event {
            await JoinMeetingAction.join(
                event: event,
                center: appState.meetingRecorderCenter,
                forceRecord: actionID == NotificationService.joinRecordActionID,
                openURL: openURL
            )
        } else if let urlString = userInfo["conferenceUrl"] as? String,
                  let url = URL(string: urlString) {
            // Event vanished between push and tap — still open the link.
            // (URL(string:) already rejects the empty string.)
            _ = openURL(url)
        } else {
            // Nothing to join: make the tap do something visible instead of
            // silently nothing — land the user on the Calendar tab.
            appState?.selectedDestination = .calendar
        }
    }
}

@main
struct WatchtowerApp: App {
    @State private var appState = AppState()
    private let notificationDelegate = NotificationDelegate()
    private let isDuplicate: Bool

    init() {
        // Stored-property initializers (`appState`, `notificationDelegate`) run BEFORE
        // this guard, so they must stay side-effect-free — a duplicate instance
        // constructs them and then exits. Heavy work belongs in `AppState.initialize()`.
        if let survivor = SingleInstanceGuard.runningInstanceToDeferTo() {
            // Duplicate: stay alive, headless, only long enough for the notification
            // response that launched this process to arrive and be forwarded. With no
            // response the two seconds elapse and this degrades to activate-and-exit.
            isDuplicate = true
            NSApplication.shared.setActivationPolicy(.prohibited)
            NotificationDelegate.forwardMode = true
            UNUserNotificationCenter.current().delegate = notificationDelegate
            let activated = survivor.activate()
            NSLog(
                "SingleInstanceGuard: duplicate instance, deferring to pid %d (activate: %@); exiting",
                survivor.processIdentifier,
                activated ? "ok" : "denied"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(0) }
            return
        }

        isDuplicate = false
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        NotificationService.registerMeetingCategories()
        // Only the survivor listens: a duplicate must never route what it forwards.
        NotificationForwarding.observe { response in
            Task { @MainActor in
                await NotificationDelegate.route(
                    actionID: response.actionID,
                    userInfo: response.userInfo,
                    appState: NotificationDelegate.sharedAppState
                )
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            // A duplicate is headless for its grace window: no UI to flash, and no
            // `AppState.initialize()` running a second time against the shared database.
            if isDuplicate {
                EmptyView()
            } else {
                NavigationRoot()
                    .frame(minWidth: 800, minHeight: 600)
                    .overlay(alignment: .bottomTrailing) {
                        RecordingIndicatorView()
                    }
                    .overlay(alignment: .bottomTrailing) {
                        ExtractIndicatorView()
                    }
                    // Separate alignment from the recording/extract indicators'
                    // corner, so the banner and the pills never overlap.
                    .overlay(alignment: .top) {
                        UpcomingMeetingBannerView()
                    }
                    .background(OpaqueWindowBackground())
                    // `.environment` must wrap the overlay too: the overlay attaches as a
                    // sibling outside any environment applied deeper on NavigationRoot, so
                    // injecting here (outermost) is what lets RecordingIndicatorView's
                    // @Environment(AppState.self) resolve instead of trapping on launch.
                    .environment(appState)
                    .onAppear {
                        // H5 fix: connect the live SwiftUI-managed appState to the notification delegate
                        NotificationDelegate.sharedAppState = appState
                        appState.initialize()
                    }
                    .onOpenURL { url in
                        // Handle watchtower-auth:// callback — just bring app to front
                        if url.scheme == "watchtower-auth" {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                    }
                    // Claim external URL events for the EXISTING window — without
                    // this, WindowGroup spawns a brand-new window per open-URL.
                    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            }
        }
        .defaultSize(width: 1200, height: 800)

        Window("Pipeline Progress", id: "progress-detail") {
            ProgressDetailView()
                .environment(appState)
        }
        .defaultSize(width: 600, height: 500)

        Settings {
            SettingsView()
                .environment(appState)
                .background(SettingsWindowAccessor())
        }
    }
}

/// Makes the Settings window appear on the same fullscreen Space as the main window.
struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowView { SettingsWindowView() }
    func updateNSView(_ nsView: SettingsWindowView, context: Context) {}
}

class SettingsWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.level = .floating
        // Reset to normal level after a brief delay so the window doesn't stay always-on-top
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            window?.level = .normal
            window?.collectionBehavior.remove(.canJoinAllSpaces)
            window?.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }
}

/// Inserts an opaque NSView that fills the entire window behind all SwiftUI content.
struct OpaqueWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> OpaqueBackgroundView {
        let view = OpaqueBackgroundView()
        return view
    }

    func updateNSView(_ nsView: OpaqueBackgroundView, context: Context) {}
}

class OpaqueBackgroundView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        // Persist window frame (position + size) across launches
        window.setFrameAutosaveName("WatchtowerMainWindow")

        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor

        // Insert an opaque layer behind the entire content view hierarchy
        if let contentView = window.contentView {
            contentView.wantsLayer = true

            // Add opaque background layer at the bottom of the layer stack
            let bgLayer = CALayer()
            bgLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
            bgLayer.zPosition = -1000
            bgLayer.frame = contentView.bounds
            bgLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            contentView.layer?.insertSublayer(bgLayer, at: 0)

            // Also set layer itself opaque
            contentView.layer?.isOpaque = true
            contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
