import Foundation
import Observation

/// The composer's pending (not yet sent) attachments. Owned by ChatViewModel,
/// so pending files survive navigating away from the chat.
///
/// Files are copied and recorded off the main thread (board #670): a file
/// joins `pending` once its row landed, and leaves it once its removal did.
/// `settled()` waits for the adds and removals under way — a send awaits it,
/// so a file dropped just before Enter goes out with that message.
@MainActor @Observable
package final class ComposerAttachments {
    package private(set) var pending: [ChatAttachment] = []
    package private(set) var errorMessage: String?
    @ObservationIgnored private let store: ChatAttachmentStore?
    /// Adds and removals under way.
    @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var removing: Set<Int64> = []
    /// Bumped when the composer switches chats: an add that lands after the
    /// switch stays stored as that chat's pending file and is not shown here.
    @ObservationIgnored private var generation = 0

    package init(store: ChatAttachmentStore?) {
        self.store = store
    }

    /// Imports `urls` one after another; each is shown once stored.
    package func add(urls: [URL], conversationID: Int64) {
        guard let store else {
            errorMessage = "Attachments need an active workspace"
            return
        }
        let generation = self.generation
        track { [self] in
            var problems: [String] = []
            for url in urls {
                do {
                    let item = try await store.importFile(url: url, conversationID: conversationID)
                    if self.generation == generation { pending.append(item) }
                } catch let rejection as AttachmentRejection {
                    problems.append(rejection.message)
                } catch {
                    problems.append("\(url.lastPathComponent) could not be attached: \(error.localizedDescription)")
                }
            }
            guard self.generation == generation else { return }
            errorMessage = problems.isEmpty ? nil : problems.joined(separator: "\n")
        }
    }

    /// Pasted bytes (a screenshot, PDF data, a long text paste) under `name`;
    /// the same validation and store as a dropped file. true once attached.
    @discardableResult
    package func addPasted(_ data: Data, name: String, conversationID: Int64) async -> Bool {
        guard let store else {
            errorMessage = "Attachments need an active workspace"
            return false
        }
        let generation = self.generation
        do {
            let item = try await store.importData(data, name: name, owner: .conversation(conversationID))
            guard self.generation == generation else { return true }
            pending.append(item)
            errorMessage = nil
            return true
        } catch let rejection as AttachmentRejection {
            if self.generation == generation { errorMessage = rejection.message }
        } catch {
            if self.generation == generation {
                errorMessage = "\(name) could not be attached: \(error.localizedDescription)"
            }
        }
        return false
    }

    /// The file stays shown until its removal landed; a second press
    /// meanwhile does nothing.
    package func remove(id: Int64) {
        guard let item = pending.first(where: { $0.id == id }), let store, removing.insert(id).inserted else { return }
        track { [self] in
            defer { removing.remove(id) }
            do {
                try await store.discard(item)
                pending.removeAll { $0.id == id }
            } catch {
                errorMessage = "\(item.name) could not be removed: \(error.localizedDescription)"
            }
        }
    }

    /// Returns once every add and removal asked for so far has landed.
    package func settled() async {
        while let next = inFlight.values.first { await next.value }
    }

    /// Switching conversations: pending files belong to their own chat, so
    /// the composer shows the newly opened chat's unsent files instead.
    package func replacePending(with items: [ChatAttachment]) {
        generation += 1
        pending = items
        errorMessage = nil
    }

    private func track(_ body: @escaping @MainActor () async -> Void) {
        let key = UUID()
        inFlight[key] = Task { [self] in
            await body()
            inFlight[key] = nil
        }
    }

    /// The files a turn just sent leave the composer; one added while that
    /// turn was being written stays for the next.
    package func removeSent(_ ids: [Int64]) {
        let sent = Set(ids)
        pending.removeAll { sent.contains($0.id) }
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
