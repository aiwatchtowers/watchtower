import CloudKit
import Foundation
import os
import WatchtowerSync

/// One hub's work-alert push subscription (D14): registered while the phone's "When work stops" switch is on, removed
/// when it is off. A private-scope hub gets the `WatchtowerSignal` query subscription (saving by ID replaces, so a
/// repeat is harmless); a shared-scope hub has none: the phone posts its alerts itself after each fetch
/// (`SharedAlertPoster`, ask #622).
@MainActor
final class AlertSubscriptionRegistrar {
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AlertSubscription")

    private let hubID: String
    private let scope: CloudDatabaseScope
    private let saver: any SubscriptionSaving
    private enum Applied { case unknown, registered, removed }

    /// What this process last got CloudKit to do; `unknown` until the first success, so a failure is retried by the
    /// next call (the next launch, or the next toggle).
    private var applied = Applied.unknown

    init(hubID: String, scope: CloudDatabaseScope, saver: any SubscriptionSaving) {
        self.hubID = hubID
        self.scope = scope
        self.saver = saver
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

    private func applyDesired() async {
        let enabled = desired
        let wanted = enabled ? Applied.registered : .removed
        guard applied != wanted else { return }
        do {
            if enabled {
                guard let subscription = AskAlertSubscription.subscription(for: scope, hubID: hubID) else { return }
                try await saver.save(subscription)
            } else if AskAlertSubscription.subscription(for: scope, hubID: hubID) != nil {
                try await saver.delete(id: AskAlertSubscription.subscriptionID(hubID: hubID))
            }
            applied = wanted
        } catch {
            let what = enabled ? "save" : "delete"
            Self.logger.error("alert subscription \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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
