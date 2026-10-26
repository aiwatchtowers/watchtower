import Foundation

/// The Chats panel's level (spec 2026-10-26 §4): every chat, or one
/// project's chats. Remembered per workspace as `storageValue`.
package enum ChatPanelLevel: Equatable, Hashable, Sendable {
    case all
    case project(Int64)

    /// The project whose chats the level lists; nil = All chats.
    package var projectID: Int64? {
        if case .project(let id) = self { return id }
        return nil
    }

    /// `"all"` or `"project:<id>"`.
    package var storageValue: String {
        switch self {
        case .all: "all"
        case .project(let id): "project:\(id)"
        }
    }

    /// nil for anything `storageValue` never writes.
    package init?(storageValue: String) {
        if storageValue == "all" {
            self = .all
            return
        }
        let prefix = "project:"
        guard storageValue.hasPrefix(prefix), let id = Int64(storageValue.dropFirst(prefix.count)) else {
            return nil
        }
        self = .project(id)
    }

    /// All chats once the project is gone (deleted or archived).
    package func resolved(activeProjectIDs: Set<Int64>) -> Self {
        guard let projectID, !activeProjectIDs.contains(projectID) else { return self }
        return .all
    }

    /// Whether a chat in `projectID` (nil = outside any project) is listed.
    package func lists(projectID chatProjectID: Int64?) -> Bool {
        projectID.map { $0 == chatProjectID } ?? true
    }
}
