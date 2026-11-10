import Foundation
import os

/// After a Desktop reminder write (Done, Snooze): `watchtower inbox
/// approvals changed --ref reminder:<id>`, which queues a run of Needs
/// approval (AUTO-09: it only queues). The Inbox's row actions and Home's
/// Done/Hide run it through this one helper. A failure is logged (the ref
/// only, FILES-01) and never shown: the render-time check already hides the
/// closed reminder, and the daemon's sweep redraws (spec "Desktop reminder
/// writes").
package enum ReminderApprovalHook {
    package static func arguments(_ id: Int64) -> [String] {
        ["inbox", "approvals", "changed", "--ref", "reminder:\(id)"]
    }

    /// `runner` nil (no watchtower binary): logged, nothing run. Callers
    /// resolve their own default runner first.
    package static func changed(_ id: Int64, runner: (any CLIRunnerProtocol)?) async {
        guard let runner else {
            log.error("approvals changed for reminder:\(id, privacy: .public) skipped: no watchtower binary")
            return
        }
        do {
            _ = try await runner.run(args: arguments(id))
        } catch {
            log.error("approvals changed for reminder:\(id, privacy: .public) failed")
        }
    }

    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "inbox-approvals")
}
