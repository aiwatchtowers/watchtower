import Foundation
@testable import WatchtowerDesktop
import WatchtowerCore

/// Readiness inputs for tests: Slack connected and synced once, the daemon
/// up, everything else set per test. Reads no file.
@MainActor
final class FakeReadinessEnvironment: ReadinessEnvironment {
    var now = Date()
    var daemonRunning = true
    var daemonNotRunningSince: Date?
    var syncProgress: SyncProgress?
    var lastSyncTime: Date? = Date().addingTimeInterval(-3600)
    var disabledFeatureIDs: Set<String> = []
    var connected = ConnectedSources(slack: true)
    var briefingHour = 8
    var dayPlanHour = 8
    var pollInterval: String?
    var backfillDays: Int?
    var stamps: [String: Date] = [:]
    func stamp(_ fileName: String) -> Date? { stamps[fileName] }
}
