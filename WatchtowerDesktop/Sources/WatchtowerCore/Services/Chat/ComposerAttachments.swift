import Foundation
import Observation

/// The composer's pending (not yet sent) attachments. Owned by ChatViewModel,
/// so pending files survive navigating away from the chat.
///
/// Files are copied and recorded off the main thread (board #670): a file
/// shows as being stored (`importing`) at once and joins `pending` once its
/// row landed; a removed one stays (its ✕ disabled, `removing`) until its
/// delete landed. `settled()` waits for the adds and removals under way — a
/// send awaits it, so a file dropped just before Enter goes out with that
/// message.
@MainActor @Observable
package final class ComposerAttachments {
    package private(set) var pending: [ChatAttachment] = []
    package private(set) var errorMessage: String?
    /// Attachments whose removal is under way.
    package private(set) var removing: Set<Int64> = []
    /// Files being stored, with the conversation each is for.
    private var stores: [(id: UUID, conversationID: Int64, name: String)] = []
    @ObservationIgnored private let store: ChatAttachmentStore?
    /// Adds and removals under way.
    @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// The conversation whose files the composer shows: an add that lands
    /// for another one stays stored as that chat's pending file and is shown
    /// only when that chat is shown again.
    @ObservationIgnored private var shown: Int64?

    package init(store: ChatAttachmentStore?) {
        self.store = store
    }

    /// The names of the shown chat's files being stored.
    package var importing: [String] {
        stores.filter { $0.conversationID == shown }.map(\.name)
    }

    /// Whether an add or a removal is under way.
    package var isBusy: Bool { !inFlight.isEmpty }

    /// Imports `urls` one after another; each is shown once stored.
    package func add(urls: [URL], conversationID: Int64) {
        guard let store else {
            errorMessage = "Attachments need an active workspace"
            return
        }
        shown = shown ?? conversationID
        let entries = urls.map { (id: UUID(), conversationID: conversationID, name: $0.lastPathComponent) }
        stores.append(contentsOf: entries)
        track { [self] in
            var problems: [String] = []
            for (url, entry) in zip(urls, entries) {
                do {
                    show(try await store.importFile(url: url, conversationID: conversationID))
                } catch let rejection as AttachmentRejection {
                    problems.append(rejection.message)
                } catch {
                    problems.append("\(url.lastPathComponent) could not be attached: \(error.localizedDescription)")
                }
                stores.removeAll { $0.id == entry.id }
            }
            guard shown == conversationID else { return }
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
        shown = shown ?? conversationID
        let entry = (id: UUID(), conversationID: conversationID, name: name)
        stores.append(entry)
        defer { stores.removeAll { $0.id == entry.id } }
        do {
            show(try await store.importData(data, name: name, owner: .conversation(conversationID)))
            if shown == conversationID { errorMessage = nil }
            return true
        } catch let rejection as AttachmentRejection {
            if shown == conversationID { errorMessage = rejection.message }
        } catch {
            if shown == conversationID { errorMessage = "\(name) could not be attached: \(error.localizedDescription)" }
        }
        return false
    }

    /// The file stays shown, its ✕ disabled, until its removal landed.
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
    /// the composer shows the newly opened chat's unsent files instead (read
    /// from the database by the caller; nil = the landing, which has none).
    package func replacePending(with items: [ChatAttachment], conversationID: Int64? = nil) {
        shown = conversationID
        pending = items
        errorMessage = nil
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

    /// A stored file joins the composer when its chat is the one shown (and
    /// it is not there yet: the chat may have been reopened, reading it).
    private func show(_ item: ChatAttachment) {
        guard item.conversationID == shown, !pending.contains(where: { $0.id == item.id }) else { return }
        pending.append(item)
    }

    private func track(_ body: @escaping @MainActor () async -> Void) {
        let key = UUID()
        inFlight[key] = Task { [self] in
            await body()
            inFlight[key] = nil
        }
    }
}
