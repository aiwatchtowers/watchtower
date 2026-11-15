import Foundation
import Observation
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// One conversation's unsent message (iPhone chat spec §6.2): the typed text, the quote batch, the files, the
/// message being edited, the last refusal's reason, and, for a new chat, the model and project picked.
struct ChatDraft: Equatable {
    var text = ""
    var quotes: [ChatQuoteDraft] = []
    var attachments: [ComposerAttachment] = []
    /// The owner message an Edit replaces (`chat_turn mode edit`).
    var editing: Int64?
    /// Why the last send came back (shown over the composer until the next send).
    var notice: String?
    /// A new chat's model; nil is Auto.
    var routing: ChatRouting?
    /// A new chat's project; nil is none.
    var projectID: Int64?
}

/// The drafts of one hub's chats, kept in memory per conversation (0 is a new chat), so leaving a chat and coming
/// back finds the text where it was.
@MainActor
@Observable
final class ChatDraftStore {
    private(set) var drafts: [Int64: ChatDraft] = [:]

    func draft(_ conversation: Int64) -> ChatDraft { drafts[conversation] ?? ChatDraft() }

    func update(_ conversation: Int64, _ change: (inout ChatDraft) -> Void) {
        var draft = draft(conversation)
        change(&draft)
        drafts[conversation] = draft
    }

    /// A refused send's text and files back, kept beside anything typed since.
    func restore(_ sent: ChatDraft, conversation: Int64) {
        update(conversation) { draft in
            let typed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.text = typed.isEmpty ? sent.text : sent.text + "\n\n" + draft.text
            draft.quotes = sent.quotes + draft.quotes.filter { quote in !sent.quotes.contains { $0.id == quote.id } }
            draft.attachments = sent.attachments
            draft.editing = sent.editing
            draft.notice = sent.notice
        }
    }

    func setNotice(_ notice: String?, conversation: Int64) {
        update(conversation) { $0.notice = notice }
    }

    func setAttachmentState(_ id: String, _ state: ComposerAttachment.State, conversation: Int64) {
        update(conversation) { draft in
            if let index = draft.attachments.firstIndex(where: { $0.id == id }) { draft.attachments[index].state = state }
        }
    }

    func clearAttachments(conversation: Int64) {
        update(conversation) { $0.attachments = [] }
    }

    /// A new chat's draft becomes its conversation's.
    func move(from old: Int64, to new: Int64) {
        guard let draft = drafts.removeValue(forKey: old) else { return }
        drafts[new] = draft
    }
}

/// What the composer shows now (mockups 2a–2i): the field's placeholder, Send or Stop, the model and project
/// chips (editable only on a new chat: they lock after the first message), the quote batch, the + menu, and the
/// lines over it. Every text is here.
struct ChatComposerModel: Equatable {
    struct Chip: Equatable {
        let label: String
        let editable: Bool
    }

    static let newPlaceholder = "Message"
    static let followUpPlaceholder = "Ask a follow-up"
    static let quotePlaceholder = "Ask about the quote"
    static let editingLine = "Editing your message"
    static let overLimitLine = "A message holds up to 32 000 characters."
    static let autoLabel = "Auto"
    static let noProject = "No project"
    static let sendLabel = "Send"
    static let stopLabel = "Stop"
    static let attachLabel = "Attach"
    static let cancelEditLabel = "Cancel editing"

    let placeholder: String
    /// The text a Send sends: the quote batch and the typed text, the Mac's exact format (`ChatQuoteReply.compose`).
    let sendText: String?
    let canSend: Bool
    /// A turn runs (here or on the Mac): the button is Stop.
    let showsStop: Bool
    let canStop: Bool
    /// The + menu: only while the hub answers.
    let canAttach: Bool
    let modelChip: Chip
    let projectChip: Chip
    let quotes: [ChatQuoteDraft]
    /// The line over the composer: the refusal's reason, the edit in progress or the length limit.
    let line: String?
    let isEditing: Bool

    init(
        draft: ChatDraft,
        isNew: Bool,
        online: Bool,
        lease: ChatFeed.Lease?,
        sending: Bool,
        list: ChatList?,
        conversation: ChatFeed.Conversation?
    ) {
        quotes = draft.quotes
        isEditing = draft.editing != nil
        placeholder = !draft.quotes.isEmpty ? Self.quotePlaceholder : isNew ? Self.newPlaceholder : Self.followUpPlaceholder
        let typed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        sendText = draft.quotes.isEmpty ? (typed.isEmpty ? nil : typed) : ChatQuoteReply.compose(quotes: draft.quotes, typed: typed)
        let fits = sendText.map(ChatLimits.textFits) ?? true
        let uploading = draft.attachments.contains { $0.state == .uploading }
        showsStop = lease != nil
        canStop = online && !(lease?.turnID.isEmpty ?? true)
        canSend = online && lease == nil && !sending && !uploading && fits && (sendText != nil || (!draft.attachments.isEmpty && !isNew))
        canAttach = online && draft.editing == nil
        let models = list?.models ?? []
        if isNew {
            modelChip = Chip(label: Self.modelLabel(draft.routing, provider: nil, models: models), editable: true)
            let project = draft.projectID.flatMap { id in list?.projects.first { $0.id == id }?.name }
            projectChip = Chip(label: project ?? Self.noProject, editable: true)
        } else {
            modelChip = Chip(
                label: Self.modelLabel(conversation?.routing, provider: conversation?.actualProvider, models: models), editable: false
            )
            projectChip = Chip(label: conversation?.project?.name ?? Self.noProject, editable: false)
        }
        if !fits {
            line = Self.overLimitLine
        } else if let notice = draft.notice {
            line = notice
        } else {
            line = draft.editing != nil ? Self.editingLine : nil
        }
    }

    /// "Auto · Claude" (the provider's name), or the pinned model's name.
    static func modelLabel(_ routing: ChatRouting?, provider: String?, models: [ChatList.Model]) -> String {
        if let routing, routing.mode == "pinned" {
            let named = models.first { $0.provider == routing.provider && $0.model == (routing.model ?? "") }
            return named?.displayName ?? routing.model ?? routing.provider ?? autoLabel
        }
        let wanted = provider.flatMap { $0.isEmpty ? nil : $0 }
        let name = models.first { wanted == nil || $0.provider == wanted }?.displayName ?? wanted?.capitalized
        return name.map { "\(autoLabel) · \($0)" } ?? autoLabel
    }

    /// The model menu: Auto, then every model the hub offers.
    static func modelOptions(_ list: ChatList?) -> [(label: String, routing: ChatRouting?)] {
        [(autoLabel, nil)] + (list?.models ?? []).map { model in
            (model.displayName, ChatRouting(mode: "pinned", provider: model.provider, model: model.model))
        }
    }
}
