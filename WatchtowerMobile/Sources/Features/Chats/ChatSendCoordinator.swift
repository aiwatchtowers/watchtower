import ChatWire
import Foundation
import Observation
import os
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

/// Takes one queued chat action back from the outbox (`ActionOutbox.withdraw(actionID:)`).
typealias ChatWithdraw = @MainActor (String) async -> OutboxWithdrawal

/// A chat action still waiting in the outbox, as recovery matches it.
struct QueuedChatAction: Equatable, Sendable {
    let kind: ActionKind
    let params: [String: JSONValue]
}

/// How one attachment reaches the hub: sealed once and sent, the same record again on a retry of a lost send. The
/// app's is `ChatUploadLedger`; `none` refuses (no hub to upload to).
struct ChatUploads {
    let send: @MainActor (ChatAttachmentUploadPayload, URL) async throws -> Void

    static let none = Self { _, _ in throw ChatUploadUnavailable() }
}

struct ChatUploadUnavailable: Error {}

/// The phone's uploads in flight (iPhone chat spec §4.5): the Kit's uploader keeps no ledger, so this keeps each
/// upload's `Sealed` result until its echo arrives, and a retry of a lost send sends the same record again. The
/// echo (`applied` or `failed`) drops the sealed file and goes on to the chats.
actor ChatUploadLedger: ChatAttachmentAcking {
    private let transport: SecureTransport
    private let directory: URL
    private var sealed: [String: ChatAttachmentUploader.Sealed] = [:]
    private var onEcho: (@Sendable (ChatAttachmentUploadPayload) async -> Void)?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatUploadLedger")

    /// Where a hub's sealed uploads wait for their echo.
    static func directory(hubID: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chat-uploads", isDirectory: true)
            .appendingPathComponent(hubID, isDirectory: true)
    }

    init(transport: SecureTransport, directory: URL) {
        self.transport = transport
        self.directory = directory
    }

    func setEchoHandler(_ handler: @escaping @Sendable (ChatAttachmentUploadPayload) async -> Void) {
        onEcho = handler
    }

    /// Seals `file` the first time an upload id is seen, then sends the sealed record.
    func upload(_ payload: ChatAttachmentUploadPayload, file: URL) async throws {
        let record: ChatAttachmentUploader.Sealed
        if let held = sealed[payload.uploadID] {
            record = held
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(payload.uploadID + ".sealed")
            record = try await ChatAttachmentUploader.seal(payload, file: file, sealedFile: target, transport: transport)
            sealed[payload.uploadID] = record
        }
        try await ChatAttachmentUploader.send(record, transport: transport)
    }

    /// Whether an upload still waits for its echo (tests).
    func holds(_ uploadID: String) -> Bool { sealed[uploadID] != nil }

    func applyEcho(_ upload: ChatAttachmentUploadPayload) async throws {
        guard upload.status != .pending else { return }
        if let held = sealed.removeValue(forKey: upload.uploadID) {
            try? FileManager.default.removeItem(at: held.sealedFile)
        }
        await onEcho?(upload)
    }
}

/// The phone's sends (iPhone chat spec §6.3): a new chat first sends `chat_new`, then the attachments upload, then
/// `chat_turn`. The owner bubble stays pending until the `chat_turn` echo is `applied`; a refused echo puts the
/// text back into the composer with the reason (CHAT-01 on the phone: the owner's text is never lost). Regenerate,
/// Retry and Edit go the same way. Each send is kept in the hub's copy until its turn is applied, so a kill or a
/// relaunch mid-send brings the text back (`recover`); an echo that never comes gives the text back after
/// `echoPatience` with "Couldn't send that".
@MainActor
@Observable
final class ChatSendCoordinator {
    /// A send on its way, shown as the owner's pending bubble.
    struct PendingTurn: Equatable {
        let conversationID: Int64
        let mode: ChatTurnMode
        /// The owner's text as sent (empty for a regenerate).
        let text: String
        let attachments: [String]
        /// Set once the `chat_turn` echo is applied: the bubble stops dimming until the feed has the message.
        var userMessageID: Int64?
        /// The patience ran out but the action could not be taken back (the hub may have it): the bubble says it
        /// waits for the hub, and the echo settles it whenever it comes.
        var isStalled = false

