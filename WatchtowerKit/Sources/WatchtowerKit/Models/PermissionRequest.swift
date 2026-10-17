import Foundation
import WatchtowerSync

/// The `permission_request` slice (#517), record name
/// `permission_request-<permission_requests.id>`: a Claude Code permission
/// prompt a board session waits on. Only pending requests are published; the
/// phone answers through `PermissionAnswerParams` and draws no rules of its own.
public struct PermissionRequest: SliceMirror, Identifiable {
    public static let sliceKind = SliceKind.permissionRequest

    public let id: Int64
    public let sessionID: Int64
    public let workbenchID: Int64
    public let toolName: String
    /// What the tool is about to do. Cap 2000.
    public let summary: String
    public let summaryClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let createdAt: Date

    // convertFromSnakeCase maps "*_id" -> "*Id".
    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case workbenchID = "workbenchId"
        case toolName, summary, summaryClipped, createdAt
    }
}
