import AppKit
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The owner asks of the workbench on screen (spec 2026-10-03 Parts 5 and 8).
/// Owned by `WorkbenchesViewModel` (AppState), so the drafts, a pending
/// answer and its notice survive navigation (house rule).
///
/// The agent writes asks from another process (`watchtower mcp --workbench`),
/// which ValueObservation cannot see, so the board's pattern applies: a cheap
/// fingerprint read every 5 s while the Workbench tab is on screen, and on
/// app activation; the asks reload only when it moved.
@MainActor
@Observable
final class OwnerAsksViewModel {
    /// What the last answer to an ask came to, shown beside it.
    enum Notice: Equatable {
        /// Written; the line went as `sendPrompt` says. An ask without a
        /// session counts as `.noSession`.
        case delivered(TerminalCenter.PromptDelivery)
        /// Not written: the ask was no longer open (withdrawn, superseded).
        case withdrawn

        var text: String {
            switch self {
            case .delivered(.sent): OwnerAsksViewModel.sentNote
            case .delivered(.copied): WorkbenchCommentsSendBar.copiedNote
            case .delivered(.noSession): OwnerAsksViewModel.noSessionNote
            case .withdrawn: OwnerAsksViewModel.withdrawnNote
            }
        }
    }

    static let sentNote = "Pasted into Claude — press Return to send"
    static let noSessionNote = "Answer saved — it goes to the session's brief when it starts"
    static let withdrawnNote = "The agent withdrew this ask — your draft is kept"
    static let pollInterval: Duration = .seconds(5)

    /// Never written to the DB; answering is what persists a draft.
    let drafts = OwnerAskDrafts()
    /// Each workbench's open asks, oldest first, as last read.
    private(set) var openAsks: [Int64: [OwnerAsk]] = [:]
    /// The last answer's outcome per ask id, until dismissed.
    private(set) var notices: [Int64: Notice] = [:]
    /// Why the last read or answer of a workbench failed; the next success clears it.
    private(set) var errors: [Int64: String] = [:]
    /// Asks an answer is being written for: Answer is disabled meanwhile,
    /// and a second click writes nothing.
    private(set) var answering: Set<Int64> = []
    /// The ask each workbench's drawer shows (nil = closed). An answer that
    /// typed or copied its line closes it: the terminal takes over.
    private(set) var drawerAskIDs: [Int64: Int64] = [:]

    /// Whether the Workbench tab is what the owner sees; the poll reads only then.
    @ObservationIgnored var isTabOnScreen: () -> Bool = { false }
    /// The workbench on screen, whose asks the poll follows.
    @ObservationIgnored var watchedProjectID: () -> Int64? = { nil }
    /// An answer's line was typed or copied into `sessionID`: the page shows
    /// that terminal and moves the keyboard into it.
    @ObservationIgnored var onDelivered: ((_ projectID: Int64, _ sessionID: Int64) -> Void)?
    /// Seams for tests: the poll's wait and the activation notifications.
    @ObservationIgnored var pollSleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored var notificationCenter: NotificationCenter = .default

    private let dbPool: DatabasePool
    private let terminalCenter: TerminalCenter?
    @ObservationIgnored private var fingerprints: [Int64: String] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(dbPool: DatabasePool, terminalCenter: TerminalCenter?) {
        self.dbPool = dbPool
        self.terminalCenter = terminalCenter
    }

    func stack(projectID: Int64) -> OwnerAskStack {
        OwnerAskStack(openAsks[projectID] ?? [])
    }

    // MARK: - Loading

    func load(projectID: Int64) async {
        do {
            let (asks, stamp) = try await dbPool.read { db in
                (try OwnerAskQueries.openAsks(db, projectID: projectID), try Self.fingerprint(db, projectID: projectID))
            }
            openAsks[projectID] = asks
            fingerprints[projectID] = stamp
            errors[projectID] = nil
        } catch {
            // The last list stays beside the error.
            errors[projectID] = "Could not load the asks: \(error.localizedDescription)"
        }
    }