        var isApplied: Bool { userMessageID != nil }
    }

    /// What one send asks for.
    struct Request: Equatable {
        var conversationID: Int64
        var mode: ChatTurnMode = .send
        var messageID: Int64?
        var text: String
        var attachments: [ComposerAttachment] = []
        /// For a new chat (`chat_new`).
        var projectID: Int64?
        var routing: ChatRouting?
        /// What goes back into the composer on a refusal: the typed text and the quotes (the sent text is composed).
        var draft: ChatDraft?
        /// Files the hub already holds (`chat_attachment` applied), sent with the turn before `attachments`.
        var attachmentIDs: [Int64] = []
        /// A refusal puts the text back into `ChatDraftStore`. Off for a send from a `ChatUI` composer, which keeps its
        /// own draft until the echo is applied; the kept send (`chat_outgoing`) still guards a kill either way.
        var restoresDraft = true
    }

    /// How one send ended.
    enum Outcome: Equatable {
        /// The turn's echo is applied: the conversation it went to and the echo's result.
        case applied(conversationID: Int64, result: [String: JSONValue]?)
        /// Refused by the hub (its reason and message), or never sent (no reason, `couldNotSend`).
        case refused(ActionReason?, String)
    }

    enum Echo: Equatable {
        case applied([String: JSONValue]?)
        case failed(ChatActionFailure)
    }

    static let couldNotSend = "Couldn't send that. Try again."
    /// How long a send waits for one echo before it gives the text back. Sending is only possible while the hub
    /// answers, so a missing echo is a lost one.
    static let echoPatience: Duration = .seconds(120)

    /// By conversation.
    private(set) var pending: [Int64: PendingTurn] = [:]
    /// A new chat's conversation once `chat_new` was applied (the screen follows it).
    private(set) var created: [String: Int64] = [:]
    @ObservationIgnored private let sender: ChatSender
    @ObservationIgnored private let uploads: ChatUploads
    @ObservationIgnored private let drafts: ChatDraftStore
    @ObservationIgnored private let copy: ChatOfflineCopy
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let withdraw: ChatWithdraw
    @ObservationIgnored private var waiters: [String: CheckedContinuation<Echo, Never>] = [:]
    /// Echoes that came before their waiter. Only a send in flight can still claim one: a send's own are dropped
    /// when it ends, and every one once no send is in flight (an applied chat_new/chat_turn of no send here).
    @ObservationIgnored private var early: [String: Echo] = [:]
    @ObservationIgnored private var sendsInFlight = 0
    /// `request`s waiting for their echo: while any does, every applied chat echo is held for it.
    @ObservationIgnored private var requestsInFlight = 0
    @ObservationIgnored private var knownFailures: [String: ChatActionFailure] = [:]
    @ObservationIgnored private var uploadWaiters: [String: CheckedContinuation<ChatAttachmentUploadPayload?, Never>] = [:]
    @ObservationIgnored private var earlyUploads: [String: ChatAttachmentUploadPayload] = [:]
    /// Sends a previous run left on its way, not settled yet (`recover`).
    @ObservationIgnored private var recovered: [ChatOutgoingSend]
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatSendCoordinator")

