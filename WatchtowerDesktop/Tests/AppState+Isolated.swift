import Foundation
@testable import WatchtowerDesktop
import WatchtowerCore

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
        peopleRosterRun: @escaping PeopleRosterLoad.Run = { _, _ in (0, "") }
    ) -> AppState {
        let name = "WatchtowerDesktopTests.onboarding"
        UserDefaults.standard.removePersistentDomain(forName: name)
        let appState = AppState(
            onboardingDefaults: UserDefaults(suiteName: name) ?? .standard,
            openDatabase: openDatabase,
            peopleRosterRun: peopleRosterRun
        )
        appState.onboardingDaemonOverride = FakeOnboardingDaemon()
        appState.wireAppDatabaseOverride = { _ in }
        return appState
    }
}

/// Counts finish's daemon calls; `running` is what it reports.
@MainActor
final class FakeOnboardingDaemon: OnboardingDaemonControl {
    var running = false
    private(set) var starts = 0
    private(set) var restarts = 0

    func daemonIsRunning() -> Bool { running }

    func startDaemon() async {
        starts += 1
        running = true
    }

    func restartDaemon() async {
        restarts += 1
    }
}
