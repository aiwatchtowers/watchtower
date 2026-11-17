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
    public static let overLimitLine = "A message holds up to 32 000 characters."
    public static let sendLabel = "Send"
    public static let stopLabel = "Stop"
    public static let retryLabel = "Retry"
    /// A file whose `attach` got no answer (the chat could not be reached); the message itself may still go.
    public static let attachUnreachableLine = "Couldn't reach Watchtower to attach it."

    public let conversation: ChatConversationModel
    public var draft = "" {
        // A draft changed away from an unanswered send is a new message: typing the same words again later is a new
        // send too, never the old turn (final review M1).
        didSet { if let sent = unanswered?.content.draft, draft != sent { unanswered = nil } }
    }
    public var quotes: [ChatQuoteDraft] = []
    public private(set) var attachments: [ChatComposerAttachment] = []
    /// The `@` and `/` picker: its rows, and the mentions and skill picked for the draft.
    public let picker: ComposerPickerModel
    /// The `@` mentions picked into the draft; only those still in the text go with the message.
    public var mentions: [ChatCompose.Mention] {
        get { picker.mentions }
        set { picker.mentions = newValue }
    }
    /// The `/` skill picked for the next message.
    public var skill: String? {
        get { picker.skill }
        set { picker.skill = newValue }
    }
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
    public private(set) var notice: String?
    /// Files being attached (their names) and attachments being removed: the chips show it.
    public private(set) var importing: [String] = []
    public private(set) var removing: Set<Int64> = []
    /// A send waits for the files attached just before it.
    public private(set) var isWaitingForAttachments = false
    private var importWaiters: [CheckedContinuation<Void, Never>] = []
    /// The last send the engine never answered, and what it carried: Send again with the same content reuses its
    /// `client_key`, so the engine answers the first turn instead of starting a second (final review M1).
    @ObservationIgnored private var unanswered: (key: String, content: SentContent)?
    /// The last import refused while a send waited for its files.
    @ObservationIgnored private var lastImportRefusal: String?

    /// What a send carries, to tell a resend of the same message from a new one.
    private struct SentContent: Equatable {
        let draft: String
        let quotes: [ChatQuoteDraft]
        let attachmentIDs: [Int64]
        let mentions: [ChatCompose.Mention]
        let skill: String?
        let editing: Int64?
    }

    public init(conversation: ChatConversationModel) {
        self.conversation = conversation
        let client = conversation.client
        picker = ComposerPickerModel(
            searchEntities: { query in await Self.search(entities: query, client: client) },
            skills: { await Self.skills(client: client) }
        )
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
        let files = !attachments.isEmpty || !importing.isEmpty || hasShellAttachments
        return sendText != nil || (files && conversation.conversationID != nil)
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
    /// `screenContext` (the Mac's ⌘/ panel: the screen the owner asked from) goes to the provider only; the engine
    /// never stores it, so the stored owner text is the typed text alone.
    /// Whether the engine applied the send.
    @discardableResult
    public func send(screenContext: String? = nil) async -> Bool {
        guard canSend else { return false }
        isSending = true
        defer { isSending = false }
        var importRefusal: String?
        if !importing.isEmpty {
            // The files dropped or pasted just before Send go with it; a refused one leaves its reason, which stays
            // after the message went.
            lastImportRefusal = nil
            isWaitingForAttachments = true
            await withCheckedContinuation { importWaiters.append($0) }
            isWaitingForAttachments = false
            importRefusal = lastImportRefusal
        }
        let sentDraft = draft
        let liveMentions = ComposerPickerModel.liveMentions(text: draft, mentions: mentions)
        let content = SentContent(draft: draft, quotes: quotes, attachmentIDs: attachments.map(\.id),
                                  mentions: liveMentions, skill: skill, editing: editing)
        let clientKey = unanswered?.content == content ? unanswered?.key ?? UUID().uuidString : UUID().uuidString
        let text = sendText ?? ""
        // A client that creates the chat with its first turn sends conversation 0 (the send is kept from the start).
        let createsOnTurn = conversation.conversationID == nil && client.createsConversationOnTurn
        let conversationID: Int64
        if createsOnTurn {
            conversationID = 0
        } else {
            guard let id = await ensureConversation() else { return false }
            conversationID = id
        }
        let request = ChatTurnRequest(
            conversationID: conversationID,
            mode: editing == nil ? .send : .edit,
            messageID: editing,
            text: text,
            attachmentIDs: attachments.map(\.id),
            routing: routing,
            compose: skill == nil && liveMentions.isEmpty ? nil : ChatCompose(skill: skill, mentions: liveMentions),
            screenContext: screenContext,
            clientKey: clientKey,
            projectID: createsOnTurn ? projectID : nil,
            draft: ChatTurnDraft(text: draft, quotes: quotes.map(\.quote))
        )
        unanswered = (clientKey, content)
        let echo = await conversation.sendTurn(request)
        if case .applied(.turn(let started))? = echo, let created = started.conversationID, conversation.conversationID == nil {
            conversation.adopt(created)
        }
        switch echo {
        case .applied?:
            unanswered = nil
            notice = importRefusal
            draft = Self.remainder(of: draft, after: sentDraft)
            quotes = []
            attachments = []
            picker.reset()
            editing = nil
            return true
        case let .refused(code, message)?:
            // Unreachable past the patience: the engine may still have taken it, so the key is kept for a resend.
            if code != ChatConversationModel.unreachableCode { unanswered = nil }
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
                refuseImport(name, ChatConversationModel.refusalLine(code: code, message: message))
            }
        } catch {
            // The host went away before it answered: the file is not attached; nothing else failed.
            refuseImport(name, Self.attachUnreachableLine)
        }
    }

    /// A file that was not attached: the line names it and says why.
    private func refuseImport(_ name: String, _ reason: String) {
        let line = "\(name): " + reason
        notice = line
        lastImportRefusal = line
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

    /// The `@` picker's hits (`entity_search`).
    public func search(entities query: String) async -> [ChatEntityHit] {
        await Self.search(entities: query, client: client)
    }

    private static func search(entities query: String, client: any ChatClient) async -> [ChatEntityHit] {
        guard case .applied(.entities(let hits))? = try? await client.send(.entitySearch(query: query, kinds: [])) else {
            return []
        }
        return hits
    }

    /// The `/` picker's skills (`skills_list`).
    public func skills() async -> [ChatSkill] {
        await Self.skills(client: client)
    }

    private static func skills(client: any ChatClient) async -> [ChatSkill] {
        guard case .applied(.skills(let skills))? = try? await client.send(.skillsList) else { return [] }
        return skills
    }

    /// Adds a quoted passage of an answer ("Ask about this"): it goes with the next message (`ChatQuoteReply`).
    public func addQuote(_ passage: String) {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        quotes.append(ChatQuoteDraft(quote: trimmed, comment: ""))
    }

    /// Starts editing an owner message: its words go into the field (the engine keeps its skill and mentions).
    public func beginEditing(_ message: ChatFeed.Message) {
        editing = message.id
        draft = ChatOwnerText.displayParts(message.text).body
    }

    /// ↑ in an empty field: edits the last owner message, never while a turn runs.
    public func beginEditingLast() {
        guard !conversation.isTurnRunning,
              let last = conversation.messages.last(where: { $0.role == "user" }) else { return }
        beginEditing(last)
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