    init(
        sender: ChatSender,
        uploads: ChatUploads,
        drafts: ChatDraftStore,
        copy: ChatOfflineCopy,
        withdraw: @escaping ChatWithdraw = { _ in .withdrawn },
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.withdraw = withdraw
        self.sender = sender
        self.uploads = uploads
        self.drafts = drafts
        self.copy = copy
        self.sleep = sleep
        recovered = []
        do {
            let kept = try copy.outgoing()
            recovered = kept.sends
            for key in kept.undecodableKeys {
                do { try copy.deleteOutgoing(key) } catch {
                    Self.logger.error("unreadable kept send not deleted: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
        } catch {
            // Nothing is recovered and nothing deleted: the rows stay for the next launch that can read them.
            Self.logger.error("kept sends unreadable: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func isSending(_ conversationID: Int64) -> Bool { pending[conversationID].map { !$0.isApplied } ?? false }

    /// Runs one send to its end. `onCreated` hears a new chat's conversation id as soon as `chat_new` is applied.
    /// Returns the conversation the turn went to, nil when it was refused (the draft is back then).
    @discardableResult
    func send(_ request: Request, clientKey: String = UUID().uuidString, onCreated: ((Int64) -> Void)? = nil) async -> Int64? {
        guard case let .applied(conversation, _) = await sendTurn(request, clientKey: clientKey, onCreated: onCreated) else { return nil }
        return conversation
    }

    /// `send`, telling how it ended: the applied echo's result, or the refusal's reason and message.
    func sendTurn(_ request: Request, clientKey: String = UUID().uuidString, onCreated: ((Int64) -> Void)? = nil) async -> Outcome {
        var record = Self.record(request, clientKey: clientKey)
        sendsInFlight += 1
        defer { ended(record) }
        keep(record)
        var conversation = request.conversationID
        let names = request.attachments.map(\.name)
        pending[conversation] = PendingTurn(conversationID: conversation, mode: request.mode, text: request.text, attachments: names)
        if conversation == 0 {
            let created: Int64
            switch await create(request, record: &record) {
            case let .success(id): created = id
            case let .failure(refusal): return .refused(refusal.reason, refusal.message)
            }
            pending[0] = nil
            pending[created] = PendingTurn(conversationID: created, mode: request.mode, text: request.text, attachments: names)
            drafts.move(from: 0, to: created)
            self.created[clientKey] = created
            conversation = created
            record.conversationID = created
            keep(record)
            onCreated?(created)
        }
        let uploaded: [Int64]
        switch await upload(request, conversation: conversation, record: &record) {
        case let .success(ids): uploaded = ids
        case let .failure(refusal): return .refused(refusal.reason, refusal.message)
        }
        let turn = ChatTurnParams(
            conversationID: conversation, mode: request.mode, messageID: request.messageID, text: request.text,
            attachmentIDs: request.attachmentIDs + uploaded, routing: nil
        )
        switch await run(turn, record: &record, \.turnActionID) {
        case let .applied(result):
            forget(record)
            drafts.clearAttachments(conversation: conversation)
            if case let .integer(id)? = result?["user_message_id"] {
                pending[conversation]?.userMessageID = id
            } else {
                pending[conversation] = nil
            }
            return .applied(conversationID: conversation, result: result)
        case let .failed(failure):
            let message = refuse(request, conversation: conversation, message: failure.message, record: record)
            return .refused(failure.reason, message)
        }
    }

    /// One chat action that is not a turn (a new chat, Stop, a read mark, a row action, a picker): queued, then its
    /// echo awaited with the same patience as a turn. Nothing is kept across a kill: none of these carries the
    /// owner's text.
    func request<P: ActionParams>(_ params: P) async -> Echo {
        requestsInFlight += 1
        var record = ChatOutgoingSend.untracked
        defer {
            requestsInFlight -= 1
            if let id = record.turnActionID { early[id] = nil }
            if sendsInFlight == 0, requestsInFlight == 0 { early.removeAll() }
        }
        return await run(params, record: &record, \.turnActionID, keeps: false)
    }

    /// One file to the hub (`chat_attachment`): sent, then its echo awaited. The plaintext goes once the hub holds
    /// it. Nil when the upload could not be sent or no echo came within the patience.
    func upload(_ payload: ChatAttachmentUploadPayload, file: URL) async -> ChatAttachmentUploadPayload? {
        do {
            try await uploads.send(payload, file)
        } catch {
            Self.logger.warning("chat upload not sent: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        let echo = await waitForUpload(payload.uploadID)
        if echo?.status == .applied { ChatAttachmentPrep.discard(file) }
        return echo
    }

    /// An applied echo of a chat action. Only the kinds a send waits for are kept for a waiter still on its way.
    func receiveApplied(_ action: ActionRequestPayload) {
        if let index = recovered.firstIndex(where: { $0.turnActionID == action.id }) {
            let record = recovered.remove(at: index)
            forget(record)
            pending[record.conversationID] = nil
        }
        if waiters[action.id] != nil || [.chatNew, .chatTurn].contains(action.kind) || requestsInFlight > 0 {
            resolve(action.id, .applied(action.result))
        }
    }

    /// The chat actions the hub refused (the snapshot's failed rows).
    func receive(failures: [String: ChatActionFailure]) {
        knownFailures = failures
        for (id, failure) in failures where waiters[id] != nil {
            resolve(id, .failed(failure))
        }
    }

    /// An upload's echo from the relay feed.
    func receiveUpload(_ upload: ChatAttachmentUploadPayload) {
        if let waiter = uploadWaiters.removeValue(forKey: upload.uploadID) {
            waiter.resume(returning: upload)
        } else {
            earlyUploads[upload.uploadID] = upload
        }
    }

    /// A pending bubble goes once the feed shows the message it became.
    func settle(feeds: [Int64: ChatFeedEntry]) {
        for (id, turn) in pending {
            guard let message = turn.userMessageID, let feed = feeds[id]?.feed else { continue }
            if feed.messages.contains(where: { $0.id >= message }) { pending[id] = nil }
        }
    }

    /// Settles the sends a previous run left on its way against the outbox as it stands now: a turn the hub
    /// refused or never got gives its text back with the reason; a turn still queued waits for its echo (with the
    /// usual patience); a turn gone from the outbox was applied.
    func recover(failures: [String: ChatActionFailure], queued: [String: QueuedChatAction]) {
        guard !recovered.isEmpty else { return }
        for var record in recovered {
            if record.turnActionID == nil, let turn = Self.queuedTurn(of: record, in: queued) {
                // Killed after the outbox took the turn, before the kept send heard its id (M2): the outbox has it.
                record.turnActionID = turn
                if let index = recovered.firstIndex(where: { $0.clientKey == record.clientKey }) { recovered[index] = record }
                keep(record)
            }
            if let turn = record.turnActionID, queued[turn] != nil {
                guard pending[record.conversationID] == nil else { continue }
                pending[record.conversationID] = PendingTurn(
                    conversationID: record.conversationID, mode: ChatTurnMode(rawValue: record.mode) ?? .send, text: record.text,
                    attachments: record.files.map(\.name)
                )
                waitRecovered(turn, conversation: record.conversationID)
                continue
            }
            recovered.removeAll { $0.clientKey == record.clientKey }
            pending[record.conversationID] = nil
            if let turn = record.turnActionID, failures[turn] == nil {
                forget(record)
                continue
            }
            let message = record.turnActionID.flatMap { failures[$0]?.message }.flatMap { $0.isEmpty ? nil : $0 } ?? Self.couldNotSend
            restore(record, message: message)
        }
    }

    // MARK: - Steps

    private func create(_ request: Request, record: inout ChatOutgoingSend) async -> Result<Int64, Refusal> {
        let params = ChatNewParams(clientKey: record.clientKey, projectID: request.projectID, routing: request.routing)
        switch await run(params, record: &record, \.newActionID) {
        case let .applied(result):
            if case let .integer(id)? = result?["conversation_id"] { return .success(id) }
            return .failure(Refusal(reason: nil, message: refuse(request, conversation: 0, message: Self.couldNotSend, record: record)))
        case let .failed(failure):
            return .failure(Refusal(reason: failure.reason, message: refuse(request, conversation: 0, message: failure.message, record: record)))
        }
    }

    /// Why a step of a send did not go on.
    private struct Refusal: Error {
        let reason: ActionReason?
        let message: String
    }

    /// Uploads every attachment not uploaded yet, one at a time; nil (the draft back, the pill failed) on the first
    /// one that does not make it. An uploaded file's plaintext copy goes at once.
    private func upload(_ request: Request, conversation: Int64, record: inout ChatOutgoingSend) async -> Result<[Int64], Refusal> {
        var ids: [Int64] = []
        for attachment in request.attachments {
            if case let .uploaded(id) = attachment.state {
                ids.append(id)
                continue
            }
            drafts.setAttachmentState(attachment.id, .uploading, conversation: conversation)
            let payload = ChatAttachmentUploadPayload(
                uploadID: attachment.id, conversationID: conversation, name: attachment.name, mime: attachment.mime, size: attachment.size
            )
            do {
                try await uploads.send(payload, attachment.file)
            } catch {
                Self.logger.warning("chat upload not sent: \(String(describing: type(of: error)), privacy: .public)")
                drafts.setAttachmentState(attachment.id, .failed(Self.couldNotSend), conversation: conversation)
                let message = refuse(request, conversation: conversation, message: Self.couldNotSend, record: record)
                return .failure(Refusal(reason: nil, message: message))
            }
            let echo = await waitForUpload(attachment.id)
            guard let echo, echo.status == .applied, let id = echo.attachmentID else {
                let message = echo?.errorMessage ?? Self.couldNotSend
                drafts.setAttachmentState(attachment.id, .failed(message), conversation: conversation)
                return .failure(Refusal(reason: nil, message: refuse(request, conversation: conversation, message: message, record: record)))
            }
            drafts.setAttachmentState(attachment.id, .uploaded(id), conversation: conversation)
            if let index = record.files.firstIndex(where: { $0.id == attachment.id }) { record.files[index].attachmentID = id }
            keep(record)
            ChatAttachmentPrep.discard(attachment.file)
            ids.append(id)
        }
        return .success(ids)
    }

    /// Queues `params`, notes its action id in the kept send, then waits for the echo.
    private func run<P: ActionParams>(
        _ params: P, record: inout ChatOutgoingSend, _ slot: WritableKeyPath<ChatOutgoingSend, String?>, keeps: Bool = true
    ) async -> Echo {
        let id: String
        do {
            id = try await sender(params)
        } catch {
            Self.logger.warning("chat action not queued: \(String(describing: type(of: error)), privacy: .public)")
            return .failed(ChatActionFailure(reason: nil, message: Self.couldNotSend))
        }
        record[keyPath: slot] = id
        if keeps { keep(record) }
        if let echo = early.removeValue(forKey: id) { return echo }
        if let failure = knownFailures[id] { return .failed(failure) }
        let conversation = record.conversationID
        let timer = Task { [weak self, sleep] in
            do { try await sleep(Self.echoPatience) } catch { return }
            await self?.giveUp(id, conversation: conversation, waits: keeps)
        }
        let echo = await withCheckedContinuation { waiters[id] = $0 }
        timer.cancel()
        return echo
    }

    private func waitForUpload(_ uploadID: String) async -> ChatAttachmentUploadPayload? {
        if let echo = earlyUploads.removeValue(forKey: uploadID) { return echo }
        let timer = Task { [weak self, sleep] in
            do { try await sleep(Self.echoPatience) } catch { return }
            self?.uploadWaiters.removeValue(forKey: uploadID)?.resume(returning: nil)
        }
        let echo = await withCheckedContinuation { uploadWaiters[uploadID] = $0 }
        timer.cancel()
        return echo
    }

    /// The patience ran out: the action is taken back if the hub cannot have it, and only then the waiter hears
    /// "Couldn't send that". A send the hub may have stays (`waits`): the bubble waits for the hub and its echo
    /// settles it. A `request` hears it either way: it carries no text of the owner's.
    private func giveUp(_ id: String, conversation: Int64, waits: Bool) async {
        guard waiters[id] != nil else { return }
        if await withdraw(id) == .withdrawn || !waits {
            waiters.removeValue(forKey: id)?.resume(returning: .failed(ChatActionFailure(reason: nil, message: Self.couldNotSend)))
        } else {
            pending[conversation]?.isStalled = true
        }
    }

    /// A recovered turn still queued: its echo settles it (`receiveApplied`, `recover` on a refusal); after the
    /// patience it is taken back and its text given back, unless the hub may have it.
    private func waitRecovered(_ turn: String, conversation: Int64) {
        Task { [weak self, sleep] in
            do { try await sleep(Self.echoPatience) } catch { return }
            guard let self, self.recovered.contains(where: { $0.turnActionID == turn }) else { return }
            guard await self.withdraw(turn) == .withdrawn,
                  let index = self.recovered.firstIndex(where: { $0.turnActionID == turn }) else {
                self.pending[conversation]?.isStalled = true
                return
            }
            let record = self.recovered.remove(at: index)
            self.pending[record.conversationID] = nil
            self.restore(record, message: Self.couldNotSend)
        }
    }

    /// The queued `chat_turn` a kept send became, matched by its conversation and text.
    private static func queuedTurn(of record: ChatOutgoingSend, in queued: [String: QueuedChatAction]) -> String? {
        queued.first { _, action in
            guard action.kind == .chatTurn, let params = try? ChatTurnParams(wireParams: action.params) else { return false }
            return params.conversationID == record.conversationID && params.text == record.text && params.mode.rawValue == record.mode
        }?.key
    }

    private func resolve(_ id: String, _ echo: Echo) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: echo)
        } else {
            early[id] = echo
        }
    }

    /// Puts the owner's text and files back (the attachments already uploaded keep their ids) with the reason, unless
    /// the composer keeps its own draft (`restoresDraft` off). Returns the reason as shown.
    @discardableResult
    private func refuse(_ request: Request, conversation: Int64, message: String, record: ChatOutgoingSend) -> String {
        forget(record)
        pending[conversation] = nil
        let message = message.isEmpty ? Self.couldNotSend : message
        guard request.restoresDraft else { return message }
        guard request.mode != .regenerate else {
            drafts.setNotice(message, conversation: conversation)
            return message
        }
        var draft = request.draft ?? ChatDraft(text: request.text)
        let current = drafts.draft(conversation).attachments
        draft.attachments = request.attachments.map { sent in current.first { $0.id == sent.id } ?? sent }
        draft.editing = request.mode == .edit ? request.messageID : nil
        draft.notice = message
        drafts.restore(draft, conversation: conversation)
        return message
    }

    /// A kept send from a previous run, back in its composer.
    private func restore(_ record: ChatOutgoingSend, message: String) {
        forget(record)
        guard record.mode != ChatTurnMode.regenerate.rawValue else {
            drafts.setNotice(message, conversation: record.conversationID)
            return
        }
        let files = record.files.compactMap { file -> ComposerAttachment? in
            let url = URL(fileURLWithPath: file.path)
            if let id = file.attachmentID {
                return ComposerAttachment(id: file.id, name: file.name, mime: file.mime, size: file.size, file: url, state: .uploaded(id))
            }
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return ComposerAttachment(id: UUID().uuidString, name: file.name, mime: file.mime, size: file.size, file: url)
        }
        let draft = ChatDraft(
            text: record.draftText, quotes: record.quotes.map { ChatQuoteDraft(quote: $0, comment: "") }, attachments: files,
            editing: record.mode == ChatTurnMode.edit.rawValue ? record.messageID : nil, notice: message
        )
        drafts.restore(draft, conversation: record.conversationID)
    }

    private static func record(_ request: Request, clientKey: String) -> ChatOutgoingSend {
        ChatOutgoingSend(
            clientKey: clientKey, conversationID: request.conversationID, mode: request.mode.rawValue, messageID: request.messageID,
            text: request.text, draftText: request.draft?.text ?? request.text, quotes: request.draft?.quotes.map(\.quote) ?? [],
            files: request.attachments.map { .init(id: $0.id, name: $0.name, mime: $0.mime, size: $0.size, path: $0.file.path) },
            createdAt: Date()
        )
    }

    /// A send ended (applied or given back): its early echoes go, and every one once no send is in flight.
    private func ended(_ record: ChatOutgoingSend) {
        sendsInFlight -= 1
        for id in [record.newActionID, record.turnActionID].compactMap({ $0 }) { early[id] = nil }
        if sendsInFlight == 0 { early.removeAll() }
    }

    /// Echoes held for a waiter not there yet (tests).
    var earlyEchoCount: Int { early.count }

    private func keep(_ record: ChatOutgoingSend) {
        do {
            try copy.saveOutgoing(record)
        } catch {
            Self.logger.error("chat send not kept: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func forget(_ record: ChatOutgoingSend) {
        do {
            try copy.deleteOutgoing(record.clientKey)
        } catch {
            Self.logger.error("kept chat send not dropped: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

extension ChatOutgoingSend {
    /// The slot a `request` notes its action id in; never kept.
    fileprivate static var untracked: Self {
        Self(clientKey: "", conversationID: 0, mode: "", messageID: nil, text: "", draftText: "", quotes: [], files: [], createdAt: Date())
    }
}
