import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface
import WatchtowerChatText

/// A stand-in for the daemon's `chat.*` commands over a test database: each
/// call is recorded and applied with the test writers (`ChatTestWriters`,
/// the SQL the Go writers are pinned to), or refused as scripted.
package final class FakeChatTower: ChatTowerSending, @unchecked Sendable {
    package struct Call {
        package let command: TowerCommand
        package let params: [String: Any]
    }

    private struct Refusal: Error {
        let sentence: String
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
        if let refused { return .refused(refused) }
        await beforeApply?(command)
        do {
            let result = try await apply(command, data)
            return .ok(try JSONDecoder().decode(Resp.self, from: result))
        } catch let refusal as Refusal {
            return .refused(refusal.sentence)
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    // MARK: - Commands

    private static let chatGone = "This chat no longer exists."
    private static let messageGone = "This message no longer exists."

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
                return try ChatConversationQueries.create(db, projectID: q.projectID).id
            }
            return try encode(ChatNewResponse(conversationID: id))
        case .chatPin:
            let q = try request(ChatPinRequest.self)
            try await write(gone: Self.chatGone) { try ChatConversationQueries.pin($0, id: q.conversationID, pinned: q.pinned) }
            return done
        case .chatRename:
            let q = try request(ChatRenameRequest.self)
            try await write(gone: Self.chatGone) { try ChatConversationQueries.rename($0, id: q.conversationID, title: q.title) }
            return done
        case .chatSetTitle:
            let q = try request(ChatSetTitleRequest.self)
            try await write(gone: Self.chatGone) { db in
                if q.ifEmpty == true {
                    try db.execute(sql: "UPDATE chat_conversations SET title = ? WHERE id = ? AND title = ''",
                                   arguments: [q.title, q.conversationID])
                } else {
                    try ChatConversationQueries.updateTitle(db, id: q.conversationID, title: q.title)
                }
            }
            return done
        case .chatArchive:
            let q = try request(ChatConversationRequest.self)
            try await write(gone: Self.chatGone) { try ChatConversationQueries.archive($0, id: q.conversationID) }
            return done
        case .chatDelete:
            let q = try request(ChatDeleteRequest.self)
            try await write(gone: Self.chatGone) { db in
                guard try ChatConversationQueries.fetchByID(db, id: q.conversationID) != nil else {
                    throw Refusal(sentence: Self.chatGone)
                }
                try ChatMessageQueries.deleteByConversation(db, conversationID: q.conversationID)
                try ChatConversationQueries.delete(db, id: q.conversationID)
            }
            return done
        case .chatDeleteUntouched:
            let q = try request(ChatDeleteUntouchedRequest.self)
            let changed = try await db.write {
                try ChatConversationQueries.deleteIfUntouched($0, id: q.conversationID, createdAt: q.createdAt,
                                                              projectID: q.projectID)
            }
            return try encode(ChatChanged(changed: changed))
        case .chatBranch:
            let q = try request(ChatBranchRequest.self)
            try await write(gone: Self.messageGone) { db in
                guard let conv = try Int64.fetchOne(db, sql: "SELECT conversation_id FROM chat_messages WHERE id = ?",
                                                    arguments: [q.messageID]) else { throw Refusal(sentence: Self.messageGone) }
                try ChatTreeQueries.selectSibling(db, conversationID: conv, siblingID: q.messageID)
            }
            return done
        case .chatRead:
            let q = try request(ChatReadRequest.self)
            try await write(gone: Self.chatGone) { try ChatConversationQueries.markRead($0, id: q.conversationID) }
            return done
        case .chatSetProject:
            let q = try request(ChatSetProjectRequest.self)
            try await write(gone: Self.chatGone) {
                try ChatConversationQueries.setProject($0, id: q.conversationID, projectID: q.projectID)
            }
            return done
        case .chatSetRouting:
            let q = try request(ChatSetRoutingRequest.self)
            try await write(gone: Self.chatGone) {
                try ChatConversationQueries.setRouting($0, id: q.conversationID, automatic: q.routing.automatic,
                                                       provider: q.routing.provider ?? "", model: q.routing.model)
            }
            return done
        case .chatSetModel:
            let q = try request(ChatSetModelRequest.self)
            try await write(gone: Self.chatGone) { db in
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
            let id = try await db.write { try ReviewerThreadQueries.ensure($0, projectID: q.projectID, branch: q.branch) }
            return try encode(ChatNewResponse(conversationID: id))
        case .chatCodeQuestionDeleteEmpty:
            let q = try request(ChatDeleteEmptyCodeQuestionsRequest.self)
            let count = try await db.write {
                try CodeQuestionList.deleteEmpty($0, workbenchID: q.workbenchID, createdBefore: q.createdBefore,
                                                 keeping: Set(q.keeping ?? []))
            }
            return try encode(ChatCount(count: Int64(count)))
        case .chatAttach:
            return try await attach(try request(ChatAttachRequest.self))
        case .chatAttachDelete:
            let q = try request(ChatAttachmentRequest.self)
            let (changed, orphan) = try await db.write { db -> (Bool, String?) in
                let path = try String.fetchOne(db, sql: "SELECT path FROM chat_attachments WHERE id = ?",
                                               arguments: [q.attachmentID])
                try ChatAttachmentQueries.delete(db, id: q.attachmentID)
                let changed = db.changesCount > 0
                guard let path, try ChatAttachmentQueries.referenceCount(db, path: path) == 0 else { return (changed, nil) }
                return (changed, path)
            }
            if let orphan { try? FileManager.default.removeItem(atPath: orphan) }
            return try encode(ChatChanged(changed: changed))
        case .chatStop:
            let q = try request(ChatTurnRequest.self)
            let changed = try await db.write {
                try ChatLeaseQueries.requestCancel($0, conversationID: q.conversationID, turnID: q.turnID,
                                                   nowMS: ChatLease.milliseconds(Date()))
            }
            return try encode(ChatChanged(changed: changed))
        case .chatRecover:
            let q = try request(ChatTurnRequest.self)
            let (marked, released) = try await db.write { db -> (Int, Bool) in
                try db.execute(sql: """
                    UPDATE chat_messages SET error_code = 'session_lost'
                    WHERE conversation_id = ? AND turn_id = ? AND role = 'assistant' AND status = 'partial'
                    """, arguments: [q.conversationID, q.turnID])
                let marked = db.changesCount
                try db.execute(sql: "DELETE FROM chat_turn_leases WHERE conversation_id = ? AND turn_id = ?",
                               arguments: [q.conversationID, q.turnID])
                return (marked, db.changesCount > 0)
            }
            return try encode(ChatRecoverResponse(marked: Int64(marked), released: released))
        case .chatReleaseLaunches:
            let q = try request(ChatReleaseLaunchesRequest.self)
            let released = try await db.write { try ChatLeaseQueries.releaseEarlierDesktopLaunches($0, currentLaunchID: q.keep) }
            return try encode(ChatReleaseLaunchesResponse(released: Int64(released)))
        case .chatProjectCreate:
            let q = try request(ChatProjectCreateRequest.self)
            let project = try await db.write { try ChatProjectQueries.create($0, name: q.name) }
            return try encode(ChatProjectCreateResponse(projectID: project.id, name: project.name))
        case .chatProjectRename:
            let q = try request(ChatProjectRenameRequest.self)
            try await db.write { try ChatProjectQueries.rename($0, id: q.projectID, name: q.name) }
            return done
        case .chatProjectInstructions:
            let q = try request(ChatProjectInstructionsRequest.self)
            try await db.write { try ChatProjectQueries.updateInstructions($0, id: q.projectID, instructions: q.instructions) }
            return done
        case .chatProjectArchive:
            let q = try request(ChatProjectRequest.self)
            try await db.write { try ChatProjectQueries.archive($0, id: q.projectID) }
            return done
        case .chatProjectDelete:
            let q = try request(ChatProjectRequest.self)
            _ = try await db.write { try ChatProjectQueries.delete($0, id: q.projectID) }
            return done
        case .chatProjectAddSource:
            let q = try request(ChatProjectAddSourceRequest.self)
            guard let kind = ChatProjectSource.Kind(rawValue: q.kind) else { throw Refusal(sentence: "Unknown kind.") }
            let added = try await db.write {
                try ChatProjectQueries.addSource($0, projectID: q.projectID, kind: kind, ref: q.ref, label: q.label)
            }
            return try encode(ChatChanged(changed: added))
        case .chatProjectRemoveSource:
            let q = try request(ChatProjectSourceRequest.self)
            let removed = try await db.write { try ChatProjectQueries.removeSource($0, id: q.sourceID) }
            return try encode(ChatChanged(changed: removed))
        case .chatProjectRemoveFile:
            let q = try request(ChatAttachmentRequest.self)
            let result = try await db.write { try ChatProjectQueries.removeFile($0, id: q.attachmentID) }
            // Go removes an orphaned file after the commit.
            if let orphan = result.orphanPath { try? FileManager.default.removeItem(atPath: orphan) }
            return try encode(ChatChanged(changed: result.removed))
        case .chatCommentAdd:
            let q = try request(ChatCommentAddRequest.self)
            let anchor = CommentAnchor(quote: q.anchor.quote, prefix: q.anchor.prefix, suffix: q.anchor.suffix,
                                       heading: q.anchor.heading)
            let id = try await db.write {
                try ArtifactCommentQueries.add($0, conversationID: q.conversationID, key: q.artifactKey,
                                               version: Int(q.version), anchor: anchor, body: q.body)
            }
            return try encode(ChatCommentAddResponse(commentID: id))
        case .chatCommentDeleteUnsent:
            let q = try request(ChatCommentRequest.self)
            let changed = try await db.write { try ArtifactCommentQueries.deleteUnsent($0, id: q.commentID) }
            return try encode(ChatChanged(changed: changed))
        case .chatCommentResolve:
            let q = try request(ChatCommentRequest.self)
            let changed = try await db.write { try ArtifactCommentQueries.resolve($0, id: q.commentID) }
            return try encode(ChatChanged(changed: changed))
        case .chatCommentMarkSent:
            let q = try request(ChatCommentMarkSentRequest.self)
            let count = try await db.write {
                try ArtifactCommentQueries.markSent($0, ids: q.commentIDs, at: Date(timeIntervalSince1970: q.sentAt))
            }
            return try encode(ChatCount(count: Int64(count)))
        case .chatCommentApply:
            let q = try request(ChatCommentApplyRequest.self)
            let plan = ArtifactCommentReanchor.Plan(moved: q.moved ?? [], lost: q.lost ?? [])
            try await db.write { try ArtifactCommentQueries.apply($0, plan: plan, version: Int(q.version)) }
            return done
        case .chatDraftSave:
            let q = try request(ChatDraftSaveRequest.self)
            try await db.write { try QueuedDraftQueries.save($0, key: q.surfaceKey, text: q.text, at: Date()) }
            return done
        case .chatDraftClear:
            let q = try request(ChatDraftClearRequest.self)
            try await db.write { try QueuedDraftQueries.clear($0, key: q.surfaceKey) }
            return done
        case .chatArtifactKeep:
            let q = try request(ChatArtifactKeepRequest.self)
            do {
                try await db.write {
                    try ChatArtifactQueries.keep($0, conversationID: q.conversationID, artifactKey: q.artifactKey,
                                                 version: Int(q.version))
                }
            } catch ChatArtifactKeepError.liveSlack {
                throw Refusal(sentence: ArtifactPanelModel.liveSlackRefusal)
            }
            return done
        case .chatArtifactUnkeep:
            let q = try request(ChatArtifactUnkeepRequest.self)
            try await db.write { try ChatArtifactQueries.unkeep($0, conversationID: q.conversationID, artifactKey: q.artifactKey) }
            return done
        case .chatArtifactSaveEdit:
            let q = try request(ChatArtifactSaveEditRequest.self)
            let draft = ArtifactDraft(key: q.artifactKey, kind: q.kind, title: q.title, meta: q.meta ?? [:],
                                      content: q.content, isComplete: true)
            let version = try await db.write {
                try ChatArtifactQueries.saveVersion($0, conversationID: q.conversationID, messageID: q.messageID,
                                                    draft: draft, edited: true)
            }
            return try encode(ChatArtifactSaveEditResponse(version: Int64(version.version)))
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
        default:
            throw Refusal(sentence: "FakeChatTower does not model \(command.rawValue).")
        }
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

    private func attach(_ q: ChatAttachRequest) async throws -> Data {
        let data: Data
        if let path = q.path {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = Data(base64Encoded: q.dataBase64 ?? "") ?? Data()
        }
        let kind = try AttachmentValidator.validate(data: data, fileName: q.name).get()
        let owner: ChatAttachmentOwner = q.projectID.map { .project($0) } ?? .conversation(q.conversationID ?? 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-chat-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).\(kind.fileExtension(fallbackName: q.name))")
        try data.write(to: file)
        let (name, mime, size, path) = (q.name, kind.mime, Int64(data.count), file.path)
        let row = try await write(gone: Self.chatGone) { db -> ChatAttachment in
            let row = try ChatAttachmentQueries.insert(db, owner: owner, name: name, mime: mime, size: size, path: path,
                                                       sha256: UUID().uuidString)
            if case let .project(projectID) = owner { try ChatProjectQueries.dropSessions(db, projectID: projectID) }
            return row
        }
        return try JSONEncoder().encode(ChatAttachResponse(attachmentID: row.id, mime: row.mime, size: row.size,
                                                           path: row.path))
    }
}
