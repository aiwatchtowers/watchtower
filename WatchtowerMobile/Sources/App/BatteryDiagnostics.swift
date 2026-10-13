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

/// Decides, once per process, whether its cold launch was a background one
/// (iOS launched it for a silent push) or a foreground one (the owner
/// opened it). `UIApplication.applicationState` at launch cannot tell: a
/// scene-based app reads `.background` there even on a tap, and iOS
/// prewarming runs a process up to `didFinishLaunching` without any
/// launch by the owner. So the launch itself decides only when it carries
/// a remote notification; otherwise the first of a push (background) or
/// the scene's first activation (foreground) decides. A prewarmed process
/// was not launched for a push, so a push before its activation decides
/// nothing; its first activation is the owner's launch.
struct ColdLaunchClassifier {
    private var decided = false
    private var prewarmed = false

    /// `didFinishLaunching`: `forRemoteNotification` when the launch
    /// options carry `.remoteNotification`; `prewarmed` when the process
    /// environment has `ActivePrewarm=1`.
    mutating func launched(forRemoteNotification: Bool, prewarmed: Bool) -> EnergyEvent? {
        self.prewarmed = prewarmed
        return forRemoteNotification && !prewarmed ? decide(.coldLaunchBackground) : nil
    }

    /// A silent push reached the app.
    mutating func receivedPush() -> EnergyEvent? {
        prewarmed ? nil : decide(.coldLaunchBackground)
    }

    /// The scene became active.
    mutating func becameActive() -> EnergyEvent? {
        decide(.coldLaunchForeground)
    }

    private mutating func decide(_ event: EnergyEvent) -> EnergyEvent? {
        guard !decided else { return nil }
        decided = true
        return event
    }

    /// `ActivePrewarm=1` marks a process iOS prewarmed.
    static func isPrewarmed(_ environment: [String: String]) -> Bool {
        environment["ActivePrewarm"] == "1"
    }
}
