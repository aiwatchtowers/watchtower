import Foundation
import GRDB
import Observation

/// State of the artifact side panel for one (conversation, key). Owned by
/// ChatViewModel so the panel survives navigation like the turn itself.
@MainActor @Observable
package final class ArtifactPanelModel {
    package let conversationID: Int64
    package let key: String
    package private(set) var versions: [ChatArtifact] = []
    /// nil = follow the latest version (and a live draft while a turn writes this key).
    package var selectedVersion: Int?
    package private(set) var liveDraft: ArtifactDraft?
    package private(set) var isEditing = false
    package var editText = ""
    package private(set) var errorMessage: String?
    @ObservationIgnored private let db: any DatabaseWriter

    package init(db: any DatabaseWriter, conversationID: Int64, key: String) {
        self.db = db
        self.conversationID = conversationID
        self.key = key
        reload()
    }

    package func reload() {
        do {
            versions = try db.read { try ChatArtifactQueries.versions($0, conversationID: conversationID, key: key) }
            if let selected = selectedVersion, !versions.contains(where: { $0.version == selected }) {
                selectedVersion = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not load the artifact: \(error.localizedDescription)"
        }
    }

    package var selectedArtifact: ChatArtifact? {
        guard let selectedVersion else { return versions.last }
        return versions.first { $0.version == selectedVersion }
    }

    package var displayed: ArtifactDraft? {
        if selectedVersion == nil, let liveDraft { return liveDraft }
        return selectedArtifact?.asDraft
    }

    /// Feed with the streaming message's drafts (`parse(…, final: false).artifacts`).
    package func applyStreaming(_ drafts: [ArtifactDraft]) {
        guard let draft = drafts.last(where: { $0.key == key }) else { return }
        liveDraft = draft
    }

    /// The turn ended and its artifacts are persisted: drop the draft, show the stored version.
    package func turnFinished() {
        liveDraft = nil
        reload()
    }

    package func beginEdit() {
        guard liveDraft == nil, let displayed else { return }
        editText = displayed.content
        isEditing = true
    }

    package func cancelEdit() {
        isEditing = false
        editText = ""
    }

    package func saveEdit() {
        guard isEditing, let base = selectedArtifact else { return }
        guard editText != base.content else {
            cancelEdit()
            return
        }
        var draft = base.asDraft
        draft.content = editText
        do {
            _ = try db.write {
                try ChatArtifactQueries.saveVersion($0, conversationID: conversationID, messageID: base.messageID,
                                                    draft: draft, edited: true)
            }
            selectedVersion = nil
            cancelEdit()
            reload()
        } catch {
            errorMessage = "Could not save the edit: \(error.localizedDescription)"
        }
    }

    /// The key a streaming turn should auto-open: the block being written now,
    /// unless it is already shown or the owner closed it during this turn.
    package static func keyToAutoOpen(drafts: [ArtifactDraft], currentKey: String?, dismissedKeys: Set<String>) -> String? {
        guard let writing = drafts.last(where: { !$0.isComplete }),
              writing.key != currentKey,
              !dismissedKeys.contains(writing.key) else { return nil }
        return writing.key
    }
}
