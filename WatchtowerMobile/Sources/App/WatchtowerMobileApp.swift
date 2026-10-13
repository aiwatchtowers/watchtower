import os
import SwiftUI
import UIKit
import WatchtowerSync

/// The silent-push wake path: CKSyncEngine owns subscriptions and push
/// registration; the app turns a `content-available` push into a fetch.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set once the root exists. Static because a background push launch
    /// reaches the delegate before any view appears; weak because the
    /// app's boot state owns the root. Read through the root, since the link
    /// flow replaces its environment.
    @MainActor static weak var root: AppRoot?

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            guard let env = Self.root?.env else {
                Self.logger.warning("remote notification with no environment (degraded boot?)")
                completionHandler(.noData)
                return
            }
            completionHandler(await env.refresh() ? .newData : .failed)
        }
    }
}

@main
struct WatchtowerMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The live environment, or why the replica could not open. Every tab
    /// needs the store, so an open failure is a readable full-screen state,
    /// never a crash. While the app only hosts XCTest it boots nothing: no
    /// replica, demo seed, recorder recovery, fetch loop or push
    /// registration runs beside the environments the tests build.
    enum Boot {
        case ready(AppRoot)
        case failed(String)
        /// The Keychain is locked (a push launched the app before the first
        /// unlock since a restart): the device id cannot be read
        /// (`KeyStoreError.locked`), and a new identity would unlink the
        /// phone from its Mac. The boot runs again once protected data is
        /// available.
        case waitingForUnlock
        case hostingTests

        /// XCTest sets `XCTestConfigurationFilePath` in the process it
        /// injects the test bundle into; a normal launch never has it.
        nonisolated static func isHostingTests(_ environment: [String: String]) -> Bool {
            environment["XCTestConfigurationFilePath"] != nil
        }

        @MainActor
        /// `makeRoot` is for tests: the app builds its own.
        static func make(
            processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
            makeRoot: @MainActor () throws -> AppRoot = { try AppRoot.live() }
        ) -> Self {
            if isHostingTests(processEnvironment) {
                return .hostingTests
            }
            do {
                let root = try makeRoot()
                AppDelegate.root = root
                // Only the live transport has an engine for a push to wake;
                // the demo path registers for nothing.
                if root.env.transportKind == .cloudKit {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                return .ready(root)
            } catch KeyStoreError.locked {
                Logger(subsystem: "WatchtowerMobile", category: "Boot")
                    .notice("keychain locked before the first unlock: the boot waits for it")
                return .waitingForUnlock
            } catch let keychain as KeyStoreError {
                Logger(subsystem: "WatchtowerMobile", category: "Boot")
                    .critical("boot failed: keychain \(String(describing: keychain), privacy: .public)")
                return .failed("The Keychain could not read this iPhone's Watchtower keys (\(keychain)).")
            } catch {
                Logger(subsystem: "WatchtowerMobile", category: "Boot")
                    .critical("boot failed: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        }
    }

    @State private var boot = Boot.make()

    var body: some Scene {
        WindowGroup {
            switch boot {
            case let .ready(root):
                AppRootView(root: root)
            case let .failed(message):
                BootFailureView(message: message)
            case .waitingForUnlock:
                WaitingForUnlockView { boot = Boot.make() }
            case .hostingTests:
                Color.clear
            }
        }
    }
}

/// Full-screen state for a replica that cannot open.
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

/// The boot while the Keychain is locked (`Boot.waitingForUnlock`): asks
/// for the unlock and retries the boot until it gets past the lock. It
/// retries on `protectedDataDidBecomeAvailable`, and every
/// `retryInterval` while protected data is available: a background launch
/// may draw nothing until the owner opens the app, by when the
/// notification has passed, and a retry that is still locked out leaves
/// this view up, so the loop tries again.
struct WaitingForUnlockView: View {
    static let retryInterval: Duration = .seconds(2)
    let retry: @MainActor () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Unlock your iPhone to continue", systemImage: "lock")
        } description: {
            Text("Watchtower starts once this iPhone is unlocked.")
        }
        .task {
            while !Task.isCancelled {
                if UIApplication.shared.isProtectedDataAvailable {
                    retry()
                }
                try? await Task.sleep(for: Self.retryInterval)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            retry()
        }
    }
}
