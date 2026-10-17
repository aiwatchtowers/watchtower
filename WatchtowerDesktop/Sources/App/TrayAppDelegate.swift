import AppKit
import CloudKit
import os
import ServiceManagement
import WatchtowerCore

/// App is in the Dock while it has a visible window; menu-bar-only otherwise.
enum ActivationPolicyDecision {
    static func policy(hasVisibleWindow: Bool) -> NSApplication.ActivationPolicy {
        hasVisibleWindow ? .regular : .accessory
    }

    /// Windows that earn a Dock icon: the ones the user can bring to front
    /// (main window, Settings, Logs, …). Deliberately NOT
    /// "main window only" — closing the main window while Settings is open
    /// must not strand a visible window in `.accessory`, where it has neither
    /// Dock icon nor menu bar. The MenuBarExtra's status-item window is
    /// permanently visible and would pin the app to `.regular` forever; it is
    /// excluded because a status-item/panel window cannot become main.
    static func hasVisibleAppWindow(_ windows: [NSWindow]) -> Bool {
        windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    /// The one "leave the tray, come back as a normal app" move, shared by the
    /// tray's Open action and the Dock/Finder reopen path.
    static func becomeRegularAndActivate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Owns the opinionated lifecycle: app bootstrap, close-to-tray, login-item
/// autostart (straight to accessory), Dock reopen, and the single full-exit
/// path. A SingleInstanceGuard duplicate leaves `managesLifecycle` false and
/// this delegate inert — the duplicate's own grace-window exit(0) is the quit
/// path.
final class TrayAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by WatchtowerApp.init only for the survivor instance.
    var managesLifecycle = false

    /// Scene id of the main `WindowGroup`. SwiftUI derives the window's
    /// `NSWindow.identifier` from it (`"main-AppWindow-1"` shape).
    static let mainWindowSceneID = "main"
    /// Frame autosave name stamped on the main window once its SwiftUI content
    /// mounts (see `OpaqueBackgroundView`).
    static let mainWindowAutosaveName = "WatchtowerMainWindow"

    /// UserDefaults key holding the bundle path the login item was registered
    /// for — a path, not a bare flag: a worktree dev build registering itself
    /// must not permanently latch out the real install (and vice versa).
    static let loginItemRegisteredPathKey = "tray.loginItemRegisteredBundlePath"

    /// How long after a login launch the delegate keeps closing a main window
    /// that SwiftUI materialises late.
    private static let loginLaunchCloseGrace: TimeInterval = 3

    private var closeObserver: NSObjectProtocol?
    private var loginLaunchObserver: NSObjectProtocol?
    /// ⌃⌥D — registered only for the survivor instance, same as everything
    /// else in `applicationDidFinishLaunching`. Retained here for the life of
    /// the app; `GlobalHotKey.deinit` tears it down if it's ever released.
    private var globalHotKey: GlobalHotKey?

    /// True for the main `WindowGroup` window. Keyed on the window identifier
    /// SwiftUI derives from the scene id, because that is set when the window
    /// is created — the frame autosave name is stamped only after the SwiftUI
    /// content mounts, which is too late for `applicationDidFinishLaunching`
    /// (the login-launch close ran against an unnamed window and matched
    /// nothing). The autosave name stays as a second, mount-time signal.
    /// Settings (`com_apple_SwiftUI_Settings_window`) and the other windows
    /// (`logs-…`, …) never match.
    static func isMainWindow(_ window: NSWindow) -> Bool {
        isMainWindowIdentifier(window.identifier?.rawValue)
            || window.frameAutosaveName == mainWindowAutosaveName
    }

    /// Identifier half of `isMainWindow`, split out so it is testable against
    /// the raw strings SwiftUI produces without building an NSWindow per case.
    static func isMainWindowIdentifier(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        return rawValue == mainWindowSceneID || rawValue.hasPrefix("\(mainWindowSceneID)-")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard managesLifecycle else { return }

        // Bootstrap is window-independent: a login launch closes (or never
        // opens) the main window, and everything the app needs to be alive —
        // migrations, the database, the CLI binary store, the daemon,
        // notification routing — hangs off `AppState.initialize()`. Reaching
        // it only from a window's `onAppear` meant a windowless launch got
        // none of it. `AppState.shared` IS the instance SwiftUI manages (the
        // App struct seeds its `@State` from the same singleton), so this
        // cannot pick up the stale copy the H5 note in WatchtowerApp warns
        // about; the `onAppear` call remains, idempotent via `isInitializing`.
        let appState = AppState.shared
        NotificationDelegate.sharedAppState = appState
        appState.initialize()

        if Self.isLoginLaunch() {
            enterTrayForLoginLaunch()
        }

        registerLoginItemOnce()

        // M3 fix-round: the willCloseNotification observer only recomputes
        // policy on window CLOSE, not open — from `.accessory` (no Dock
        // icon), opening the window without also activating left it behind
        // the frontmost app. Mirrors the tray's own "Open Watchtower" path.
        let hotKey = GlobalHotKey {
            ActivationPolicyDecision.becomeRegularAndActivate()
            AppState.shared.openQuickCapture?()
        }
        hotKey.register()
        globalHotKey = hotKey

        // Close-to-tray: when the last user-facing window goes away, leave the
        // Dock but keep the tray (the app itself) alive. Deferred one runloop
        // turn so NSApp.windows reflects the close.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(
                    ActivationPolicyDecision.policy(
                        hasVisibleWindow: ActivationPolicyDecision.hasVisibleAppWindow(NSApp.windows)
                    )
                )
            }
        }
    }

    /// A login-item launch: the launch Apple event carries
    /// `keyAELaunchedAsLogInItem` in its propData.
    private static func isLoginLaunch() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }

    /// Login-item launch: no window, straight to the tray. SwiftUI may
    /// materialise the WindowGroup window after this delegate callback, so the
    /// immediate close is backed by a short-lived observer that closes a main
    /// window arriving late. The observer is torn down as soon as the grace
    /// period elapses OR the app deliberately becomes regular again (tray
    /// "Open Watchtower", Dock/Finder reopen — see `endLoginLaunchClosing`'s
    /// call sites), so a user who opens the window from the tray is never
    /// fought.
    private func enterTrayForLoginLaunch() {
        NSApp.setActivationPolicy(.accessory)
        closeMainWindows()
        loginLaunchObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow, Self.isMainWindow(window) else { return }
            window.close()
            self?.endLoginLaunchClosing()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loginLaunchCloseGrace) { [weak self] in
            self?.endLoginLaunchClosing()
        }
    }

    private func closeMainWindows() {
        for window in NSApp.windows where Self.isMainWindow(window) {
            window.close()
        }
    }

    /// Torn down on grace-period expiry and from both places the app
    /// deliberately leaves the tray for a regular window (`TrayMenuView`'s
    /// "Open Watchtower" action, via `NSApp.delegate`, and
    /// `applicationShouldHandleReopen` below) — internal, not private, so the
    /// tray view can reach it.
    func endLoginLaunchClosing() {
        guard let observer = loginLaunchObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        loginLaunchObserver = nil
    }

    /// Dock icon / Finder reopen while living in the tray: back to a regular
    /// app. Returning true lets AppKit/SwiftUI restore or recreate the
    /// WindowGroup window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard managesLifecycle else { return true }
        if !flag {
            endLoginLaunchClosing()
            ActivationPolicyDecision.becomeRegularAndActivate()
        }
        return true
    }

    // MARK: - CloudKit pushes (the mobile hub)

    /// The hub registered for remote notifications
    /// (`MobileHubStorage.registerForPushes`); the token is CloudKit's
    /// business, only the outcome is logged.
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.pushLogger.notice("registered for CloudKit pushes")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.pushLogger.error("push registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// A silent CloudKit push (the CKSyncEngine's database subscription):
    /// the hub's relay loop pulls now instead of after its wait, so a
    /// linking phone's `device` record or a phone action is read at once.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard managesLifecycle, CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return }
        AppState.shared.mobileHub?.wakeRelay()
    }

    private static let pushLogger = Logger(subsystem: Constants.bundleID, category: "CloudKitPush")

    /// The one quit entry point for the surfaces we own (Cmd+Q via the
    /// replaced `.appTermination` command, tray "Quit Watchtower"). SwiftUI's
    /// scene layer vetoes app termination while any scene has a presented
    /// sheet — an AEQuit comes back "User cancelled" (-128) before
    /// `applicationShouldTerminate` is ever consulted, so with a popup open
    /// the app was simply unquittable (live-repro, 2026-08-16). Closing the
    /// sheet-carrying windows first removes the veto; termination then runs
    /// the normal daemon-stop flow below. Closing (not `endSheet`) is
    /// deliberate: Quit tears the window down anyway, and `close()` drops the
    /// scene synchronously. An update's relaunch passes `forUpdate`: that
    /// quit never asks about sessions and leaves the hosted ones running
    /// (PROJ-19).
    static func requestQuit(forUpdate: Bool = false) {
        for window in windowsBlockingTermination(NSApp.windows) {
            window.close()
        }
        quitIsForUpdate = forUpdate
        NSApp.terminate(nil)
        // Still running: the quit was cancelled, so the next one is not
        // an update's unless it says so.
        quitIsForUpdate = false
    }

    /// The quit `NSApp.terminate` is running now came from an update.
    private static var quitIsForUpdate = false

    /// Filter half of `requestQuit`, split out for tests: the windows whose
    /// presented sheets make SwiftUI cancel termination.
    static func windowsBlockingTermination(_ windows: [NSWindow]) -> [NSWindow] {
        windows.filter { $0.attachedSheet != nil }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let app = AppState.shared
        let plan = Self.quitPlan(
            forUpdate: Self.quitIsForUpdate,
            quitReason: Self.currentQuitReason(),
            recording: app.meetingRecorderCenter.isBusy,
            askDrafts: app.workbenchesViewModel?.asks.drafts.count ?? 0,
            liveSessions: app.terminalCenter.liveHostedCount
        )
        return Self.terminateDecision(
            managesLifecycle: managesLifecycle,
            hasBlockingWork: plan.prompt != nil,
            keepsSessions: plan.keepsSessions,
            confirmQuit: { plan.prompt.map { plan.choice(button: Self.runQuitAlert($0)) } ?? .cancel },
            closeChatSessions: { await app.chatSessionPool?.closeAll() },
            closeTerminals: { await app.terminalCenter.closeAll() },
            detachTerminals: { await app.terminalCenter.detachAll() },
            stopDaemon: { await DaemonManager.stopDaemonBounded() },
            reply: { ok in sender.reply(toApplicationShouldTerminate: ok) }
        )
    }

    /// The terminate decision, extracted from `applicationShouldTerminate` so
    /// the `managesLifecycle` gate is pinned by tests without a live
    /// NSApplication: a duplicate instance must quit immediately and must
    /// never touch the survivor's daemon.
    @MainActor
    static func terminateDecision(
        managesLifecycle: Bool,
        hasBlockingWork: Bool,
        keepsSessions: Bool = false,
        confirmQuit: () -> QuitChoice,
        closeChatSessions: @escaping () async -> Void = {},
        closeTerminals: @escaping () async -> Void = {},
        detachTerminals: @escaping () async -> Void = {},
        stopDaemon: @escaping () async -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard managesLifecycle else { return .terminateNow }
        return QuitCoordinator.shouldTerminate(
            hasBlockingWork: hasBlockingWork,
            confirmQuit: confirmQuit,
            keepsSessions: keepsSessions,
            closeChatSessions: closeChatSessions,
            closeTerminals: closeTerminals,
            detachTerminals: detachTerminals,
            stopDaemon: stopDaemon,
            reply: reply
        )
    }

    /// Register the login item once per installed bundle. Never re-register
    /// for the same bundle: a user who disabled autostart in System Settings →
    /// Login Items must stay disabled, and a repeated `register()` would
    /// silently re-enable it. The latch stores the bundle path rather than a
    /// bare flag, so a dev/worktree build that registered itself does not lock
    /// the real install out of ever registering. A failed registration leaves
    /// the latch unset — next launch retries.
    static func registerLoginItem(
        bundlePath: String,
        defaults: UserDefaults,
        register: () throws -> Void
    ) {
        guard defaults.string(forKey: loginItemRegisteredPathKey) != bundlePath else { return }
        do {
            try register()
            defaults.set(bundlePath, forKey: loginItemRegisteredPathKey)
        } catch {
            // Manual launch is unaffected; retry next launch.
            NSLog("TrayAppDelegate: login item registration failed: %@", error.localizedDescription)
        }
    }

    private func registerLoginItemOnce() {
        Self.registerLoginItem(bundlePath: Bundle.main.bundlePath, defaults: .standard) {
            try SMAppService.mainApp.register()
        }
    }

    /// What a quit asks before it drops work: a recording in progress,
    /// unsent ask answers (in memory only, spec 2026-10-03 Part 8), or live
    /// hosted workbench sessions (board #496) — one alert for all of them.
    /// nil = nothing to lose, quit without asking.
    struct QuitPrompt: Equatable {
        let message: String
        let informative: String
        let quitTitle: String
        /// The button that quits leaving the hosted sessions running; nil
        /// when no hosted session is live.
        var keepSessionsTitle: String?

        /// The alert's buttons, in order.
        var buttons: [String] {
            (keepSessionsTitle.map { [$0] } ?? []) + [quitTitle, "Cancel"]
        }
    }

    static func quitPrompt(recording: Bool, askDrafts: Int, liveSessions: Int = 0) -> QuitPrompt? {
        let drafts = askDrafts == 1 ? "1 unsent ask answer" : "\(askDrafts) unsent ask answers"
        let sessions = liveSessions == 1
            ? "1 workbench session is running"
            : "\(liveSessions) workbench sessions are running"
        let sessionsChoice = liveSessions == 1
            ? "Keep it running and Watchtower reattaches when you open it again, or stop it now."
            : "Keep them running and Watchtower reattaches when you open it again, or stop them now."
        let base: QuitPrompt
        if recording {
            base = QuitPrompt(
                message: "A recording or transcription is in progress",
                informative: "Quitting stops the capture and drops any transcription still running. "
                    + "The audio recorded so far is kept and offered again on next launch."
                    + (askDrafts > 0 ? " Your \(drafts) will be lost." : ""),
                quitTitle: "Stop & Quit"
            )
        } else if askDrafts > 0 {
            base = QuitPrompt(
                message: "You have \(drafts)",
                informative: "Drafts are kept only while Watchtower runs. Answer them from the workbench first, "
                    + "or quit and lose them.",
                quitTitle: "Quit"
            )
        } else if liveSessions > 0 {
            return QuitPrompt(
                message: sessions,
                informative: sessionsChoice,
                quitTitle: "Stop Sessions and Quit",
                keepSessionsTitle: "Keep Sessions and Quit"
            )
        } else {
            return nil
        }
        guard liveSessions > 0 else { return base }
        return QuitPrompt(
            message: base.message,
            informative: base.informative + " \(sessions). " + sessionsChoice,
            quitTitle: "Stop Sessions and Quit",
            keepSessionsTitle: "Keep Sessions and Quit"
        )
    }

    /// What one quit asks and does when it goes ahead unasked.
    struct QuitPlan: Equatable {
        let prompt: QuitPrompt?
        /// The quit leaves the hosted sessions running without asking: an
        /// update's, or the system ending the login session.
        let keepsSessions: Bool

        /// The choice behind the prompt's button at `index`
        /// (`QuitPrompt.buttons`). Without a Keep button, quitting keeps the
        /// sessions only when this quit keeps them anyway.
        func choice(button index: Int) -> QuitChoice {
            let choices: [QuitChoice] = prompt?.keepSessionsTitle != nil
                ? [.quitKeepingSessions, .quitStoppingSessions, .cancel]
                : [keepsSessions ? .quitKeepingSessions : .quitStoppingSessions, .cancel]
            return choices.indices.contains(index) ? choices[index] : .cancel
        }
    }

    /// An update's quit and a logout, restart or shutdown never ask about
    /// sessions and leave the hosted ones running (PROJ-19, spec §4.4); a
    /// recording or unsent answers still ask. Any other quit with a live
    /// hosted session asks Keep or Stop. `quitReason` is the quitting Apple
    /// event's `kAEQuitReason` (`currentQuitReason`), nil when there is none.
    static func quitPlan(
        forUpdate: Bool,
        quitReason: OSType?,
        recording: Bool,
        askDrafts: Int,
        liveSessions: Int
    ) -> QuitPlan {
        let keeps = forUpdate || quitReason.map(systemSessionEndReasons.contains) == true
        return QuitPlan(
            prompt: quitPrompt(recording: recording, askDrafts: askDrafts, liveSessions: keeps ? 0 : liveSessions),
            keepsSessions: keeps
        )
    }

    /// The `kAEQuitReason` values of a logout, restart or shutdown.
    static let systemSessionEndReasons: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
        OSType(kAERestart), OSType(kAEShowShutdownDialog), OSType(kAEShutDown)
    ]

    /// The quit reason of the Apple event being handled, if any.
    private static func currentQuitReason() -> OSType? {
        NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
    }

    /// Shows `prompt` and returns the index of the button pressed.
    private static func runQuitAlert(_ prompt: QuitPrompt) -> Int {
        let alert = NSAlert()
        alert.messageText = prompt.message
        alert.informativeText = prompt.informative
        for title in prompt.buttons {
            alert.addButton(withTitle: title)
        }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
