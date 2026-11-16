import ChatWire
import Foundation
import Observation
import WatchtowerChatText

/// A file attached to the draft (stored by the engine, sent with the next message by id).
public struct ChatComposerAttachment: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    /// The file's type and size as attached ("" and 0 when unknown).
    public let mime: String
    public let size: Int64

    public init(id: Int64, name: String, mime: String = "", size: Int64 = 0) {
        self.id = id
        self.name = name
        self.mime = mime
        self.size = size
    }
}

/// The composer (unified chat spec §6.1, CHAT-01): the draft stays in the field until the engine's echo is `applied`;
/// a refused send (`busy` from a turn another device started, or any other refusal) leaves it there with the reason,
/// and while the chat is unreachable or the conversation is gone Send is off and the draft is kept.
@MainActor
@Observable
public final class ChatComposerModel {
    public static let newPlaceholder = "Message"
    public static let followUpPlaceholder = "Ask a follow-up"
    public static let quotePlaceholder = "Ask about the quote"
    public static let editingLine = "Editing your message"
    public static let sendLabel = "Send"
    public static let stopLabel = "Stop"

    public let conversation: ChatConversationModel
    public var draft = ""
    public var quotes: [ChatQuoteDraft] = []
    public private(set) var attachments: [ChatComposerAttachment] = []
    /// The `@` mentions picked into the draft (the engine composes the references and drops the ones no longer in
    /// the text).
    public var mentions: [ChatCompose.Mention] = []
    /// The `/` skill picked for the next message.
    public var skill: String?
    /// The routing of a new conversation (nil: automatic).
    public var routing: ChatRouting?
    /// The project of a new conversation.
    public var projectID: Int64?
    /// Editing this owner message instead of sending a new one.
    public var editing: Int64?
    public private(set) var isSending = false
    /// The `/` picker's catalog, read once.
    private var skillCatalog: [ChatSkill]?
    public private(set) var notice: String?
    /// Files being attached (their names) and attachments being removed: the chips show it.
    public private(set) var importing: [String] = []
    public private(set) var removing: Set<Int64> = []
    /// A send waits for the files attached just before it.
    public private(set) var isWaitingForAttachments = false
    private var importWaiters: [CheckedContinuation<Void, Never>] = []

    public init(conversation: ChatConversationModel) {
        self.conversation = conversation
    }

    private var client: any ChatClient { conversation.client }

    /// The text the next message carries: the typed text, or the quotes with it.
    public var sendText: String? {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard quotes.isEmpty else { return ChatQuoteReply.compose(quotes: quotes, typed: typed) }
        return typed.isEmpty ? nil : typed
    }

    public var canSend: Bool {
        guard conversation.reachability == .connected, !conversation.isGone, !isSending,
              !conversation.isTurnRunning else { return false }
        return sendText != nil || ((!attachments.isEmpty || !importing.isEmpty) && conversation.conversationID != nil)
    }

    public var placeholder: String {
        if !quotes.isEmpty { return Self.quotePlaceholder }
        return conversation.conversationID == nil ? Self.newPlaceholder : Self.followUpPlaceholder
    }

    /// The state line above the field: unreachable, stopped, gone.
    public var stateLine: ChatStateLine.Content? { conversation.stateLine }

    /// The line under the field: a refusal, else the edit mode.
    public var line: String? {
        notice ?? conversation.notice ?? (editing != nil ? Self.editingLine : nil)
    }

    /// Sends the draft. The text stays until the echo is `applied` (CHAT-01); a lost echo resends with the same key.
    /// `screenContext` (the Mac's ⌘/ panel: the screen the owner asked from) goes to the provider only; the engine
    /// never stores it, so the stored owner text is the typed text alone.
    /// Whether the engine applied the send.
    @discardableResult
    public func send(screenContext: String? = nil) async -> Bool {
        guard canSend else { return false }
        isSending = true
        defer { isSending = false }
        if !importing.isEmpty {
            // The files dropped or pasted just before Send go with it.
            isWaitingForAttachments = true
            await withCheckedContinuation { importWaiters.append($0) }
            isWaitingForAttachments = false
        }
        let sentDraft = draft
        let text = sendText ?? ""
        guard let conversationID = await ensureConversation() else { return false }
        let request = ChatTurnRequest(
            conversationID: conversationID,
            mode: editing == nil ? .send : .edit,
            messageID: editing,
            text: text,
            attachmentIDs: attachments.map(\.id),
            routing: routing,
            compose: skill == nil && mentions.isEmpty ? nil : ChatCompose(skill: skill, mentions: mentions),
            screenContext: screenContext,
            clientKey: UUID().uuidString
        )
        let echo = await conversation.sendTurn(request)
        switch echo {
        case .applied?:
            notice = nil
            draft = Self.remainder(of: draft, after: sentDraft)
            quotes = []
            attachments = []
            mentions = []
            skill = nil
            editing = nil
            return true
        case let .refused(code, message)?:
            notice = ChatConversationModel.refusalLine(code: code, message: message)
            return false
        case nil:
            return false
        }
    }

