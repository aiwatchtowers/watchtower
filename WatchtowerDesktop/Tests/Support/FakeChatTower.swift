import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface
import WatchtowerChatText

/// A stand-in for the daemon's `chat.*` commands (and the chat's knowledge
/// items, `ideas.create_from_chat`/`ideas.undo_chat`) over a test database: each
/// call is recorded and applied with the test writers (`ChatTestWriters`,
/// the SQL the Go writers are pinned to), or refused as scripted.
package final class FakeChatTower: ChatTowerSending, @unchecked Sendable {
    package struct Call {
        package let command: TowerCommand
        package let params: [String: Any]
    }

    private struct Refusal: Error {
        let sentence: String
        var code: WatchtowerInterface.RefusalCode = .notFound
    }

    package let db: any DatabaseWriter
    private let lock = NSLock()
    private var refusalsStorage: [TowerCommand: String] = [:]
    private var callsStorage: [Call] = []
    /// Runs before a call is applied (a test's moment to look or hold).
    package var beforeApply: (@Sendable (TowerCommand) async -> Void)?

    package init(db: any DatabaseWriter) {
        self.db = db
    }

    /// `ChatWrites` over a fake tower on `db`.
    package static func writes(_ db: any DatabaseWriter) -> (ChatWrites, FakeChatTower) {
        let tower = FakeChatTower(db: db)
        return (ChatWrites(tower: tower), tower)
    }

    /// Every later `command` is refused with `sentence` (nil: applied again).
    package func refuse(_ command: TowerCommand, with sentence: String?) {
        lock.withLock { refusalsStorage[command] = sentence }
    }

    package var calls: [Call] { lock.withLock { callsStorage } }

    package func calls(_ command: TowerCommand) -> [[String: Any]] {
        calls.filter { $0.command == command }.map(\.params)
    }

    package func act<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand,
        key: String,
        params: (String) -> Params
    ) async -> TowerActOutcome<Resp> {
        let request = params(UUID().uuidString.lowercased())
        guard let data = try? JSONEncoder().encode(request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(TowerFailure(kind: .refused, sentence: TowerText.couldNotSend))
        }
        let refused = lock.withLock { () -> String? in
            callsStorage.append(Call(command: command, params: object))
            return refusalsStorage[command]
        }
        if let refused { return .refused(WatchtowerInterface.Refusal(code: .unsupported, sentence: refused)) }
        await beforeApply?(command)
        do {
            let result = try await apply(command, data)
            return .ok(try JSONDecoder().decode(Resp.self, from: result))
        } catch let refusal as Refusal {
            return .refused(WatchtowerInterface.Refusal(code: refusal.code, sentence: refusal.sentence))
        } catch {
            return .refused(WatchtowerInterface.Refusal(code: .unsupported, sentence: error.localizedDescription))
        }
    }

    // MARK: - Commands

    private static let chatGone = "This chat no longer exists."
    private static let messageGone = "This message no longer exists."
    private static let mainChat = "Watchtower's chat writes this chat itself. Update the app."
    private static let workbenchGone = "This workbench no longer exists."
    private static let badRequest = "Watchtower couldn't apply this: the request is incomplete. Update the app."

    // One switch over the commands the Desktop sends.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func apply(_ command: TowerCommand, _ data: Data) async throws -> Data {
        let decoder = JSONDecoder()
        func request<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type, from: data) }
        func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
        let done = try encode(ChatDone())
        switch command {
        case .chatNew:
            let q = try request(ChatNewRequest.self)
            let id = try await db.write { db -> Int64 in
                if let context = q.context {
                    // Go: a "Not clear?" chat only for a live workbench, in the creating transaction.
                    if context.type == AskExplainKey.contextType {
                        guard let bench = Self.askExplainWorkbenchID(context.id) else {
                            throw Refusal(sentence: Self.badRequest, code: .unsupported)
                        }
                        guard try Bool.fetchOne(db, sql: "SELECT 1 FROM projects WHERE id = ?", arguments: [bench]) != nil else {
                            throw Refusal(sentence: Self.workbenchGone)
                        }
                    }
                    if context.reuse == true,
                       let existing = try ChatConversationQueries.fetchByContext(db, type: context.type, id: context.id) {
                        return existing.id
                    }
                    let conv = try ChatConversationQueries.create(db, title: context.title ?? "", contextType: context.type,
                                                                  contextID: context.id, projectID: q.projectID)
                    if let routing = q.routing, !routing.automatic, let provider = routing.provider {
                        try ChatConversationQueries.setProviderModel(db, id: conv.id, provider: provider, model: routing.model)
                    }
                    return conv.id
                }
                // Go refuses: a main chat is the chat engine's.
                throw Refusal(sentence: Self.mainChat)
            }
            return try encode(ChatNewResponse(conversationID: id))
        case .chatSetTitle:
            let q = try request(ChatSetTitleRequest.self)
            try await write(gone: Self.chatGone) { db in
                try Self.refuseMainChat(db, q.conversationID)
                if q.ifEmpty == true {
                    try db.execute(sql: "UPDATE chat_conversations SET title = ? WHERE id = ? AND title = ''",
                                   arguments: [q.title, q.conversationID])
                } else {
                    try ChatConversationQueries.updateTitle(db, id: q.conversationID, title: q.title)
                }
            }
            return done
        case .chatDelete:
            let q = try request(ChatDeleteRequest.self)
            guard let contextType = q.contextType, !contextType.isEmpty else { throw Refusal(sentence: Self.mainChat) }
            try await write(gone: Self.chatGone) { db in
                guard let conv = try ChatConversationQueries.fetchByID(db, id: q.conversationID),
                      conv.contextType == contextType else {
                    throw Refusal(sentence: Self.chatGone)
                }
                try ChatMessageQueries.deleteByConversation(db, conversationID: q.conversationID)
                try ChatConversationQueries.delete(db, id: q.conversationID)
            }
            return done
        case .chatSetModel:
            let q = try request(ChatSetModelRequest.self)
            try await write(gone: Self.chatGone) { db in
                try Self.refuseMainChat(db, q.conversationID)
                try ChatConversationQueries.setProviderModel(db, id: q.conversationID, provider: q.provider, model: q.model)
                guard db.changesCount > 0 else { throw Refusal(sentence: Self.chatGone) }
            }
            return done
        case .chatContext:
            let q = try request(ChatContextRequest.self)
            let moved = try await db.write { db -> Bool in
                if let existing = try ChatConversationQueries.fetchByContext(db, type: q.contextType, id: q.contextID) {
                    let used = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM chat_messages WHERE conversation_id = ?)",
                                                 arguments: [existing.id]) ?? false
                    if used { return false }
                    try ChatConversationQueries.delete(db, id: existing.id)
                }
                try db.execute(sql: """
                    UPDATE chat_conversations SET context_type = ?, context_id = ?, updated_at = ?
                    WHERE id = ? AND context_type = 'automation_draft'
                    """, arguments: [q.contextType, q.contextID, Date().timeIntervalSince1970, q.conversationID])
                return db.changesCount > 0
            }
            return try encode(ChatChanged(changed: moved))
        case .chatReviewerThread:
            let q = try request(ChatReviewerThreadRequest.self)
            let id = try await db.write { try ReviewerThreadQueries.ensure($0, projectID: q.projectID, folderID: q.folderID, branch: q.branch) }
            return try encode(ChatNewResponse(conversationID: id))
        case .chatCodeQuestionDeleteEmpty:
            let q = try request(ChatDeleteEmptyCodeQuestionsRequest.self)
            let count = try await db.write {
                try CodeQuestionList.deleteEmpty($0, workbenchID: q.workbenchID, createdBefore: q.createdBefore,
                                                 keeping: Set(q.keeping ?? []))
            }
            return try encode(ChatCount(count: Int64(count)))
        case .chatDraftSave:
            let q = try request(ChatDraftSaveRequest.self)
            try await db.write { db in
                guard let key = try Self.askExplainDraftKey(db, q.surfaceKey) else { return }
                try QueuedDraftQueries.save(db, key: key, text: q.text, at: Date())
            }
            return done
        case .chatDraftClear:
            let q = try request(ChatDraftClearRequest.self)
            try await db.write { db in
                try QueuedDraftQueries.clear(db, key: q.surfaceKey)
                if let key = try Self.askExplainDraftKey(db, q.surfaceKey) { try QueuedDraftQueries.clear(db, key: key) }
            }
            return done
        case .chatMessageAppend:
            let q = try request(ChatMessageAppendRequest.self)
            let id = try await write(gone: Self.chatGone) { db -> Int64 in
                try ChatMessageQueries.requireConversation(db, id: q.conversationID)
                return try ChatMessageQueries.insert(db, conversationID: q.conversationID, role: q.role, text: q.text)
            }
            return try encode(ChatMessageAppendResponse(messageID: id))
        case .chatReplyFinish:
            let q = try request(ChatReplyFinishRequest.self)
            try await write(gone: Self.messageGone) { db in
                try db.execute(sql: """
                    UPDATE chat_messages SET text = ?, status = ?, error_code = ?, error_message = ?
                    WHERE id = ? AND conversation_id = ? AND role = 'assistant'
                    """, arguments: [q.text, q.status, q.errorCode, q.errorMessage, q.messageID, q.conversationID])
                guard db.changesCount > 0 else { throw Refusal(sentence: Self.messageGone) }
                if q.status == "complete" { try ChatConversationQueries.touch(db, id: q.conversationID) }
            }
            return done
        case .ideasCreateFromChat:
            // Go's `db.CreateIdeaFromChatTx`: an active chat-born item with
            // its `chat` mention, written at once.
            let q = try request(IdeaFromChatRequest.self)
            let (id, at) = try await db.write { db -> (Int64, String) in
                let now = try String.fetchOne(db, sql: "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now')") ?? ""
                let firstLine = q.body.split(maxSplits: 1, omittingEmptySubsequences: false,
                                             whereSeparator: \.isNewline).first ?? ""
                try db.execute(sql: """
                    INSERT INTO ideas (kind, title, essence, status, source, last_mention_at, chat_born)
                    VALUES (?, ?, ?, 'active', 'owner', ?, 1)
                    """, arguments: [q.kind, String(firstLine.prefix(120)), q.body, now])
                let id = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO idea_mentions (idea_id, source, ref, quote, said_at) VALUES (?, 'chat', ?, ?, ?)
                    """, arguments: [id, "chat:\(q.conversationID):\(q.messageID)", q.body, now])
                let at = try String.fetchOne(db, sql: "SELECT updated_at FROM ideas WHERE id = ?", arguments: [id]) ?? ""
                return (id, at)
            }
            return try encode(CreatedResult(id: id, updatedAt: at))
        case .ideasUndoChat:
            // Go's `db.UndoChatIdeaTx`: deleted only while untouched.
            let q = try request(IdeaUndoChatRequest.self)
            let undone = try await db.write { db -> Bool in
                let untouched = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM ideas WHERE id = ? AND chat_born = 1 AND status = 'active'
                        AND merged_into_id IS NULL AND updated_at = ?
                        AND NOT EXISTS (SELECT 1 FROM ideas c WHERE c.merged_into_id = ideas.id))
                    """, arguments: [q.id, q.createdUpdatedAt]) ?? false
                guard untouched else { return false }
                try db.execute(sql: "DELETE FROM ideas WHERE id = ?", arguments: [q.id])
                return true
            }
            return try encode(UndoChatResult(undone: undone))
        default:
            throw Refusal(sentence: "FakeChatTower does not model \(command.rawValue).")
        }
    }

    /// Go's `db.AskExplainWorkbenchID`: `<workbench>:<ask>` or
    /// `<workbench>:<ask>:<item>`, both ids canonical positive (written back
    /// exactly as given), the item `q` or `s` and a canonical positive
    /// number; nil for any other shape.
    package static func askExplainWorkbenchID(_ contextID: String) -> Int64? {
        let parts = contextID.split(separator: ":", omittingEmptySubsequences: false)
        func canonical(_ part: Substring) -> Int64? {
            guard let id = Int64(part), id > 0, String(id) == part else { return nil }
            return id
        }
        guard parts.count == 2 || parts.count == 3, let bench = canonical(parts[0]), canonical(parts[1]) != nil
        else { return nil }
        if parts.count == 3 {
            let item = parts[2]
            guard let kind = item.first, kind == "q" || kind == "s", canonical(item.dropFirst()) != nil else { return nil }
        }
        return bench
    }

    /// Go's `askExplainDraftKeyTx`: a "Not clear?" chat's draft key follows
    /// its conversation — nil once it is deleted, the current key after a
    /// merge re-keyed it; any other key as is.
    private static func askExplainDraftKey(_ db: Database, _ key: String) throws -> String? {
        let prefix = AskExplainKey.contextType + "."
        guard key.hasPrefix(prefix), let dot = key.lastIndex(of: "."),
              let conversation = Int64(key[key.index(after: dot)...]) else { return key }
        guard let contextID = try String.fetchOne(db, sql: """
            SELECT context_id FROM chat_conversations WHERE id = ? AND context_type = ?
            """, arguments: [conversation, AskExplainKey.contextType]) else { return nil }
        return "\(prefix)\(contextID).\(conversation)"
    }

    /// Go's `refuseMainChatTx`: a main chat's rows are the chat engine's.
    private static func refuseMainChat(_ db: Database, _ conversationID: Int64) throws {
        guard let conv = try ChatConversationQueries.fetchByID(db, id: conversationID) else { return }
        if conv.contextType == nil { throw Refusal(sentence: mainChat) }
    }

    /// A write whose missing row (or broken foreign key) answers `gone`.
    @discardableResult
    private func write<T: Sendable>(gone: String, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await db.write(body)
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
            throw Refusal(sentence: gone)
        } catch is ChatContextGoneError {
            throw Refusal(sentence: gone)
        } catch is RowNotFoundError {
            throw Refusal(sentence: gone)
        }
    }
}
