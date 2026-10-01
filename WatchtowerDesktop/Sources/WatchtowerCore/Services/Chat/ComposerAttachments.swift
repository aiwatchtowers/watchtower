import Foundation
import Observation

/// The composer's pending (not yet sent) attachments. Owned by ChatViewModel,
/// so pending files survive navigating away from the chat.
@MainActor @Observable
package final class ComposerAttachments {
    package private(set) var pending: [ChatAttachment] = []
    package private(set) var errorMessage: String?
    @ObservationIgnored private let store: ChatAttachmentStore?

    package init(store: ChatAttachmentStore?) {
        self.store = store
    }

    package func add(urls: [URL], conversationID: Int64) {
        guard let store else {
            errorMessage = "Attachments need an active workspace"
            return
        }
        var problems: [String] = []
        for url in urls {
            do {
                pending.append(try store.importFile(url: url, conversationID: conversationID))
            } catch let rejection as AttachmentRejection {
                problems.append(rejection.message)
            } catch {
                problems.append("\(url.lastPathComponent) could not be attached: \(error.localizedDescription)")
            }
        }
        errorMessage = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    package func addPastedImage(_ png: Data, conversationID: Int64) {
        guard let store else {
            errorMessage = "Attachments need an active workspace"
            return
        }
        do {
            pending.append(try store.importData(png, name: "Pasted image.png", owner: .conversation(conversationID)))
            errorMessage = nil
        } catch let rejection as AttachmentRejection {
            errorMessage = rejection.message
        } catch {
            errorMessage = "The pasted image could not be attached: \(error.localizedDescription)"
        }
    }

    package func remove(id: Int64) {
        guard let item = pending.first(where: { $0.id == id }), let store else { return }
        do {
            try store.discard(item)
            pending.removeAll { $0.id == id }
        } catch {
            errorMessage = "\(item.name) could not be removed: \(error.localizedDescription)"
        }
    }

    /// Switching conversations: pending files belong to their own chat, so
    /// the composer shows the newly opened chat's unsent files instead.
    package func replacePending(with items: [ChatAttachment]) {
        pending = items
        errorMessage = nil
    }

    /// Hands the pending set to `send` and clears the composer.
    package func takeForSend() -> [ChatAttachment] {
        let taken = pending
        pending = []
        errorMessage = nil
        return taken
    }
}
