import ChatWire
import Foundation
import Observation
import WatchtowerChatText

/// A file attached to the draft (stored by the engine, sent with the next message by id).
public struct ChatComposerAttachment: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
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
    public static let overLimitLine = "A message holds up to 32 000 characters."
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
    /// What a new chat may be started with; set by a shell that shows the model and project chips.
    public var newChatChoices: ChatNewChatChoices?
    /// Why the shell holds sending (for example a send that waits for the hub after a relaunch): Send is off and the
    /// line says so. Nil lets the composer send.
    public var hold: String?
    /// The shell holds files of its own that go with the next send (the phone's staged pills, uploaded by its client):
    /// a saved chat may then send them with no text, as it may its own `attachments`.
    public var hasShellAttachments = false
    /// The `/` picker's catalog, read once.
    private var skillCatalog: [ChatSkill]?
    public private(set) var notice: String?

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
        guard conversation.reachability == .connected, !conversation.isGone, !isSending, hold == nil,
              !conversation.isTurnRunning, fits else { return false }
        return sendText != nil || ((!attachments.isEmpty || hasShellAttachments) && conversation.conversationID != nil)
    }

    /// The text is within the hub's cap (32 000 Unicode scalars, `ChatLimits`).
    public var fits: Bool { sendText.map(ChatLimits.textFits) ?? true }

    public var placeholder: String {
        if !quotes.isEmpty { return Self.quotePlaceholder }
        return conversation.conversationID == nil ? Self.newPlaceholder : Self.followUpPlaceholder
    }

    /// The state line above the field: unreachable, stopped, gone.
    public var stateLine: ChatStateLine.Content? { conversation.stateLine }

    /// The line under the field: a refusal, else the edit mode.
    public var line: String? {
        if let hold { return hold }
        if !fits { return Self.overLimitLine }
        return notice ?? conversation.notice ?? (editing != nil ? Self.editingLine : nil)
    }

    /// Sends the draft. The text stays until the echo is `applied` (CHAT-01); a lost echo resends with the same key.
    public func send() async {
        guard canSend else { return }
        isSending = true
        defer { isSending = false }
        let sentDraft = draft
        let text = sendText ?? ""
        // A client that creates the chat with its first turn sends conversation 0 (the send is kept from the start).
        let createsOnTurn = conversation.conversationID == nil && client.createsConversationOnTurn
        let conversationID: Int64
        if createsOnTurn {
            conversationID = 0
        } else {
            guard let id = await ensureConversation() else { return }
            conversationID = id
        }
        let request = ChatTurnRequest(
            conversationID: conversationID,
            mode: editing == nil ? .send : .edit,
            messageID: editing,
            text: text,
            attachmentIDs: attachments.map(\.id),
            routing: routing,
            compose: skill == nil && mentions.isEmpty ? nil : ChatCompose(skill: skill, mentions: mentions),
            clientKey: UUID().uuidString,
            projectID: createsOnTurn ? projectID : nil,
            draft: ChatTurnDraft(text: draft, quotes: quotes.map(\.quote))
        )
        let echo = await conversation.sendTurn(request)
        if case .applied(.turn(let started))? = echo, let created = started.conversationID, conversation.conversationID == nil {
            conversation.adopt(created)
        }
        switch echo {
        case .applied?:
            notice = nil
            draft = Self.remainder(of: draft, after: sentDraft)
            quotes = []
            attachments = []
            mentions = []
            skill = nil
            editing = nil
        case let .refused(code, message)?:
            notice = ChatConversationModel.refusalLine(code: code, message: message)
        case nil:
            break
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

    /// Attaches a file: the Mac passes a path, the phone a sealed upload.
    public func attach(_ source: ChatAttachSource) async {
        guard let conversationID = await ensureConversation() else { return }
        let name: String = switch source {
        case .path(let path): URL(fileURLWithPath: path).lastPathComponent
        case .sealedUpload(let upload): upload.name
        }
        do {
            switch try await client.send(.attach(conversationID: conversationID, source: source)) {
            case .applied(.attachment(let id)):
                attachments.append(ChatComposerAttachment(id: id, name: name))
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
        attachments.removeAll { $0.id == id }
        guard let conversationID = conversation.conversationID else { return }
        _ = try? await client.send(.attachDiscard(conversationID: conversationID, attachmentID: id))
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

    /// Starts editing an owner message: its text goes into the field.
    public func beginEditing(_ message: ChatFeed.Message) {
        editing = message.id
        draft = message.text
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
