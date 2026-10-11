import Foundation
import WatchtowerSync

/// A board target's status (`targets.status`). rawValues are wire format; a
/// status added by a newer Mac decodes as an unknown value.
public struct WorkbenchTargetStatus: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let todo = Self(rawValue: "todo")
    public static let inProgress = Self(rawValue: "in_progress")
    public static let inReview = Self(rawValue: "in_review")
    public static let blocked = Self(rawValue: "blocked")
    public static let done = Self(rawValue: "done")
    public static let dismissed = Self(rawValue: "dismissed")
    public static let snoozed = Self(rawValue: "snoozed")
    public static let knownValues: [Self] = [.todo, .inProgress, .inReview, .blocked, .done, .dismissed, .snoozed]

    /// The statuses the owner may set (`WorkbenchBoardCard.editableStatuses`,
    /// spec §5.2 `board_target_status`).
    public static let editable: [Self] = [.todo, .inProgress, .inReview, .blocked, .done, .dismissed]
}

/// A board target's priority (`targets.priority`,
/// `WorkbenchBoardCard.editablePriorities`). rawValues are wire format.
public struct WorkbenchTargetPriority: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let high = Self(rawValue: "high")
    public static let medium = Self(rawValue: "medium")
    public static let low = Self(rawValue: "low")
    public static let knownValues: [Self] = [.high, .medium, .low]
}

/// Who made a status move (`target_status_history.actor`). rawValues are
/// wire format.
public struct WorkbenchStatusActor: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let agent = Self(rawValue: "agent")
    public static let owner = Self(rawValue: "owner")
    public static let system = Self(rawValue: "system")
    public static let knownValues: [Self] = [.agent, .owner, .system]
}

/// The `workbench_target` slice (mobile POC spec §4.3), record name
/// `workbench_target-<targets.id>`: one target of a workbench board. Only
/// board targets are published (PROJ-01). Archived targets carry
/// `archived: true`; the phone shows them only under the Archive filter.
public struct WorkbenchTarget: SliceMirror, Identifiable {
    public static let sliceKind = SliceKind.workbenchTarget

    public let id: Int64
    public let workbenchID: Int64
    /// nil for a top-level target.
    public let parentID: Int64?
    /// Cap 300.
    public let text: String
    public let textClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// Cap 4000.
    public let intent: String
    public let intentClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let status: WorkbenchTargetStatus
    public let priority: WorkbenchTargetPriority
    /// 0...1.
    public let progress: Double
    /// Cap 120.
    public let branch: String
    public let branchClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// A number or URL. Cap 120.
    public let pr: String
    public let prClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let archived: Bool
    public let childrenCount: Int
    public let openComments: Int
    public let unreadForOwner: Int
    /// Open asks filed on this target.
    public let openAsks: Int
    /// Sessions working on this target (direct or linked). At most 20.
    public let sessionIDs: [Int64]
    public let sessionIDsMore: Int?
    /// The newest status move; nil when the target has none.
    public let lastStatusAt: Date?
    public let lastStatusActor: WorkbenchStatusActor?
    /// The Mac's "Work on it" brief for this target; prefills the start
    /// sheet. Cap 1000.
    public let workOnPrompt: String
    public let workOnPromptClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let createdAt: Date
    public let updatedAt: Date

    // convertFromSnakeCase maps "workbench_id" -> "workbenchId" (lowercase
    // d), so the ID keys use that form.
    enum CodingKeys: String, CodingKey {
        case id
        case workbenchID = "workbenchId"
        case parentID = "parentId"
        case text, textClipped, intent, intentClipped, status, priority, progress
        case branch, branchClipped, pr, prClipped, archived, childrenCount, openComments, unreadForOwner, openAsks
        case sessionIDs = "sessionIds"
        case sessionIDsMore = "sessionIdsMore"
        case lastStatusAt, lastStatusActor, workOnPrompt, workOnPromptClipped, createdAt, updatedAt
    }
}
