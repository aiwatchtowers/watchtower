import os
import SwiftUI
import UIKit

/// The silent-push wake path: CKSyncEngine owns subscriptions and push
/// registration; the app turns a `content-available` push into a fetch.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set once the environment exists. Static because a background push
    /// launch reaches the delegate before any view appears; weak because
    /// the app's boot state owns the environment.
    @MainActor static weak var environment: AppEnvironment?

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            guard let env = Self.environment else {
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
    /// never a crash.
    private enum Boot {
        case ready(AppEnvironment)
        case failed(String)

        @MainActor
        static func make() -> Self {
            do {
                let env = try AppEnvironment()
                AppDelegate.environment = env
                // Only the live transport has an engine for a push to wake;
                // the demo path registers for nothing.
                if env.transportKind == .cloudKit {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                return .ready(env)
            } catch {
                Logger(subsystem: "WatchtowerMobile", category: "Boot")
                    .critical("replica failed to open: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        }
    }

    @State private var boot = Boot.make()

    var body: some Scene {
        WindowGroup {
            switch boot {
            case let .ready(env):
                RootTabView()
                    .environment(env)
            case let .failed(message):
                BootFailureView(message: message)
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
