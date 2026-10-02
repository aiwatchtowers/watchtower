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
    /// are no-ops unless a test passes its own. One shared suite, emptied
    /// per instance, so a run leaves no per-test plist behind.
    static func isolated(
        openDatabase: @escaping @Sendable () throws -> DatabaseManager = { throw CocoaError(.fileNoSuchFile) },
        peopleRosterRun: @escaping PeopleRosterLoad.Run = { _, _ in (0, "") },
        featuresRunner: FakeCLIRunner = FakeCLIRunner(stdout: Data(#"{"features":[]}"#.utf8))
    ) -> AppState {
        let name = "WatchtowerDesktopTests.onboarding"
        UserDefaults.standard.removePersistentDomain(forName: name)
        let appState = AppState(
            onboardingDefaults: UserDefaults(suiteName: name) ?? .standard,
            openDatabase: openDatabase,
            peopleRosterRun: peopleRosterRun,
            featureManager: FeatureManagerService(runner: featuresRunner)
        )
        appState.daemonControlOverride = FakeDaemon()
        appState.wireAppDatabaseOverride = { _ in }
        return appState
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
