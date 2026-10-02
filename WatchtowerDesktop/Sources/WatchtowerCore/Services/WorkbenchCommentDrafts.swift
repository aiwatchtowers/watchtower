import Foundation
import Observation

/// One unsent owner comment on a project document: the passage it anchors on
/// and the owner's text. Nothing reaches the agent until the batch is sent.
package struct WorkbenchCommentDraft: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let anchor: CommentAnchor
    package var body: String

    package init(id: UUID = UUID(), anchor: CommentAnchor, body: String) {
        self.id = id
        self.anchor = anchor
        self.body = body
    }
}

/// The owner's unsent document comments, per document id, in the order they
/// were written. Owned by `WorkbenchesViewModel` (AppState), so drafts survive
/// switching documents, panes, projects and tabs; they live in memory only
/// and are gone when the app quits — "Send N comments" is what persists them.
@MainActor @Observable
package final class WorkbenchCommentDrafts {
    package private(set) var byDocument: [Int64: [WorkbenchCommentDraft]] = [:]

    package nonisolated init() {}

    /// Every unsent draft, on any document.
    package var count: Int { byDocument.values.reduce(0) { $0 + $1.count } }

    package func drafts(for documentID: Int64) -> [WorkbenchCommentDraft] {
        byDocument[documentID] ?? []
    }

    package func add(_ draft: WorkbenchCommentDraft, documentID: Int64) {
        byDocument[documentID, default: []].append(draft)
    }

    package func update(_ id: UUID, body: String, documentID: Int64) {
        guard let index = byDocument[documentID]?.firstIndex(where: { $0.id == id }) else { return }
        byDocument[documentID]?[index].body = body
    }

    package func remove(_ ids: Set<UUID>, documentID: Int64) {
        byDocument[documentID]?.removeAll { ids.contains($0.id) }
        if byDocument[documentID]?.isEmpty == true { byDocument[documentID] = nil }
    }
}
