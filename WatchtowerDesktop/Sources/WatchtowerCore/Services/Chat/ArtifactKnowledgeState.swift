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
    /// An older version shown while a newer one is kept gets no control: it is
    /// not what Knowledge holds, so neither Update nor Remove would be about it.
    package static func `for`(kind: String, shownVersion: Int, keptVersion: Int?) -> Self? {
        guard kinds.contains(kind) else { return nil }
        guard let keptVersion else { return .add }
        if shownVersion > keptVersion { return .update }
        return shownVersion == keptVersion ? .remove : nil
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
