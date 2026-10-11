import Foundation
import WatchtowerSync

/// The `workbench` slice (mobile POC spec §4.2), record name
/// `workbench-<projects.id>`: one workbench as the phone's Workbench list
/// shows it. The hub resolves and caps every field; the phone draws them as
/// given. The raw `folder_path` is never published.
///
/// `<field>_clipped` is true when the hub cut that text at its cap (absent
/// otherwise); `targets_more` counts the board targets past the window.
public struct Workbench: SliceMirror, Identifiable {
    public static let sliceKind = SliceKind.workbench

    public let id: Int64
    /// Cap 200.
    public let name: String
    public let nameClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// Cap 1000.
    public let description: String
    public let descriptionClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The folder with the home prefix replaced by `~`. Cap 300.
    public let folderDisplay: String
    public let folderDisplayClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The checked-out branch ("" when detached). Cap 120.
    public let branch: String
    public let branchClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let detached: Bool
    /// Changed entries in the working tree (staged, unstaged, untracked).
    public let changes: Int
    public let openAsks: Int
    public let openTargets: Int
    public let inProgressTargets: Int
    public let blockedTargets: Int
    /// Done targets that are not archived.
    public let doneTargets: Int
    public let sessionCounts: SessionCounts
    /// nil when the workbench has no session.
    public let lastSessionActivity: Date?
    public let archiveAfterDays: Int
    /// Board targets past the per-workbench window.
    public let targetsMore: Int?

    /// Session counts over the workbench's published `terminal_session`
    /// records, by resolved state.
    public struct SessionCounts: Codable, Hashable, Sendable {
        public let working: Int
        public let waiting: Int
        public let needsApproval: Int
        public let finished: Int
        public let failed: Int
        public let stopped: Int
        public let notRunning: Int

        public init(
            working: Int, waiting: Int, needsApproval: Int, finished: Int, failed: Int, stopped: Int, notRunning: Int
        ) {
            self.working = working
            self.waiting = waiting
            self.needsApproval = needsApproval
            self.finished = finished
            self.failed = failed
            self.stopped = stopped
            self.notRunning = notRunning
        }
    }
}
