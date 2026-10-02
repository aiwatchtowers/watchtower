import Foundation
@testable import WatchtowerDesktop

extension AppState {
    /// An AppState whose onboarding state lives in a throwaway suite, not
    /// the test runner's `.standard` domain (the v2 machine writes its step
    /// and drops the legacy keys on init). One shared suite, emptied per
    /// instance, so a run leaves no per-test plist behind; no test reads
    /// another instance's onboarding keys.
    static func isolated() -> AppState {
        let name = "WatchtowerDesktopTests.onboarding"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return AppState(onboardingDefaults: UserDefaults(suiteName: name) ?? .standard)
    }
}
