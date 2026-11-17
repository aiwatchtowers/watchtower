import Foundation
import GRDB
import Observation
import WatchtowerCore
import WatchtowerInterface

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
/// at once as an active registry item (Go's `ideas.create_from_chat`, #1170
/// Task 12), and the chat shows the outcome under the message. The write
/// runs off the send path, so a busy database never delays the turn.
@MainActor
@Observable
final class ChatKnowledgeCenter {
    private var marks: [Int64: ChatKnowledgeMark] = [:]

    @ObservationIgnored let dbPool: DatabasePool
    /// The item's `updated_at` as it was right after creation, per message:
    /// Undo deletes the item only while it still matches.
    @ObservationIgnored private var stamps: [Int64: String] = [:]
    /// Messages whose Undo is running: a second press while it runs does
    /// nothing (it would find the row gone and read it as changed).
    @ObservationIgnored private var undoing: Set<Int64> = []
    /// Writes still running, by a token; each removes itself when done.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Where the item's create and Undo go: the chat's tower when the write
    /// runs (nil: they fail with the daemon's sentence).
    @ObservationIgnored private let tower: () -> (any TowerSending)?

    init(dbPool: DatabasePool, tower: @escaping () -> (any TowerSending)?) {
        self.dbPool = dbPool
        self.tower = tower
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
        let tower = tower()
        let token = UUID()
        tasks[token] = Task { [weak self] in
            let result: Result<(Int64, String), Error>
            do {
                guard let tower else { throw TowerWriteError(TowerText.daemonDown) }
                let created: CreatedResult = try await tower.perform(.ideasCreateFromChat) {
                    IdeaFromChatRequest(requestID: $0, conversationID: conversationID, messageID: messageID,
                                        kind: parsed.kind, body: parsed.body)
                }
                result = .success((created.id, created.updatedAt ?? ""))
            } catch {
                result = .failure(error)
            }
            self?.finish(token: token, messageID: messageID, kind: parsed.kind, result: result)
        }
    }

    /// A main-chat owner message whose turn started: Go wrote its knowledge
    /// item in the start (`started.idea_id`), so only the mark is set here
    /// (mobile Inbox spec §8).
    func record(_ started: ChatStarted, text: String) async {
        guard let parsed = KnowledgePrefix.parse(text) else { return }
        let messageID = started.ownerMessageID
        if parsed.body.isEmpty {
            marks[messageID] = .empty
        } else if started.ideaID > 0 {
            await loadMark(conversationID: started.conversationID, messageID: messageID)
        } else {
            marks[messageID] = .failed(started.prefixError.isEmpty ? Self.notSaved : started.prefixError)
        }
    }

    static let notSaved = "Watchtower couldn't save this."

    /// Deletes the item this message wrote while it is untouched; otherwise
    /// the mark says it changed (the view then opens it in the Inbox).
    func undo(messageID: Int64) async {
        guard case .saved(_, let ideaID)? = marks[messageID], let stamp = stamps[messageID],
              undoing.insert(messageID).inserted else { return }
        defer { undoing.remove(messageID) }
        do {
            guard let tower = tower() else { throw TowerWriteError(TowerText.daemonDown) }
            let undone: UndoChatResult = try await tower.perform(.ideasUndoChat) {
                IdeaUndoChatRequest(requestID: $0, id: ideaID, createdUpdatedAt: stamp)
            }
            let deleted = undone.undone
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
