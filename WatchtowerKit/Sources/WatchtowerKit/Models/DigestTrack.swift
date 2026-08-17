import Foundation

/// Lightweight track parsed from a digest's inline JSON (not the full DB model).
public struct DigestTrack: Codable, Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let assignee: String?
    public let status: String?  // "open", "done", etc.

    public enum CodingKeys: String, CodingKey {
        case text, assignee, status
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.assignee == rhs.assignee && lhs.status == rhs.status
    }
}