    /// Reloads a workbench's asks when anything about them changed since the
    /// last read — a workbench never read counts as changed. Returns whether
    /// it reloaded.
    @discardableResult
    func refreshIfChanged(projectID: Int64) async -> Bool {
        let current = try? await dbPool.read { try Self.fingerprint($0, projectID: projectID) }
        guard let current, current != fingerprints[projectID] else { return false }
        await load(projectID: projectID)
        return true
    }

    /// The 5 s poll and app activation, for the whole app run (AppState).
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollSleep(Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.pollTick()
            }
        }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.watchedProjectID() else { return }
                Task { await self.refreshIfChanged(projectID: id) }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// One poll tick: the watched workbench, only while the tab is on screen.
    func pollTick() async {
        guard isTabOnScreen(), let id = watchedProjectID() else { return }
        await refreshIfChanged(projectID: id)
    }

    /// Counts plus the latest stamps of a workbench's asks. Go files and
    /// withdraws asks and marks them delivered in place: the open count, the
    /// max id or a stamp moves with every such write.
    nonisolated private static func fingerprint(_ db: Database, projectID: Int64) throws -> String {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*), MAX(id), SUM(CASE WHEN status = 'open' THEN 1 ELSE 0 END),
                       MAX(answered_at), MAX(delivered_at)
                FROM owner_asks WHERE project_id = ?
                """,
            arguments: [projectID]
        )
        return row?.description ?? ""
    }

    // MARK: - Drawer

    func openDrawer(askID: Int64, projectID: Int64) {
        drawerAskIDs[projectID] = askID
    }

    func closeDrawer(projectID: Int64) {
        drawerAskIDs[projectID] = nil
    }

    func dismissNotice(askID: Int64) {
        notices[askID] = nil
    }

    // MARK: - Answering

    /// Answers `ask` from its draft (spec 2026-10-03 Part 5, PROJ-12): one
    /// guarded write, and only then exactly one `sendPrompt` of the
    /// `OwnerAskPrompt` line to the ask's session — pasted, never submitted.
    /// An ask without a session, or one not running, gets nothing typed: the
    /// brief delivers it. An ask the agent withdrew meanwhile writes nothing
    /// and keeps the draft. Returns the delivery, nil when nothing was written
    /// (an incomplete draft, an answer already running, a failure).
    @discardableResult
    func answer(_ ask: OwnerAsk) async -> TerminalCenter.PromptDelivery? {
        let draft = drafts.draft(for: ask.id)
        guard !answering.contains(ask.id), draft.isAnswerable(for: ask) else { return nil }
        answering.insert(ask.id)
        defer { answering.remove(ask.id) }
        let answer = draft.answer(for: ask)
        let (askID, projectID) = (ask.id, ask.projectID)
        do {
            try await dbPool.write { db in
                try OwnerAskQueries.answer(db, askID: askID, projectID: projectID, with: answer)
            }
        } catch AskAnswerError.notOpen {
            notices[askID] = .withdrawn
            await load(projectID: projectID)
            return nil
        } catch {
            errors[projectID] = "Could not save the answer: \(error.localizedDescription)"
            return nil
        }
        errors[projectID] = nil
        drafts.discard(askID)
        let line = OwnerAskPrompt.line(id: askID, kind: ask.kind, answer: answer)
        let delivery = ask.sessionID.flatMap { terminalCenter?.sendPrompt(line, sessionID: $0) } ?? .noSession
        notices[askID] = .delivered(delivery)
        if delivery != .noSession, let sessionID = ask.sessionID {
            if drawerAskIDs[projectID] == askID { drawerAskIDs[projectID] = nil }
            onDelivered?(projectID, sessionID)
        }
        await load(projectID: projectID)
        return delivery
    }
}
