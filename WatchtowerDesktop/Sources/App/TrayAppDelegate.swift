import AppKit
import ServiceManagement

/// App is in the Dock while its main window is open; menu-bar-only otherwise.
enum ActivationPolicyDecision {
    static func policy(hasVisibleMainWindow: Bool) -> NSApplication.ActivationPolicy {
        hasVisibleMainWindow ? .regular : .accessory
    }
}

/// Owns the opinionated lifecycle: close-to-tray, login-item autostart
/// (straight to accessory), Dock reopen, and the single full-exit path.
/// A SingleInstanceGuard duplicate leaves `managesLifecycle` false and this
/// delegate inert — the duplicate's own grace-window exit(0) is the quit path.
final class TrayAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by WatchtowerApp.init only for the survivor instance.
    var managesLifecycle = false

    private static let loginItemRegisteredKey = "tray.loginItemRegistered"
    private var closeObserver: NSObjectProtocol?

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.frameAutosaveName == "WatchtowerMainWindow"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard managesLifecycle else { return }

        // Login-item launch: no window, straight to the tray. The launch
        // Apple event carries keyAELaunchedAsLogInItem in its propData.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginLaunch = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
        if isLoginLaunch {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows where Self.isMainWindow(window) {
                window.close()
            }
        }

        registerLoginItemOnce()

        // Close-to-tray: when the main window goes away, leave the Dock but
        // keep the tray (the app itself) alive. Deferred one runloop turn so
        // NSApp.windows reflects the close.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, Self.isMainWindow(window) else { return }
            DispatchQueue.main.async {
                let hasMain = NSApp.windows.contains { Self.isMainWindow($0) && $0.isVisible }
                NSApp.setActivationPolicy(ActivationPolicyDecision.policy(hasVisibleMainWindow: hasMain))
            }
        }
    }

    /// Dock icon / Finder reopen while living in the tray: back to a regular
    /// app. Returning true lets AppKit/SwiftUI restore or recreate the
    /// WindowGroup window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard managesLifecycle else { return true }
        if !flag {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard managesLifecycle else { return .terminateNow }
        return QuitCoordinator.shouldTerminate(
            isCapturing: NotificationDelegate.sharedAppState?.meetingRecorderCenter.isCapturing ?? false,
            confirmQuit: Self.confirmQuitDuringRecording,
            stopDaemon: { await DaemonManager.stopForQuit() },
            reply: { ok in sender.reply(toApplicationShouldTerminate: ok) }
        )
    }

    /// Register the login item exactly once. Never re-register: a user who
    /// disabled autostart in System Settings → Login Items must stay disabled,
    /// and a repeated register() would silently re-enable it.
    private func registerLoginItemOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.loginItemRegisteredKey) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: Self.loginItemRegisteredKey)
        } catch {
            // Manual launch is unaffected; retry next launch.
            NSLog("TrayAppDelegate: login item registration failed: %@", error.localizedDescription)
        }
    }

    private static func confirmQuitDuringRecording() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A meeting recording is in progress"
        alert.informativeText = "Quitting stops the capture. The audio recorded so far is kept and offered for transcription on next launch."
        alert.addButton(withTitle: "Stop Recording & Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
