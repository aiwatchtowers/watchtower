import Foundation
import os
import WatchtowerSync

/// The phone's battery diagnostics (board #724): the per-day counters of
/// wakes and CloudKit work, and the MetricKit history. One per process,
/// outside any `AppEnvironment` (the link flow replaces environments; the
/// counts span them). Settings → Battery reads it.
final class BatteryDiagnostics: Sendable {
    let counter: EnergyCounter
    let metrics: MetricHistory

    init(counter: EnergyCounter, metrics: MetricHistory) {
        self.counter = counter
        self.metrics = metrics
    }

    /// The live diagnostics: in the app group on a build that has it (the
    /// signed builds), else in the app's own defaults and Application
    /// Support, like the replica.
    static let shared = BatteryDiagnostics.live()

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "BatteryDiagnostics")

    private static func live() -> BatteryDiagnostics {
        let grouped = CloudKitTransport.entitlementPresent()
        let defaults = grouped ? UserDefaults(suiteName: AppEnvironment.appGroupID) ?? .standard : .standard
        let directory: URL?
        do {
            directory = grouped ? try AppEnvironment.appGroupDirectory() : try AppEnvironment.applicationSupportDirectory()
        } catch {
            logger.error("no directory for the metric history, keeping it in memory: \(error.localizedDescription, privacy: .public)")
            directory = nil
        }
        return BatteryDiagnostics(
            counter: EnergyCounter(defaults: defaults),
            metrics: MetricHistory(fileURL: directory?.appendingPathComponent("battery-metrics.json"))
        )
    }
}
