import os
import SwiftUI
import UIKit
import WatchtowerSync

/// The silent-push wake path: CKSyncEngine owns subscriptions and push
/// registration (and fetches on a push by itself); the app turns a
/// `content-available` push into a light fetch that rides the engine's.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set once the root exists. Static because a background push launch
    /// reaches the delegate before any view appears; weak because the
    /// app's boot state owns the root. Read through the root, since the link
    /// flow replaces its environment.
    @MainActor static weak var root: AppRoot?

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppDelegate")

    /// Keeps MetricKit's reports for Settings → Battery; held for the
    /// process's lifetime.
    private var metricSubscriber: MetricSubscriber?

    /// Whether this process counts its cold launch: not while it only
    /// hosts XCTest.
    private var countsLaunch = false
    private var coldLaunch = ColdLaunchClassifier()

    /// Starts classifying the cold launch (`ColdLaunchClassifier`) and
    /// subscribes to MetricKit. Nothing while the app only hosts XCTest.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard !WatchtowerMobileApp.Boot.isHostingTests(environment) else { return true }
        countsLaunch = true
        let diagnostics = BatteryDiagnostics.shared
        recordColdLaunch(coldLaunch.launched(
            forRemoteNotification: launchOptions?[.remoteNotification] != nil,
            prewarmed: ColdLaunchClassifier.isPrewarmed(environment)
        ))
        let subscriber = MetricSubscriber(history: diagnostics.metrics)
        subscriber.register()
        metricSubscriber = subscriber
        return true
    }

    /// The scene became active: the first activation of a process not yet
    /// classified is a foreground cold launch.
    func sceneBecameActive() {
        recordColdLaunch(coldLaunch.becameActive())
    }

    private func recordColdLaunch(_ event: EnergyEvent?) {
        guard countsLaunch, let event else { return }
        BatteryDiagnostics.shared.counter.record(event)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        BatteryDiagnostics.shared.counter.record(.silentPush)
        recordColdLaunch(coldLaunch.receivedPush())
        // Fetched at once; pushes landing during a fetch share one follow-up
        // (`AppEnvironment.handlePush`), and each push still gets its
        // completion when the fetch serving it ends. In the foreground a
        // fallback fetch also polls the zones.
        let inForeground = application.applicationState == .active
        Task { @MainActor in
            guard let env = Self.root?.env else {
                Self.logger.warning("remote notification with no environment (degraded boot?)")
                completionHandler(.noData)
                return
            }
            completionHandler(await env.handlePush(inForeground: inForeground).backgroundFetchResult)
        }
    }
}

extension FetchOutcome {
    /// What a silent push's completion reports to iOS.
    var backgroundFetchResult: UIBackgroundFetchResult {
        switch self {
        case .newData: .newData
        case .noData: .noData
        case .failed: .failed
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
            } catch {
                Logger(subsystem: "WatchtowerMobile", category: "Boot")
                    .critical("replica failed to open: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        }
    }

    @State private var boot = Boot.make()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch boot {
                case let .ready(root):
                    AppRootView(root: root)
                case let .failed(message):
                    BootFailureView(message: message)
                case .hostingTests:
                    Color.clear
                }
            }
            // The first activation classifies a cold launch not yet
            // classified as a foreground one (`ColdLaunchClassifier`).
            .onChange(of: scenePhase, initial: true) {
                if scenePhase == .active { appDelegate.sceneBecameActive() }
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
