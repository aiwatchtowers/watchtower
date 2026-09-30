import Foundation
import GRDB
import Observation

/// The comments of one artifact panel (conversation, key): the latest stored
/// version's text they anchor on, their located ranges, and the owner's
/// writes. Owned by `ArtifactPanelModel`, so it lives as long as the panel.
/// It never sends anything (CHAT-05): it only hands out the composed message
/// (`outgoing()`); the chat sends it as the owner's own turn.
@MainActor @Observable
package final class ArtifactCommentsModel {
    package let conversationID: Int64
    package let key: String
    package private(set) var comments: [ArtifactComment] = []
    /// The latest stored version the comments are anchored on; nil = none yet.
    package private(set) var artifact: ChatArtifact?
    package private(set) var rendered: RenderedDocument?
    /// Comment id → its range (UTF-16) in `rendered.text`.
    package private(set) var ranges: [Int64: NSRange] = [:]
    package private(set) var errorMessage: String?
    @ObservationIgnored private let db: any DatabaseWriter

    package init(db: any DatabaseWriter, conversationID: Int64, key: String) {
        self.db = db
        self.conversationID = conversationID
        self.key = key
    }

    // MARK: - Groups

    /// Unsent comments in text order (unlocated ones last), then by id.
    package var unsent: [ArtifactComment] {
        comments.filter { $0.status == .open }.sorted { lhs, rhs in
            (ranges[lhs.id]?.location ?? .max, lhs.id) < (ranges[rhs.id]?.location ?? .max, rhs.id)
        }
    }

    package var sent: [ArtifactComment] { comments.filter { $0.status == .sent } }
    package var resolved: [ArtifactComment] { comments.filter { $0.status == .resolved } }
    package var outdated: [ArtifactComment] { comments.filter { $0.status == .outdated } }

    package func threadID(at location: Int) -> Int64? {
        ranges.first { NSLocationInRange(location, $0.value) }?.key
    }

    // MARK: - Loading

    /// Anchors on `latest` (the key's newest stored version): re-locates every
    /// comment and, when something moved or was lost, writes the plan once.
    /// Called on every panel reload — open, a finished turn, the owner's edit.
    package func sync(latest: ChatArtifact?) {
        artifact = latest
        let text = latest.map { ArtifactCommentText.render(kind: $0.kind, content: $0.content) }
        rendered = text
        do {
            var loaded = try db.read { try ArtifactCommentQueries.comments($0, conversationID: conversationID, key: key) }
            guard let latest, let text else {
                comments = loaded
                ranges = [:]
                errorMessage = nil
                return
            }
            let plan = ArtifactCommentReanchor.plan(loaded, text: text.text, version: latest.version)
            if !plan.isNoOp {
                loaded = try db.write { db in
                    try ArtifactCommentQueries.apply(db, plan: plan, version: latest.version)
                    return try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: key)
                }
            }
            comments = loaded
            ranges = plan.ranges
            errorMessage = nil
        } catch {
            errorMessage = "Could not load the comments: \(error.localizedDescription)"
        }
    }

    /// Re-reads the rows and re-locates them on the current version, without
    /// writing (after the chat marked some sent, or a test's direct write).
    package func reload() {
        sync(latest: artifact)
    }

    // MARK: - Owner actions

    @discardableResult
    package func add(body: String, selection: NSRange) -> Bool {
        guard let artifact, let rendered, selection.length > 0,
              let range = Range(selection, in: rendered.text),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let anchor = CommentAnchor.make(text: rendered.text, range: range, headings: rendered.headingOffsets)
        do {
            _ = try db.write {
                try ArtifactCommentQueries.add($0, conversationID: conversationID, key: key,
                                               version: artifact.version, anchor: anchor, body: body)
            }
            reload()
            return true
        } catch {
            errorMessage = "Could not save the comment: \(error.localizedDescription)"
            return false
        }
    }

    package func delete(_ id: Int64) {
        write { try ArtifactCommentQueries.deleteUnsent($0, id: id) }
    }

    package func resolve(_ id: Int64) {
        write { try ArtifactCommentQueries.resolve($0, id: id) }
    }

    /// The owner message for "Send N comments" and the ids it carries; nil
    /// when nothing is unsent.
    package func outgoing() -> ArtifactCommentMessage.Outgoing? {
        guard let artifact else { return nil }
        let pending = unsent
        guard let text = ArtifactCommentMessage.compose(title: artifact.title, key: key,
                                                        version: artifact.version, comments: pending) else { return nil }
        return ArtifactCommentMessage.Outgoing(text: text, ids: pending.map(\.id))
    }

    private func write(_ change: (Database) throws -> Bool) {
        do {
            _ = try db.write(change)
            reload()
        } catch {
            errorMessage = "Could not update the comment: \(error.localizedDescription)"
        }
    }
}
