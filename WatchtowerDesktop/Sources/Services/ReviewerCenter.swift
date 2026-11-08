import Foundation
import GRDB
import Observation
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

    static let startRoundToSend = "Start a round to send"

    static func sentLine(roundID: Int64) -> String {
        "Sent to the author as a design comment in round \(roundID)"
    }

    private(set) var threads: [ThreadID: ThreadState] = [:]
    /// Answers sent to the author, by assistant message id: the round each
    /// went to. Kept for this run of the app only; the comment itself is the record.
    private(set) var sent: [Int64: Int64] = [:]
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

    /// How the configured provider reads the folder, read when each turn starts.
    static func configuredReader() -> ReviewerSurface.Reader {
        switch AIProvider.fromConfig(ConfigService().aiProvider) {
        case .claude: .claudeTools
        case .codex: .codexSandbox
        case .ollama: .none
        }
    }

    /// Where the reviewer of a session's round works; nil until the thread
    /// key is known (no round yet, or the folder's branch not read yet).
    static func context(
        projectID: Int64,
        sessionID: Int64,
        round: ReviewRoundInfo?,
        place: SessionPlace,
        mainStatus: WorkbenchGitStatus?
    ) -> ReviewerSurface.Context? {
        guard let round, !round.folderRoot.isEmpty else { return nil }
        let status = ReviewIdentityPresentation.status(place: place, mainStatus: mainStatus)
        guard let branch = ReviewerSurface.threadBranch(round: round, folderStatus: status, sessionID: sessionID) else {
            return nil
        }
        let label = branch.hasPrefix("session:") ? "" : branch
        var inWorktree = false
        if case .worktree = place { inWorktree = true }
        return ReviewerSurface.Context(projectID: projectID, branch: branch, branchLabel: label,
                                       readFolder: round.folderRoot, inWorktree: inWorktree)
    }

    /// The branch's thread, made on first use (the Desktop's write, migration
    /// 00175). Asked again after a failure only (Retry).
    func open(_ id: ThreadID) async {
        if let state = threads[id], !Self.isFailed(state) { return }
        threads[id] = .loading
        do {
            let conversationID = try await dbPool.write { db in
                try ReviewerThreadQueries.ensure(db, projectID: id.projectID, branch: id.branch)
            }
            threads[id] = .ready(conversationID: conversationID)
        } catch {
            threads[id] = .failed("The reviewer's thread could not be opened: \(error.localizedDescription)")
        }
    }

    private static func isFailed(_ state: ThreadState) -> Bool {
        if case .failed = state { return true }
        return false
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
        guard sent[messageID] == nil, !sending.contains(messageID) else { return }
        guard model.canSendToAuthor, let roundID = model.round?.id else {
            sendErrors[messageID] = Self.startRoundToSend
            return
        }
        sending.insert(messageID)
        sendErrors[messageID] = nil
        defer { sending.remove(messageID) }
        do {
            try await model.addDesignComment(body: text)
            sent[messageID] = roundID
        } catch {
            sendErrors[messageID] = error.localizedDescription
        }
    }
}
