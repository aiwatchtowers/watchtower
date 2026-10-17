import Foundation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

extension AppState {
    /// An AppState for tests: its onboarding state lives in a throwaway
    /// suite, not the test runner's `.standard` domain (the v2 machine writes
    /// its step and drops the legacy keys on init), and nothing it would
    /// start on its own spawns a process or asks macOS for a permission —
    /// the people load, completion's daemon start and the app-wide DB wiring
    /// are no-ops unless a test passes its own. The workbench page's state
    /// (layouts, inspector) lives in the same suite. One suite per test
    /// process, emptied per instance, so a run leaves no per-test plist
    /// behind. Readiness reads a fake environment, never the live config,
    /// workspace directory or stamps; Home's Getting ready memory lives in
    /// the same suite.
    static func isolated(
        openDatabase: @escaping @Sendable () throws -> DatabaseManager = { throw CocoaError(.fileNoSuchFile) },
        peopleRosterRun: @escaping PeopleRosterLoad.Run = { _, _ in (0, "") },
        featuresRunner: any CLIRunnerProtocol = FakeCLIRunner(stdout: Data(#"{"features":[]}"#.utf8)),
        onboardingGoals: ((UserDefaults) -> OnboardingGoalsModel)? = nil
    ) -> AppState {
        UserDefaults.standard.removePersistentDomain(forName: isolatedSuiteName)
        let defaults = isolatedDefaults
        let appState = AppState(
            onboardingDefaults: defaults,
            workbenchDefaults: defaults,
            openDatabase: openDatabase,
            peopleRosterRun: peopleRosterRun,
            featureManager: FeatureManagerService(runner: featuresRunner),
            onboardingGoals: onboardingGoals?(defaults)
        )
        appState.daemonControlOverride = FakeDaemon()
        appState.wireAppDatabaseOverride = { _ in }
        appState.readinessEnvironmentOverride = FakeReadinessEnvironment()
        appState.homeDefaultsOverride = defaults
        isolatedAppStates.append(WeakAppState(appState))
        return appState
    }

    /// Stops the sidebar counts of every `isolated()` app state made since
    /// the last call (`stopSidebarCounts()`), for a test case whose tearDown
    /// deletes the database after an onboarding finish built them.
    static func stopIsolatedSidebarCounts() async {
        let made = isolatedAppStates
        isolatedAppStates = []
        for state in made.compactMap(\.value) {
            await state.stopSidebarCounts()?.value
        }
    }

    /// The suite `isolated()` hands out. scripts/swift-test-sharded.sh runs
    /// the suite as concurrent processes and gives each its own
    /// WATCHTOWER_TEST_SHARD: preferences are shared across processes, so one
    /// fixed name would let a shard's `isolated()` empty another's live suite.
    static var isolatedSuiteName: String {
        let shard = ProcessInfo.processInfo.environment["WATCHTOWER_TEST_SHARD"].map { ".shard\($0)" } ?? ""
        return "WatchtowerDesktopTests.onboarding" + shard
    }

    static var isolatedDefaults: UserDefaults {
        UserDefaults(suiteName: isolatedSuiteName) ?? .standard
    }

    /// Stops the sidebar counts `completeOnboarding()` builds before the
    /// test's database goes (board #526): the build is cancelled — one not
    /// started yet builds nothing — and a built view model stops observing.
    /// Returns the build, for an async test to await.
    @discardableResult
    func stopSidebarCounts() -> Task<Void, Never>? {
        let setup = sidebarCountsSetup
        setup?.cancel()
        sidebarCountsViewModel?.stopObserving()
        return setup
    }
}

/// Counts the daemon calls; `running` is what it reports, `startSucceeds`
/// and `restartError` what start and restart do. `holdRestart` parks a
/// restart until `releaseRestart()`.
@MainActor
final class FakeDaemon: DaemonControl {
    var running = false
    var startSucceeds = true
    var restartError: Error?
    var holdRestart = false
    /// The stopped daemon's process never goes.
    var stopTimesOut = false
    private(set) var waits = 0
    private(set) var starts = 0
    private(set) var restarts = 0
    private(set) var stops = 0
    private var parked: CheckedContinuation<Void, Never>?

    var isRestartParked: Bool { parked != nil }

    func daemonIsRunning() -> Bool { running }

    func startDetached() async -> Bool {
        starts += 1
        running = startSucceeds
        return startSucceeds
    }

    func restartWaiting() async throws {
        restarts += 1
        if holdRestart {
            await withCheckedContinuation { parked = $0 }
        }
        if let restartError { throw restartError }
        running = true
    }

    func stopDaemonNow() async {
        stops += 1
        running = false
    }

    func waitUntilStopped() async throws {
        waits += 1
        if stopTimesOut { throw DaemonRestartError.stopTimedOut(pid: 4242) }
    }

    func releaseRestart() {
        parked?.resume()
        parked = nil
    }
}

@MainActor private var isolatedAppStates: [WeakAppState] = []

private struct WeakAppState {
    weak var value: AppState?

    init(_ value: AppState) {
        self.value = value
    }
}
