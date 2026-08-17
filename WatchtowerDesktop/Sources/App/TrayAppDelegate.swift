import AppKit
import ServiceManagement
import WatchtowerCore

/// App is in the Dock while it has a visible window; menu-bar-only otherwise.
enum ActivationPolicyDecision {
    static func policy(hasVisibleWindow: Bool) -> NSApplication.ActivationPolicy {
        hasVisibleWindow ? .regular : .accessory
    }

    /// Windows that earn a Dock icon: the ones the user can bring to front
    /// (main window, Settings, Pipeline Progress). Deliberately NOT
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
    /// Settings (`com_apple_SwiftUI_Settings_window`) and Pipeline Progress
    /// (`progress-detail-…`) never match.
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

    /// The one quit entry point for the surfaces we own (Cmd+Q via the
    /// replaced `.appTermination` command, tray "Quit Watchtower"). SwiftUI's
    /// scene layer vetoes app termination while any scene has a presented
    /// sheet — an AEQuit comes back "User cancelled" (-128) before
    /// `applicationShouldTerminate` is ever consulted, so with a popup open
    /// the app was simply unquittable (live-repro, 2026-08-16). Closing the
    /// sheet-carrying windows first removes the veto; termination then runs
    /// the normal daemon-stop flow below. Closing (not `endSheet`) is
    /// deliberate: Quit tears the window down anyway, and `close()` drops the
    /// scene synchronously.
    static func requestQuit() {
        for window in windowsBlockingTermination(NSApp.windows) {
            window.close()
        }
        NSApp.terminate(nil)
    }

    /// Filter half of `requestQuit`, split out for tests: the windows whose
    /// presented sheets make SwiftUI cancel termination.
    static func windowsBlockingTermination(_ windows: [NSWindow]) -> [NSWindow] {
        windows.filter { $0.attachedSheet != nil }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.terminateDecision(
            managesLifecycle: managesLifecycle,
            hasBlockingWork: AppState.shared.meetingRecorderCenter.isBusy,
            confirmQuit: Self.confirmQuitDuringWork,
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
        confirmQuit: () -> Bool,
        stopDaemon: @escaping () async -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard managesLifecycle else { return .terminateNow }
        return QuitCoordinator.shouldTerminate(
            hasBlockingWork: hasBlockingWork,
            confirmQuit: confirmQuit,
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

    private static func confirmQuitDuringWork() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A recording or transcription is in progress"
        alert.informativeText = "Quitting stops the capture and drops any transcription still running. "
            + "The audio recorded so far is kept and offered again on next launch."
        alert.addButton(withTitle: "Stop & Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