    /// Sends a fixed owner text the owner pressed — a fallback's `chat_turn`, a question card's answers — as its own
    /// message, leaving the draft as it is. Refused, it goes into the field so it is not lost.
    public func sendFixed(_ text: String) async {
        guard conversation.reachability == .connected, !conversation.isGone, !isSending, !conversation.isTurnRunning,
              let conversationID = conversation.conversationID else { return }
        isSending = true
        defer { isSending = false }
        let request = ChatTurnRequest(conversationID: conversationID, mode: .send, text: text, clientKey: UUID().uuidString)
        switch await conversation.sendTurn(request) {
        case .applied?:
            notice = nil
        case let .refused(code, message)?:
            notice = ChatConversationModel.refusalLine(code: code, message: message)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = text }
        case nil:
            break
        }
    }

    /// Sends the open artifact comments with these ids as the owner's message (the Mac's "Send N comments"): the
    /// engine composes them into the owner row and marks them sent in the same transaction (CHAT-05: a comment
    /// reaches the assistant only as the owner's message). Whether the engine took the turn.
    public func sendArtifactComments(_ ids: [Int64]) async -> Bool {
        guard !ids.isEmpty, conversation.reachability == .connected, !conversation.isGone, !isSending,
              !conversation.isTurnRunning, let conversationID = conversation.conversationID else { return false }
        isSending = true
        defer { isSending = false }
        let request = ChatTurnRequest(conversationID: conversationID, mode: .send, text: "", artifactCommentIDs: ids,
                                      clientKey: UUID().uuidString)
        switch await conversation.sendTurn(request) {
        case .applied?:
            notice = nil
            return true
        case let .refused(code, message)?:
            notice = ChatConversationModel.refusalLine(code: code, message: message)
            return false
        case nil:
            return false
        }
    }

    /// Attaches a file: the Mac passes a path, the phone a sealed upload.
    public func attach(_ source: ChatAttachSource) async {
        let name: String = switch source {
        case .path(let path): URL(fileURLWithPath: path).lastPathComponent
        case .sealedUpload(let upload): upload.name
        }
        importing.append(name)
        defer { importDone(name) }
        guard let conversationID = await ensureConversation() else { return }
        let (mime, size) = Self.facts(of: source)
        do {
            switch try await client.send(.attach(conversationID: conversationID, source: source)) {
            case .applied(.attachment(let id)):
                attachments.append(ChatComposerAttachment(id: id, name: name, mime: mime, size: size))
                notice = nil
            case .applied:
                break
            case let .refused(code, message):
                notice = ChatConversationModel.refusalLine(code: code, message: message)
            }
        } catch {
            notice = ChatConversationModel.couldNotSend
        }
    }

    /// Drops an attachment from the draft (the engine deletes the stored file).
    public func removeAttachment(_ id: Int64) async {
        guard let conversationID = conversation.conversationID else {
            attachments.removeAll { $0.id == id }
            return
        }
        removing.insert(id)
        defer { removing.remove(id) }
        _ = try? await client.send(.attachDiscard(conversationID: conversationID, attachmentID: id))
        attachments.removeAll { $0.id == id }
    }

    /// The chat the next send goes into, made now when there is none yet (the Mac's landing makes it on the first
    /// keystroke so its session warms up). Nil when the engine could not make it (`line` says why).
    public func prepareConversation() async -> Int64? {
        await ensureConversation()
    }

    private func importDone(_ name: String) {
        if let index = importing.firstIndex(of: name) { importing.remove(at: index) }
        guard importing.isEmpty else { return }
        let waiters = importWaiters
        importWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// The type and size of an attachment's file, as far as the client can tell before the engine's answer.
    static func facts(of source: ChatAttachSource) -> (mime: String, size: Int64) {
        switch source {
        case .sealedUpload(let upload):
            return (upload.mime, upload.size)
        case .path(let path):
            let url = URL(fileURLWithPath: path)
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 64)
            } ?? Data()
            let kind = ChatAttachmentLimits.classify(head: head, fileName: url.lastPathComponent)?.0
            return (kind?.mime ?? "", size)
        }
    }

    /// The `@` picker's hits.
    public func search(entities query: String) async -> [ChatEntityHit] {
        guard case .applied(.entities(let hits))? = try? await client.send(.entitySearch(query: query, kinds: [])) else {
            return []
        }
        return hits
    }

    /// The `/` picker's skills.
    public func skills() async -> [ChatSkill] {
        guard case .applied(.skills(let skills))? = try? await client.send(.skillsList) else { return [] }
        return skills
    }

    /// The skills the `/` picker offers for the `/query` at `cursor` (a `/` at the start of the message, spec §6.4):
    /// the catalog is read once per composer (`skills_list`), then filtered by the typed prefix. Empty when no `/`
    /// trigger is active.
    public func skillHits(cursor: Int) async -> [ChatSkill] {
        guard let trigger = MentionTokenizer.activeSkill(text: draft, cursor: cursor) else { return [] }
        if skillCatalog == nil {
            let loaded = await skills()
            if !loaded.isEmpty { skillCatalog = loaded }
        }
        return (skillCatalog ?? []).filter { trigger.query.isEmpty || $0.name.hasPrefix(trigger.query) }
    }

    /// Picks a skill: it rides with the next message, and the `/query` leaves the text (the Mac's picker rule).
    /// Returns the caret after the edit.
    public func pick(skill picked: ChatSkill, cursor: Int) -> Int {
        guard let trigger = MentionTokenizer.activeSkill(text: draft, cursor: cursor) else { return cursor }
        skill = picked.name
        let edit = MentionTokenizer.replace(trigger, in: draft, cursor: cursor, with: "")
        draft = edit.text
        return edit.cursor
    }

    public func clearSkill() {
        skill = nil
    }

    /// Adds a quoted passage of an answer ("Ask about this"): it goes with the next message (`ChatQuoteReply`).
    public func addQuote(_ passage: String) {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        quotes.append(ChatQuoteDraft(quote: trimmed, comment: ""))
    }

    /// Picks a mention: the `@query` at `cursor` becomes `@Label`.
    public func pick(_ hit: ChatEntityHit, cursor: Int) -> Int {
        guard let trigger = MentionTokenizer.activeMention(text: draft, cursor: cursor) else { return cursor }
        let edit = MentionTokenizer.replace(trigger, in: draft, cursor: cursor, with: "@\(hit.label) ")
        draft = edit.text
        if !mentions.contains(where: { $0.kind == hit.kind && $0.id == hit.id }) {
            mentions.append(ChatCompose.Mention(kind: hit.kind, id: hit.id, label: hit.label))
        }
        return edit.cursor
    }

    /// Starts editing an owner message: its words go into the field (the engine keeps its skill and mentions).
    public func beginEditing(_ message: ChatFeed.Message) {
        editing = message.id
        draft = ChatOwnerText.displayParts(message.text).body
    }

    public func cancelEditing() {
        editing = nil
        draft = ""
    }

    /// The conversation to send into: the open one, or a new one (the first send of a new chat).
    private func ensureConversation() async -> Int64? {
        if let id = conversation.conversationID { return id }
        do {
            switch try await client.send(.new(projectID: projectID, routing: routing ?? ChatRouting(mode: "auto"))) {
            case .applied(.conversation(let id)):
                conversation.adopt(id)
                return id
            case let .refused(code, message):
                notice = ChatConversationModel.refusalLine(code: code, message: message)
            case .applied:
                notice = ChatConversationModel.couldNotSend
            }
        } catch {
            notice = ChatConversationModel.couldNotSend
        }
        return nil
    }

    /// What is left of the field after the sent text was applied: what the owner typed meanwhile.
    static func remainder(of current: String, after sent: String) -> String {
        guard current != sent else { return "" }
        guard current.hasPrefix(sent) else { return current }
        return String(current.dropFirst(sent.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
