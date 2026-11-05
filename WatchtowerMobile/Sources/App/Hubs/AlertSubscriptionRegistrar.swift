import Foundation
import os
import WatchtowerSync

/// One hub's work-alert push subscription (D14): registered while the phone's "When work stops" switch is on, removed
/// when it is off. A private-scope hub gets the `WatchtowerSignal` query subscription (saving by ID replaces, so a
/// repeat is harmless); a shared-scope hub has none: the phone posts its alerts itself after each fetch
/// (`SharedAlertPoster`, ask #622).
///
/// `route` is the hub's CloudKit route whatever transport the session is on (Open decision 18): the subscription stays
/// while the phone is on the relay, where a hub writes no signal, so it is silent there, and it is in place for the
/// signals a hub re-sends at a switch back to CloudKit.
@MainActor
final class AlertSubscriptionRegistrar {
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AlertSubscription")

    private let hubID: String
    private let route: HubRoute
    private let wake: any PushWake
    private enum Applied { case unknown, registered, removed }

    /// What this process last got CloudKit to do; `unknown` until the first success, so a failure is retried by the
    /// next call (the next launch, the next foreground, or the next toggle).
    private var applied = Applied.unknown

    init(hubID: String, route: HubRoute, wake: any PushWake) {
        self.hubID = hubID
        self.route = route
        self.wake = wake
    }

    /// The newest requested state.
    private var desired = false
    /// The last queued run: runs go one at a time, so a save and a delete never overlap at CloudKit.
    private var lastRun: Task<Void, Never>?

    /// Queues the change and returns when it (or a newer one that overtook it) has run. The newest request wins:
    /// each run applies `desired`, not the value it was asked with.
    func apply(enabled: Bool) async {
        desired = enabled
        let prior = lastRun
        let run = Task { [weak self] in
            await prior?.value
            await self?.applyDesired()
        }
        lastRun = run
        await run.value
    }

    /// Returns once no run is queued or at CloudKit: a route move waits for it, so the old session's call never
    /// overlaps the new session's.
    func idle() async {
        while let run = lastRun {
            await run.value
            if lastRun == run { return }
        }
    }

    private func applyDesired() async {
        let enabled = desired
        let wanted = enabled ? Applied.registered : .removed
        guard applied != wanted else { return }
        do {
            if enabled {
                guard try await wake.subscribeAlerts(hubID: hubID, route: route) else { return }
            } else {
                try await wake.unsubscribeAlerts(hubID: hubID, route: route)
            }
            applied = wanted
        } catch {
            let what = enabled ? "save" : "delete"
            let code = CloudKitPushWake.errorCode(error) ?? String(describing: type(of: error))
            Self.logger.error("alert subscription \(what, privacy: .public) failed: \(code, privacy: .public)")
        }
    }
}

/// The Settings copy of the alerts switch.
enum WorkAlertsCopy {
    static let title = "When work stops"
    static let footer = "Asks, approvals and finished or failed sessions, only while you're away from your Mac."
    static let sharedFootnote = "Alerts may be late on this phone."

    static func footer(anyShared: Bool) -> String {
        anyShared ? "\(footer) \(sharedFootnote)" : footer
    }
}
