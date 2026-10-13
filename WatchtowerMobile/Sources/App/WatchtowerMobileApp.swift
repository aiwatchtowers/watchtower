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
        // A launch that reads `.background` here (a silent push, a prewarm —
        // and, in a scene-based app, a tap too) starts the replica
        // observations suspended; the scene's first non-background phase
        // resumes them (`WatchtowerMobileApp`). Never while hosting XCTest
        // (the guard above): the tests drive their own gates.
        if application.applicationState == .background {
            MainActor.assumeIsolated { ReplicaObservationGate.shared.setSuspended(true) }
        }
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
        // (`AppEnvironment.handlePush`), and each push gets its completion
        // when the fetch serving it ends or at iOS's deadline, whichever
        // comes first (`PushCompletion`). In the foreground a fallback fetch
        // also polls the zones. The arrival is stamped here, before any
        // hop, so the CloudKit run that covers it is one begun after it.
        let arrivedAt = Date()
        let inForeground = application.applicationState == .active
        Task { @MainActor in
            guard let env = Self.root?.env else {
                Self.logger.warning("remote notification with no environment (degraded boot?)")
                completionHandler(.noData)
                return
            }
            PushCompletion.serve(
                env, arrivedAt: arrivedAt, inForeground: inForeground,
                startWork: BackgroundWork.starter(),
                completion: { completionHandler($0.backgroundFetchResult) }
            )
        }
    }
}

/// A silent push's completion within iOS's budget (~30 s of background
/// time): the fetch serving the push races `deadline`, and whichever ends
/// first completes, exactly once. A fetch past the deadline keeps going —
/// inside the push's background task (`BackgroundWork`), so iOS does not suspend
/// the app mid-transaction — and only its report is dropped.
@MainActor
enum PushCompletion {
    /// Under iOS's ~30 s, with room for the completion itself.
    nonisolated static let deadline: Duration = .seconds(25)

    /// `outcomeAtDeadline` is what the deadline reports. `sleep` is the
    /// deadline's wait (tests step it).
    static func race(
        deadline: Duration = Self.deadline,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fetch: @escaping @MainActor () async -> FetchOutcome,
        outcomeAtDeadline: @escaping @MainActor () -> FetchOutcome,
        completion: @escaping @MainActor (FetchOutcome) -> Void
    ) {
        let once = Once()
        let timer = Task { @MainActor in
            do {
                try await sleep(deadline)
            } catch {
                return
            }
            if once.claim() {
                completion(outcomeAtDeadline())
            }
        }
        Task { @MainActor in
            let outcome = await fetch()
            timer.cancel()
            if once.claim() {
                completion(outcome)
            }
        }
    }

    /// One silent push on `env`: a background task keeps the app running
    /// until the fetch returns, past a completion sent at the deadline, and
    /// the replica is held usable meanwhile (`BackgroundWork`). A push that
    /// launched the app may be served before the boot's own writes ran: the
    /// work lasts until the boot ends too, without holding back the
    /// completion. The deadline reports `.noData`: the push's own fetch has
    /// not ended then, so nothing says it failed.
    static func serve(
        _ env: AppEnvironment,
        arrivedAt: Date,
        inForeground: Bool,
        startWork: BackgroundWork.Starter,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        completion: @escaping @MainActor (FetchOutcome) -> Void
    ) {
        let endWork = startWork("silent-push-fetch")
        race(
            sleep: sleep,
            fetch: {
                let outcome = await env.handlePush(at: arrivedAt, inForeground: inForeground)
                Task { @MainActor in
                    await env.waitForBoot()
                    endWork()
                }
                return outcome
            },
            outcomeAtDeadline: { .noData },
            completion: completion
        )
    }

    /// The once-flag: the first `claim()` wins.
    @MainActor
    private final class Once {
        private var claimed = false

        func claim() -> Bool {
            defer { claimed = true }
            return !claimed
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
        /// The Keychain is locked (a push launched the app before the first
        /// unlock since a restart): the device id cannot be read, and a new
        /// one would unlink the phone from its Mac. The boot runs again once
        /// protected data is available.
        case waitingForUnlock
        case hostingTests

        /// The app only hosts XCTest: the scene drives no gates.
        var isTestHost: Bool {
            if case .hostingTests = self { return true }
            return false
        }

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
            } catch let locked as DeviceIDKeychain.Unavailable where locked.isLocked {
                Logger(subsystem: "WatchtowerMobile", category: "Boot")
                    .notice("keychain locked before the first unlock: the boot waits for it")
                return .waitingForUnlock
            } catch {
                Logger(subsystem: "WatchtowerMobile", category: "Boot")
                    .critical("boot failed: \(error.localizedDescription, privacy: .public)")
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
                case .waitingForUnlock:
                    WaitingForUnlockView { boot = Boot.make() }
                case .hostingTests:
                    Color.clear
                }
            }
            // The first activation classifies a cold launch not yet
            // classified as a foreground one (`ColdLaunchClassifier`). The
            // replica observations rest while the app is in the background
            // and each delivers its latest value on the return; not while
            // the app only hosts XCTest (the tests drive their own gates).
            // A boot waiting for the unlock follows the phase too, so the
            // root it builds later finds the gates already open.
            .onChange(of: scenePhase, initial: true) {
                if scenePhase == .active { appDelegate.sceneBecameActive() }
                if !boot.isTestHost {
                    ReplicaObservationGate.shared.setSuspended(scenePhase == .background)
                    // The replica's file locks rest too (0xdead10cc).
                    DatabaseSuspension.shared.setBackground(scenePhase == .background)
                }
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
