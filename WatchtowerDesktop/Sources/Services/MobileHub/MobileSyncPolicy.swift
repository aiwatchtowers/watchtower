import Foundation
import os
import WatchtowerCore
import WatchtowerSync

extension SliceKind {
    /// What `MobileSync = workbench_only` (#608, Q4) keeps on the phone: the
    /// workbench kinds — boards, sessions, asks, session chat, permission
    /// requests — and the hub's own liveness and link records. Targets and
    /// tracks are personal data and stay out.
    static let workbenchOnly: Set<SliceKind> = [
        .workbench, .workbenchTarget, .workbenchComment, .terminalSession, .ownerAsk, .sessionReport,
        .sessionTimeline, .askAlert, .permissionRequest, .sessionChat, .heartbeat, .deviceGrant
    ]
}

/// The organization's `MobileSync` mode as the hub's background parts read
/// it (#608): the publisher and the recording ingest run off the main actor,
/// so AppState mirrors the policy here on every change.
final class MobileSyncPolicyBox: Sendable {
    private let mode = OSAllocatedUnfairLock(initialState: "allowed")

    var current: String { mode.withLock { $0 } }

    func store(_ value: String) { mode.withLock { $0 = value } }

    /// The kinds the hub may publish; nil = every kind.
    var allowedKinds: Set<SliceKind>? {
        switch current {
        case "workbench_only": SliceKind.workbenchOnly
        case "off": []
        default: nil
        }
    }

    /// A phone recording is not workbench data: refused under
    /// `workbench_only` (and `off`, where no hub runs).
    func checkRecordingAllowed() throws {
        if current != "allowed" { throw MobileSyncPolicyError.blocked }
    }
}

enum MobileSyncPolicyError: Error, LocalizedError {
    case blocked

    var errorDescription: String? { "blocked by your organization's policy: phone recordings are not synced to this Mac" }
}
