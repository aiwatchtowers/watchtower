import Foundation

/// Lightweight track parsed from a digest's inline JSON (not the full DB model).
package struct DigestTrack: Codable, Identifiable, Equatable {
    package let id = UUID()
    package let text: String
    package let assignee: String?
    package let status: String?  // "open", "done", etc.

    package enum CodingKeys: String, CodingKey {
        case text, assignee, status
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.assignee == rhs.assignee && lhs.status == rhs.status
    }
}
