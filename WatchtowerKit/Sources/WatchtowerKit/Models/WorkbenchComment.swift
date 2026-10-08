import Foundation
import WatchtowerSync

/// The `workbench_comment` slice (mobile POC spec §4.4), record name
/// `workbench_comment-<project_comments.id>`: one comment on a published
/// board target, the newest 200 per target. The phone never marks comments
/// read.
public struct WorkbenchComment: SliceMirror, Identifiable {
    public static let sliceKind = SliceKind.workbenchComment

    /// rawValues are wire format (`project_comments.author`).
    public struct Author: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let owner = Self(rawValue: "owner")
        public static let agent = Self(rawValue: "agent")
        public static let knownValues: [Self] = [.owner, .agent]
    }

    /// rawValues are wire format (`project_comments.status`).
    public struct Status: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let open = Self(rawValue: "open")
        public static let resolved = Self(rawValue: "resolved")
        public static let outdated = Self(rawValue: "outdated")
        public static let knownValues: [Self] = [.open, .resolved, .outdated]
    }

    public let id: Int64
    public let workbenchID: Int64
    /// nil on a reply that names only its parent.
    public let targetID: Int64?
    /// The root comment of a reply; nil on a root.
    public let parentID: Int64?
    public let author: Author
    /// Which agent wrote it ("" for the owner). Cap 60.
    public let agentLabel: String
    public let agentLabelClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// Cap 4000.
    public let body: String
    public let bodyClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let status: Status
    public let createdAt: Date
    /// Read by the owner on the Mac.
    public let read: Bool

    // convertFromSnakeCase maps "*_id" -> "*Id" (lowercase d).
    enum CodingKeys: String, CodingKey {
        case id
        case workbenchID = "workbenchId"
        case targetID = "targetId"
        case parentID = "parentId"
        case author, agentLabel, agentLabelClipped, body, bodyClipped, status, createdAt, read
    }
}
