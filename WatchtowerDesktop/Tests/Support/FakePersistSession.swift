import Foundation
import GRDB
import WatchtowerCore
import WatchtowerChatText

/// What `ai session --persist` writes, for a `FakeChatSessionProcess` (the
/// Go session's `chatstore.Start` and `Turn`, as `chat_turn_cases.json`
/// pins them): the lease claim and the starting rows of a turn, its text,
/// steps and end, the lease released. Runs on `queue`, off the main thread,
/// one step at a time, so a test holding the writer never blocks the Mac.
package final class FakePersistSession: @unchecked Sendable {
    package let queue = DispatchQueue(label: "FakePersistSession")
    /// Let go when the process exits: a test run keeps every test case (and
    /// its fakes) alive, and each open pool holds file descriptors.
    private var dbStorage: (any DatabaseWriter)?
    private var db: any DatabaseWriter {
        get throws {
            guard let dbStorage else { throw ChatContextGoneError() }
            return dbStorage
        }
    }
    private let conversationID: Int64
    private let ownerID: String
    private let projectID: Int64?
    /// `--provider`/`--model`: a pinned session records them on every turn.
    private let pinned: (provider: String, model: String?)?
    /// The last reply this process answered (`ChatContinuity`).
    private var leaf: Int64?
    private var turn: Turn?

    private struct Turn {
        let turnID: String
        let assistantID: Int64
        var text = ""
        var steps: [String] = []
        var usage: ChatUsage?
    }

    private struct BusyError: Error {}

    init?(arguments: [String], db: any DatabaseWriter) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard arguments.contains("--persist"), let conv = value("--conversation").flatMap(Int64.init) else { return nil }
        dbStorage = db
        conversationID = conv
        ownerID = value("--lease-owner-id") ?? ""
        projectID = value("--project-id").flatMap(Int64.init)
        pinned = value("--provider").map { ($0, value("--model")) }
    }

    // MARK: - Start

    /// The answer to a `turn` line, and the turn the provider gets (nil when
    /// it was not started).
    func start(_ command: ChatTurnCommand) -> (ChatEvent, ChatTurnCommand?) {
        guard let start = command.start else {
            return (.refused(ChatRefusal(turnID: nil, reason: "turn_id_required", holder: "")), nil)
        }
        let nowMS = ChatLease.milliseconds(Date())
        let lease = ChatLease(conversationID: conversationID, owner: .desktop, ownerID: ownerID,
                              turnID: command.turnID, startedAtMS: nowMS, heartbeatAtMS: nowMS)
        do {
            let rows = try (try db).write { db in try self.writeStart(db, command: command, start: start, lease: lease) }
            let replay = start.mode != .send || rows.historyTip != leaf
            turn = Turn(turnID: command.turnID, assistantID: rows.assistantID)
            let text = start.screen.map { $0 + "\n\n" + rows.sendText } ?? rows.sendText
            let forwarded = ChatTurnCommand(turnID: command.turnID, text: text, attachments: rows.attachments,
                                            replay: replay)
            let started = ChatStarted(conversationID: conversationID, ownerMessageID: rows.ownerID,
                                      assistantMessageID: rows.assistantID, turnID: command.turnID)
            return (.started(started), forwarded)
        } catch is BusyError {
            let holder = (try? (try? db)?.read { try ChatLeaseQueries.fetch($0, conversationID: self.conversationID) })??.owner
            return (.refused(ChatRefusal(turnID: command.turnID, reason: "conversation_busy",
                                         holder: holder?.rawValue ?? "")), nil)
        } catch {
            return (.error(ChatSessionError(
                turnID: command.turnID, code: .internalError,
                message: "Your message wasn't sent because it couldn't be saved: \(error.localizedDescription)",
                retryable: false)), nil)
        }
    }

    private struct StartRows {
        let ownerID: Int64
        let assistantID: Int64
        let historyTip: Int64?
        let sendText: String
        let attachments: [ChatCommandAttachment]
    }

    private func writeStart(
        _ db: Database, command: ChatTurnCommand, start: ChatTurnStart, lease: ChatLease
    ) throws -> StartRows {
        guard try ChatLeaseQueries.claim(db, lease, nowMS: lease.startedAtMS) else { throw BusyError() }
        let path = try ChatTreeQueries.activePath(db, conversationID: conversationID)
        var historyTip: Int64?
        var userText = command.text
        var ownerID: Int64 = 0
        var filesOf: Int64 = 0
        switch start.mode {
        case .send:
            historyTip = path.last?.id
        case .regenerate:
            guard let owner = try message(db, start.parentID) else { throw ChatContextGoneError() }
            historyTip = owner.parentID
            userText = owner.text
            ownerID = owner.id
            filesOf = owner.id
        case .edit:
            guard let original = try message(db, start.editMessageID) else { throw ChatContextGoneError() }
            historyTip = original.parentID
            userText = ChatTurnComposer.recompose(stored: original.text, newBody: command.text)
            filesOf = original.id
        }
        var wroteOwner = false
        if start.mode != .regenerate {
            // A legacy owner question with no reply gets an empty partial one.
            if let tip = historyTip, let tipRow = try message(db, tip), tipRow.isUser {
                historyTip = try ChatTreeQueries.insertAssistant(db, conversationID: conversationID, parentID: tip,
                                                                 turnID: tipRow.turnID, provider: pinned?.provider ?? "",
                                                                 model: "").id
            }
            ownerID = try ChatTreeQueries.insertUser(db, conversationID: conversationID, parentID: historyTip,
                                                     text: userText, turnID: command.turnID).id
            wroteOwner = true
            if start.mode == .send {
                try ChatAttachmentQueries.link(db, attachmentIDs: start.attachmentIDs, messageID: ownerID)
                filesOf = ownerID
                _ = try ArtifactCommentQueries.markSent(db, ids: start.quotes, at: Date())
            }
            try ChatConversationQueries.setPrefixTitle(db, id: conversationID, text: start.titleText ?? userText)
        }
        if let pinned {
            try ChatConversationQueries.setRouting(db, id: conversationID, automatic: false, provider: pinned.provider,
                                                   model: pinned.model)
        }
        let assistant = try ChatTreeQueries.insertAssistant(db, conversationID: conversationID, parentID: ownerID,
                                                            turnID: command.turnID, provider: pinned?.provider ?? "",
                                                            model: pinned?.model ?? "")
        let files = try ChatAttachment.fetchAll(db, sql: "SELECT * FROM chat_attachments WHERE message_id = ? ORDER BY id",
                                                arguments: [filesOf])
        return StartRows(ownerID: wroteOwner || start.mode == .regenerate ? ownerID : 0, assistantID: assistant.id,
                         historyTip: historyTip, sendText: userText,
                         attachments: files.map { ChatCommandAttachment(path: $0.path, mime: $0.mime, name: $0.name) })
    }

    private func message(_ db: Database, _ id: Int64?) throws -> ChatMessageRecord? {
        guard let id else { return nil }
        return try ChatMessageRecord.fetchOne(db, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id])
    }

    // MARK: - The turn

    /// Whether `event` ends the running turn (its `turn_done`, or an error of it or of the session).
    func endsTurn(_ event: ChatEvent) -> Bool {
        guard let turn else { return false }
        switch event {
        case let .turnDone(turnID, _, _): return turnID == turn.turnID
        case let .error(error): return error.turnID == nil || error.turnID == turn.turnID
        default: return false
        }
    }

    /// Folds `event` into the turn's rows; the turn id when it ended it.
    @discardableResult
    func apply(_ event: ChatEvent) -> String? { // swiftlint:disable:this cyclomatic_complexity
        switch event {
        case let .sessionReady(sid, provider, model, _, _):
            try? (try? db)?.write { db in
                if let sid, !sid.isEmpty {
                    try ChatConversationQueries.updateSessionID(db, id: self.conversationID, sessionID: sid,
                                                                projectID: self.projectID)
                }
                guard !provider.isEmpty else { return }
                try db.execute(sql: "UPDATE chat_conversations SET actual_provider = ?, actual_model = ? WHERE id = ?",
                               arguments: [provider, model, self.conversationID])
                if let reply = self.turn?.assistantID {
                    try db.execute(sql: "UPDATE chat_messages SET provider = ?, model = ? WHERE id = ?",
                                   arguments: [provider, model, reply])
                }
            }
        case let .textDelta(turnID, text):
            guard var current = turn, current.turnID == turnID else { return nil }
            current.text += text
            turn = current
            try? (try? db)?.write { db in
                try ChatTreeQueries.updateAssistant(db, id: current.assistantID, text: current.text, status: "partial",
                                                    tokensIn: nil, tokensOut: nil, errorCode: nil, errorMessage: nil)
            }
        case let .toolStart(start):
            stepStarted(turnID: start.turnID, id: start.id, name: start.name, args: start.argsJSON)
        case let .toolWait(wait):
            if turn?.steps.contains(wait.id) == false { stepStarted(turnID: wait.turnID, id: wait.id, name: "", args: "{}") }
        case let .toolEnd(end):
            guard let current = turn, current.turnID == end.turnID else { return nil }
            try? (try? db)?.write { db in
                try ChatStepQueries.finish(db, messageID: current.assistantID, toolID: end.id, ok: end.ok,
                                           summary: end.summary, sourcesJSON: ChatSource.encodeList(end.sources),
                                           endedAt: Date().timeIntervalSince1970)
            }
        case let .usage(usage):
            guard turn?.turnID == usage.turnID else { return nil }
            turn?.usage = usage
        case let .turnDone(turnID, status, sid):
            if let sid, !sid.isEmpty {
                try? (try? db)?.write { db in
                    try ChatConversationQueries.updateSessionID(db, id: self.conversationID, sessionID: sid,
                                                                projectID: self.projectID)
                }
            }
            guard turn?.turnID == turnID else { return nil }
            return finalize(status: status == .complete ? "complete" : "partial", error: nil)
        case let .error(error):
            guard let current = turn, error.turnID == nil || error.turnID == current.turnID else { return nil }
            let status = error.persistenceCode == ChatErrorCode.quotaExhausted.rawValue && !current.text.isEmpty
                ? "partial" : "error"
            return finalize(status: status, error: error)
        default:
            break
        }
        return nil
    }

    /// The process is gone: its database goes too.
    func close() {
        dbStorage = nil
    }

    /// The session ended with a turn open: what streamed stays `partial`.
    func endOnExit() -> String? {
        guard turn != nil else { return nil }
        return finalize(status: "partial", error: nil)
    }

    private func stepStarted(turnID: String, id: String, name: String, args: String) {
        guard var current = turn, current.turnID == turnID else { return }
        let seq = current.steps.firstIndex(of: id) ?? current.steps.count
        if !current.steps.contains(id) { current.steps.append(id) }
        turn = current
        try? (try? db)?.write { db in
            try ChatStepQueries.upsertStart(db, messageID: current.assistantID, seq: seq, toolID: id, name: name,
                                            argsJSON: args, startedAt: Date().timeIntervalSince1970)
            try LiveSlackMark.markIfSlackStep(db, messageID: current.assistantID, name: name)
        }
    }

    private func finalize(status: String, error: ChatSessionError?) -> String? {
        guard let current = turn else { return nil }
        turn = nil
        try? (try? db)?.write { db in
            try ChatTreeQueries.updateAssistant(db, id: current.assistantID, text: current.text, status: status,
                                                tokensIn: current.usage?.tokensIn, tokensOut: current.usage?.tokensOut,
                                                errorCode: error?.persistenceCode, errorMessage: error?.message)
            try ChatLeaseQueries.release(db, conversationID: self.conversationID, turnID: current.turnID)
            if let model = current.usage?.model, !model.isEmpty {
                try ChatTreeQueries.setModel(db, messageID: current.assistantID, model: model)
            }
            try LiveSlackMark.markIfUsed(db, conversationID: self.conversationID, messageID: current.assistantID)
            if status != "error" {
                _ = try ChatArtifactQueries.persistArtifacts(db, conversationID: self.conversationID,
                                                             messageID: current.assistantID, text: current.text)
            }
        }
        leaf = status == "error" ? nil : current.assistantID
        return current.turnID
    }
}
