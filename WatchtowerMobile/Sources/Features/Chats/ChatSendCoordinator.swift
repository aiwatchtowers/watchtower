import Foundation
import Observation
import os
import WatchtowerKit
import WatchtowerSync

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
/// Retry and Edit go the same way. Waits for each echo by its action or upload id.
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
    }

    enum Echo: Equatable {
        case applied([String: JSONValue]?)
        case failed(ChatActionFailure)
    }

    static let couldNotSend = "Couldn't send that. Try again."

    /// By conversation.
    private(set) var pending: [Int64: PendingTurn] = [:]
    /// A new chat's conversation once `chat_new` was applied (the screen follows it).
    private(set) var created: [String: Int64] = [:]
    @ObservationIgnored private let sender: ChatSender
    @ObservationIgnored private let uploads: ChatUploads
    @ObservationIgnored private let drafts: ChatDraftStore
    @ObservationIgnored private var waiters: [String: CheckedContinuation<Echo, Never>] = [:]
    @ObservationIgnored private var early: [String: Echo] = [:]
    @ObservationIgnored private var knownFailures: [String: ChatActionFailure] = [:]
    @ObservationIgnored private var uploadWaiters: [String: CheckedContinuation<ChatAttachmentUploadPayload, Never>] = [:]
    @ObservationIgnored private var earlyUploads: [String: ChatAttachmentUploadPayload] = [:]
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatSendCoordinator")

    init(sender: ChatSender, uploads: ChatUploads, drafts: ChatDraftStore) {
        self.sender = sender
        self.uploads = uploads
        self.drafts = drafts
    }

    func isSending(_ conversationID: Int64) -> Bool { pending[conversationID].map { !$0.isApplied } ?? false }

    /// Runs one send to its end. `onCreated` hears a new chat's conversation id as soon as `chat_new` is applied.
    /// Returns the conversation the turn went to, nil when it was refused (the draft is back then).
    @discardableResult
    func send(_ request: Request, clientKey: String = UUID().uuidString, onCreated: ((Int64) -> Void)? = nil) async -> Int64? {
        var conversation = request.conversationID
        let names = request.attachments.map(\.name)
        pending[conversation] = PendingTurn(conversationID: conversation, mode: request.mode, text: request.text, attachments: names)
        if conversation == 0 {
            guard let created = await create(request, clientKey: clientKey) else { return nil }
            pending[0] = nil
            pending[created] = PendingTurn(conversationID: created, mode: request.mode, text: request.text, attachments: names)
            drafts.move(from: 0, to: created)
            self.created[clientKey] = created
            conversation = created
            onCreated?(created)
        }
        guard let attachmentIDs = await upload(request, conversation: conversation) else { return nil }
        let turn = ChatTurnParams(
            conversationID: conversation, mode: request.mode, messageID: request.messageID, text: request.text,
            attachmentIDs: attachmentIDs, routing: nil
        )
        switch await run(turn) {
        case let .applied(result):
            drafts.clearAttachments(conversation: conversation)
            if case let .integer(id)? = result?["user_message_id"] {
                pending[conversation]?.userMessageID = id
            } else {
                pending[conversation] = nil
            }
            return conversation
        case let .failed(failure):
            refuse(request, conversation: conversation, message: failure.message)
            return nil
        }
    }

    /// An applied echo of a chat action. Only the kinds a send waits for are kept for a waiter still on its way.
    func receiveApplied(_ action: ActionRequestPayload) {
        if waiters[action.id] != nil || [.chatNew, .chatTurn].contains(action.kind) {
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

    // MARK: - Steps

    private func create(_ request: Request, clientKey: String) async -> Int64? {
        let params = ChatNewParams(clientKey: clientKey, projectID: request.projectID, routing: request.routing)
        switch await run(params) {
        case let .applied(result):
            if case let .integer(id)? = result?["conversation_id"] { return id }
            refuse(request, conversation: 0, message: Self.couldNotSend)
            return nil
        case let .failed(failure):
            refuse(request, conversation: 0, message: failure.message)
            return nil
        }
    }

    /// Uploads every attachment not uploaded yet, one at a time; nil (the draft back, the pill failed) on the first
    /// one that does not make it.
    private func upload(_ request: Request, conversation: Int64) async -> [Int64]? {
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
                refuse(request, conversation: conversation, message: Self.couldNotSend, uploaded: ids)
                return nil
            }
            let echo = await waitForUpload(attachment.id)
            guard echo.status == .applied, let id = echo.attachmentID else {
                let message = echo.errorMessage ?? Self.couldNotSend
                drafts.setAttachmentState(attachment.id, .failed(message), conversation: conversation)
                refuse(request, conversation: conversation, message: message, uploaded: ids)
                return nil
            }
            drafts.setAttachmentState(attachment.id, .uploaded(id), conversation: conversation)
            ids.append(id)
        }
        return ids
    }

    private func run<P: ActionParams>(_ params: P) async -> Echo {
        let id: String
        do {
            id = try await sender(params)
        } catch {
            Self.logger.warning("chat action not queued: \(String(describing: type(of: error)), privacy: .public)")
            return .failed(ChatActionFailure(reason: nil, message: Self.couldNotSend))
        }
        if let echo = early.removeValue(forKey: id) { return echo }
        if let failure = knownFailures[id] { return .failed(failure) }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    private func waitForUpload(_ uploadID: String) async -> ChatAttachmentUploadPayload {
        if let echo = earlyUploads.removeValue(forKey: uploadID) { return echo }
        return await withCheckedContinuation { uploadWaiters[uploadID] = $0 }
    }

    private func resolve(_ id: String, _ echo: Echo) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: echo)
        } else {
            early[id] = echo
        }
    }

    /// Puts the owner's text and files back (the attachments already uploaded keep their ids) with the reason.
    private func refuse(_ request: Request, conversation: Int64, message: String, uploaded: [Int64] = []) {
        pending[conversation] = nil
        guard request.mode != .regenerate else {
            drafts.setNotice(message.isEmpty ? Self.couldNotSend : message, conversation: conversation)
            return
        }
        var draft = request.draft ?? ChatDraft(text: request.text)
        let current = drafts.draft(conversation).attachments
        draft.attachments = request.attachments.map { sent in current.first { $0.id == sent.id } ?? sent }
        draft.editing = request.mode == .edit ? request.messageID : nil
        draft.notice = message.isEmpty ? Self.couldNotSend : message
        drafts.restore(draft, conversation: conversation)
    }
}
