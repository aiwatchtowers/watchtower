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

    /// True on a duplicate instance that lost the single-instance race: it routes
    /// nothing itself, it hands the response to the survivor and exits. Fixed at
    /// construction by the guard's verdict, never flipped afterwards.
    let forwardMode: Bool

    init(forwardMode: Bool) {
        self.forwardMode = forwardMode
        super.init()
    }

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

        if forwardMode {
            let posted = NotificationForwarding.post(actionID: actionID, userInfo: userInfo)
            completionHandler()
            if posted {
                // "posted", not "delivered": the distributed-notification transport
                // gives no acknowledgement, so a survivor that never observes it is
                // indistinguishable from here.
                NSLog("NotificationDelegate: posted response for action %@ to the running instance; exiting", actionID)
            } else {
                NSLog("NotificationDelegate: could not forward response for action %@; exiting", actionID)
            }
            // The response is what this process was waiting for — no reason to sit
            // out the rest of the grace window, and no reason to stay on a failed
            // hand-off either: the survivor is already running.
            exit(0)
        }

        // Bring the running app to front
        NSApplication.shared.activate(ignoringOtherApps: true)

        Task { @MainActor in
            await Self.route(actionID: actionID, userInfo: userInfo, appState: Self.sharedAppState, forwarded: false)
        }

        completionHandler()
    }

    /// Survivor side of the forwarding bus: routes a response handed over by a
    /// duplicate that deferred to this instance. The sole caller of `route` with
    /// `forwarded: true` in the app, so the navigation-only policy is applied by
    /// construction rather than by each call site remembering the flag.
    @MainActor
    static func routeForwarded(_ response: ForwardedNotificationResponse, appState: AppState?) async {
        // Mirror the self-received path: the click was meant to surface the app.
        NSApplication.shared.activate(ignoringOtherApps: true)
        await route(
            actionID: response.actionID,
            userInfo: response.userInfo,
            appState: appState,
            forwarded: true
        )
    }

    /// The notification-response routing table. Shared by a response this instance
    /// received itself and one forwarded from a duplicate that deferred to it.
    ///
    /// `forwarded` marks the second case, and downgrades routing to navigation only:
    /// the forwarding bus is unauthenticated, so a response arriving on it may move the
    /// UI but must never arm an action (start or stop a recording, open a link) —
    /// navigation itself may still carry idempotent UI side effects, e.g.
    /// `navigateToDigest` marking the digest read. The gate is read here, in each
    /// action-bearing branch, before dispatch — `handleMeetingReminderAction` takes no
    /// `forwarded` flag of its own — so widening the wire payload cannot re-open it.
    ///
    /// The keys the FORWARDED branches read (`type`, `digestId`) must stay in sync with
    /// `NotificationForwarding.routedKeys`, the allowlist of what crosses the boundary.
    /// The self-received branches legitimately read more (`eventId`, `conferenceUrl`):
    /// those keys are absent by design from the forwarded payload and must stay so.
    /// `openURL` is an injectable seam threaded through to the meeting handler (the
    /// `JoinMeetingAction` convention), so tests can prove the forwarded path never opens.
    @MainActor
    static func route(
        actionID: String,
        userInfo: [AnyHashable: Any],
        appState: AppState?,
        forwarded: Bool,
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) async {
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
            if forwarded {
                // Say it out loud rather than degrading in silence — the same
                // principle as the dropped-Stop-intent log below.
                NSLog(
                    "NotificationDelegate: forwarded action %@ downgraded to navigation (unauthenticated bus)",
                    actionID
                )
                appState?.selectedDestination = .calendar
            } else {
                await handleMeetingReminderAction(
                    actionID: actionID,
                    userInfo: userInfo,
                    appState: appState,
                    openURL: openURL
                )
            }
        case "meeting_stop_recording":
            if forwarded || actionID != NotificationService.stopRecordingActionID {
                if forwarded {
                    NSLog(
                        "NotificationDelegate: forwarded action %@ downgraded to navigation (unauthenticated bus)",
                        actionID
                    )
                }
                appState?.selectedDestination = .calendar
            } else if let appState {
                await appState.meetingRecorderCenter.stopAndProcess(config: .fromDefaults())
            } else {
                // appState not wired yet (tap raced app launch): never
                // drop an explicit Stop-recording intent silently.
                print("[MeetingReminder] stop-recording action dropped: appState unavailable")
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
    /// It carries no default — `route` is the seam's entry point and owns the one.
    @MainActor
    static func handleMeetingReminderAction(
        actionID: String,
        userInfo: [AnyHashable: Any],
        appState: AppState?,
        openURL: (URL) -> Bool
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
    /// How long a deferring duplicate stays alive headless, waiting for the
    /// notification response that launched it.
    private static let duplicateGraceWindow: TimeInterval = 5

    @NSApplicationDelegateAdaptor(TrayAppDelegate.self) private var trayDelegate
    @State private var appState = AppState()
    private let notificationDelegate: NotificationDelegate
    private let isDuplicate: Bool

    init() {
        // `appState`'s stored-property initializer runs BEFORE this guard, so it must
        // stay side-effect-free — a duplicate instance constructs it and then exits.
        // Heavy work belongs in `AppState.initialize()`.
        let survivor = SingleInstanceGuard.runningInstanceToDeferTo()
        isDuplicate = survivor != nil
        notificationDelegate = NotificationDelegate(forwardMode: isDuplicate)
        UNUserNotificationCenter.current().delegate = notificationDelegate

        if let survivor {
            // Duplicate: stay alive, headless, only long enough for the notification
            // response that launched this process to arrive and be forwarded. With no
            // response the grace window elapses and this degrades to activate-and-exit.
            //
            // Activate the survivor BEFORE dropping out of the activation model: a
            // `.prohibited` process may not donate activation.
            let activated = survivor.activate()
            NSApplication.shared.setActivationPolicy(.prohibited)
            // The duplicate deliberately does NOT call
            // `NotificationService.registerMeetingCategories()`: categories are
            // per-bundle-id state in the notification daemon, so registering here would
            // race the survivor's set — and `actionIdentifier` is delivered regardless.
            NSLog(
                "SingleInstanceGuard: duplicate instance, deferring to pid %d (activate: %@); exiting",
                survivor.processIdentifier,
                activated ? "ok" : "denied"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duplicateGraceWindow) { exit(0) }
            return
        }

        NSApplication.shared.setActivationPolicy(.regular)
        trayDelegate.managesLifecycle = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationService.registerMeetingCategories()
        // Only the survivor listens: a duplicate must never route what it forwards.
        NotificationForwarding.observe { response in
            NSLog("NotificationForwarding: received forwarded response for action %@", response.actionID)
            Task { @MainActor in
                await NotificationDelegate.routeForwarded(
                    response,
                    appState: NotificationDelegate.sharedAppState
                )
            }
        }
    }

    private var rootContent: some View {
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
            // Same outermost placement, same reason: link surfaces live
            // inside the overlays too (the recording indicator's panel,
            // the meeting banner), so the scheme gate has to wrap them.
            .environment(\.openURL, AllowedURLSchemes.openURLAction)
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

    var body: some Scene {
        WindowGroup(id: "main") {
            // A duplicate is headless for its grace window: no UI to flash, and no
            // `AppState.initialize()` running a second time against the shared database.
            if isDuplicate {
                EmptyView()
            } else {
                rootContent
            }
        }
        .defaultSize(width: 1200, height: 800)

        Window("Pipeline Progress", id: "progress-detail") {
            ProgressDetailView()
                .environment(appState)
                .environment(\.openURL, AllowedURLSchemes.openURLAction)
        }
        .defaultSize(width: 600, height: 500)

        Settings {
            SettingsView()
                .environment(appState)
                .background(SettingsWindowAccessor())
                .environment(\.openURL, AllowedURLSchemes.openURLAction)
        }

        MenuBarExtra("Watchtower", systemImage: "binoculars", isInserted: .constant(!isDuplicate)) {
            TrayMenuView()
                .environment(appState)
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
