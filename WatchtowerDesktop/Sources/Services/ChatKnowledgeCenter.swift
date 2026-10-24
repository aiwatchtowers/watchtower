import Foundation
import GRDB
import Observation
import WatchtowerCore

/// What the chat shows under an owner message that said "решили: …" /
/// "decided: …" or "факт: …" / "fact: …" (`KnowledgePrefix`).
enum ChatKnowledgeMark: Equatable {
    /// The registry item the message wrote; `kind` is `decision` or `note`.
    case saved(kind: String, ideaID: Int64)
    /// Nothing after the prefix: nothing was written.
    case empty
    /// Undo deleted the item.
    case undone
    /// Undo found the item changed since (edited, approved elsewhere, merged):
    /// it was kept and opened in the Inbox instead.
    case changed(ideaID: Int64)
    case failed(String)
}

/// Saved in place: an owner chat message behind a knowledge prefix is written
/// at once as an active registry item (`IdeaQueries.createFromChat`, Swift is
/// the registry's writer here, as for the owner-create sheet), and the chat
/// shows the outcome under the message. The write runs off the send path, so
/// a busy database never delays the turn.
@MainActor
@Observable
final class ChatKnowledgeCenter {
    private var marks: [Int64: ChatKnowledgeMark] = [:]

    @ObservationIgnored let dbPool: DatabasePool
    /// The item's `updated_at` as it was right after creation, per message:
    /// Undo deletes the item only while it still matches.
    @ObservationIgnored private var stamps: [Int64: String] = [:]
    /// Writes still running, by a token; each removes itself when done.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    func mark(for messageID: Int64) -> ChatKnowledgeMark? { marks[messageID] }

    /// A new owner message is on disk. Only a knowledge prefix does anything
    /// (a remember message is `RememberCenter`'s, and parses as none here).
    func ownerMessageSent(text: String, conversationID: Int64, messageID: Int64) {
        guard let parsed = KnowledgePrefix.parse(text) else { return }
        if parsed.body.isEmpty {
            marks[messageID] = .empty
            return
        }
        let dbPool = dbPool
        let token = UUID()
        tasks[token] = Task { [weak self] in
            let result: Result<(Int64, String), Error>
            do {
                result = .success(try await dbPool.write { db -> (Int64, String) in
                    let id = try IdeaQueries.createFromChat(
                        db, kind: parsed.kind, body: parsed.body, conversationID: conversationID, messageID: messageID)
                    let stamp = try String.fetchOne(db, sql: "SELECT updated_at FROM ideas WHERE id = ?",
                                                    arguments: [id]) ?? ""
                    return (id, stamp)
                })
            } catch {
                result = .failure(error)
            }
            self?.finish(token: token, messageID: messageID, kind: parsed.kind, result: result)
        }
    }

    /// Deletes the item this message wrote while it is untouched; otherwise
    /// the mark says it changed (the view then opens it in the Inbox).
    func undo(messageID: Int64) async {
        guard case .saved(_, let ideaID)? = marks[messageID], let stamp = stamps[messageID] else { return }
        do {
            let deleted = try await dbPool.write { db in
                try IdeaQueries.undoChatIdea(db, id: ideaID, createdUpdatedAt: stamp)
            }
            marks[messageID] = deleted ? .undone : .changed(ideaID: ideaID)
            if deleted { stamps[messageID] = nil }
        } catch {
            marks[messageID] = .failed(error.localizedDescription)
        }
    }

    /// Rebuilds `.saved` for a reopened conversation from the item holding
    /// the message's chat mention. A mark already known is kept; a message
    /// with no item (undone before, or never written) gets none.
    func loadMark(conversationID: Int64, messageID: Int64) async {
        guard marks[messageID] == nil else { return }
        do {
            let idea = try await dbPool.read { db in
                try IdeaQueries.chatIdea(db, conversationID: conversationID, messageID: messageID)
            }
            guard let idea, marks[messageID] == nil else { return }
            marks[messageID] = .saved(kind: idea.kindRaw, ideaID: Int64(idea.id))
            // Created and updated in one INSERT, so `created_at` is the
            // `updated_at` an untouched item still carries.
            stamps[messageID] = idea.createdAt
        } catch {
            NSLog("ChatKnowledgeCenter: reading the saved item failed: %@", error.localizedDescription)
        }
    }

    /// Writes still running (tests: a finished one is pruned at once).
    var runningWrites: Int { tasks.count }

    /// Waits for the writes started so far (tests).
    func waitForIdle() async {
        for task in Array(tasks.values) { await task.value }
    }

    private func finish(token: UUID, messageID: Int64, kind: String, result: Result<(Int64, String), Error>) {
        tasks[token] = nil
        switch result {
        case .success(let (id, stamp)):
            marks[messageID] = .saved(kind: kind, ideaID: id)
            stamps[messageID] = stamp
        case .failure(let error):
            marks[messageID] = .failed(error.localizedDescription)
        }
    }
}
