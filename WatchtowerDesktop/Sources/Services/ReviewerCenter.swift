import Foundation
import GRDB
import Observation
import os
import WatchtowerCore

/// Branch review's reviewer (board #1025, phase 3): each branch's thread,
/// the engine of the shown one, and **Send to author**. Lives on
/// `WorkbenchesViewModel`, so a turn and a send outlive the pane; the
/// engines live in `EmbeddedChatCenter`.
@MainActor
@Observable
final class ReviewerCenter {
    struct ThreadID: Hashable {
        let projectID: Int64
        let branch: String
    }

    enum ThreadState: Equatable {
        case loading
        case ready(conversationID: Int64)
        case failed(String)
    }

    /// An answer sent into one round: the same answer may go to another
    /// session's round of the branch too (threads are per branch).
    struct SentKey: Hashable {
        let messageID: Int64
        let roundID: Int64
    }

    static let startRoundToSend = "Start a round to send"
    private static let log = Logger(subsystem: Constants.bundleID, category: "review")

    static func sentLine(roundID: Int64) -> String {
        "Sent to the author as a design comment in round \(roundID)"
    }

    private(set) var threads: [ThreadID: ThreadState] = [:]
    /// Answers sent to the author, per round. Kept for this run of the app
    /// only; the comment itself is the record.
    private(set) var sent: Set<SentKey> = []
    private(set) var sending: Set<Int64> = []
    /// A send that failed, by assistant message id.
    private(set) var sendErrors: [Int64: String] = [:]

    @ObservationIgnored let embeddedChats: EmbeddedChatCenter
    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let reader: @MainActor () -> ReviewerSurface.Reader

    init(
        embeddedChats: EmbeddedChatCenter,
        dbPool: DatabasePool,
        reader: @escaping @MainActor () -> ReviewerSurface.Reader = ReviewerCenter.configuredReader
    ) {
        self.embeddedChats = embeddedChats
        self.dbPool = dbPool
        self.reader = reader
    }

    /// How the configured provider reads the folder now (the panel's line).
    func currentReader() -> ReviewerSurface.Reader { reader() }

    /// How the configured provider reads the folder, read when each turn starts.
    static func configuredReader() -> ReviewerSurface.Reader {
        switch AIProvider.fromConfig(ConfigService().aiProvider) {
        case .claude: .claudeTools
        case .codex: .codexSandbox
        case .ollama: .none
        }
    }

    /// The branch's thread, made on first use (the Desktop's write, migration
    /// 00180). Asked again after a failure only (Retry).
    func open(_ id: ThreadID) async {
        switch threads[id] {
        case .loading, .ready: return
        case .failed, nil: break
        }
        threads[id] = .loading
        do {
            let conversationID = try await dbPool.write { db in
                try ReviewerThreadQueries.ensure(db, projectID: id.projectID, branch: id.branch)
            }
            threads[id] = .ready(conversationID: conversationID)
        } catch {
            Self.log.error(
                "reviewer thread open failed (project \(id.projectID, privacy: .public)): \(error.localizedDescription, privacy: .private)"
            )
            threads[id] = .failed("The reviewer's thread could not be opened: \(error.localizedDescription)")
        }
    }

    func engine(
        context: ReviewerSurface.Context,
        conversationID: Int64,
        map: @escaping @MainActor () -> ReviewerMapInput
    ) -> EmbeddedChatEngine {
        embeddedChats.engine(for: ReviewerSurface.spec(context: context, conversationID: conversationID,
                                                       reader: reader, map: map))
    }

    /// Send to author: the answer becomes one design comment in the open
    /// round — the owner's own write through the review's comment path.
    /// Nothing else is written, and nothing reaches the session otherwise.
    func send(messageID: Int64, text: String, to model: ReviewChangesModel) async {
        guard !sending.contains(messageID) else { return }
        guard model.canSendToAuthor, let roundID = model.round?.id else {
            sendErrors[messageID] = Self.startRoundToSend
            return
        }
        let key = SentKey(messageID: messageID, roundID: roundID)
        guard !sent.contains(key) else { return }
        sending.insert(messageID)
        sendErrors[messageID] = nil
        defer { sending.remove(messageID) }
        do {
            try await model.addDesignComment(body: text)
            sent.insert(key)
        } catch {
            Self.log.error("""
                send to author failed (round \(roundID, privacy: .public), message \(messageID, privacy: .public)): \
                \(error.localizedDescription, privacy: .private)
                """)
            sendErrors[messageID] = error.localizedDescription
        }
    }

    /// The answer went into the round the pane shows.
    func wasSent(messageID: Int64, roundID: Int64?) -> Bool {
        guard let roundID else { return false }
        return sent.contains(SentKey(messageID: messageID, roundID: roundID))
    }
}
