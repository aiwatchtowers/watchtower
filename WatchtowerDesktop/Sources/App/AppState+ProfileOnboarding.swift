import Foundation
import GRDB
import WatchtowerCore

/// The profile's `onboarding_done` read `reconcileOnboarding` decides on;
/// kept out of `AppState.swift`, which is at its SwiftLint file-length ceiling.
extension AppState {
    enum ProfileOnboarding {
        /// Profile missing or onboarding_done == false.
        case pending
        case done
        /// The read failed (logged).
        case unreadable
    }

    func checkProfileOnboarding(dbPool: DatabasePool) async -> ProfileOnboarding {
        do {
            return try await dbPool.read { db in
                guard let profile = try ProfileQueries.fetchCurrentProfile(db) else { return .pending }
                return profile.onboardingDone ? .done : .pending
            }
        } catch {
            print("[AppState] onboarding check failed: \(error.localizedDescription)")
            return .unreadable
        }
    }
}
