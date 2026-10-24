import Foundation

/// What the knowledge control on an artifact offers (chat knowledge, Task 8).
/// Only the kinds a person would search for later carry it; drafts to send
/// (`email`, `slack`, `event`) do not.
package enum ArtifactKnowledgeState: Equatable {
    case add
    case update
    case remove

    package static let kinds: Set<String> = ["document", "table", "code", "html"]

    /// `nil` = no control. `keptVersion` is the pinned version of the key, if any.
    package static func `for`(kind: String, shownVersion: Int, keptVersion: Int?) -> ArtifactKnowledgeState? {
        guard kinds.contains(kind) else { return nil }
        guard let keptVersion else { return .add }
        return keptVersion < shownVersion ? .update : .remove
    }

    package var title: String {
        switch self {
        case .add: return "Add to Knowledge"
        case .update: return "Update in Knowledge"
        case .remove: return "Remove from Knowledge"
        }
    }

    package var systemImage: String {
        switch self {
        case .add, .update: return "books.vertical"
        case .remove: return "minus.circle"
        }
    }
}
