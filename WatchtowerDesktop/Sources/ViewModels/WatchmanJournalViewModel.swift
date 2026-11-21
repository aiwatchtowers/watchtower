import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The Inbox's Watchman entry (spec §10): the list of nights and the
/// selected night's journal — Waiting for you, Decided, Checks nobody ran,
/// the gaps the Mac slept through and the night's cost. App-wide on
/// `AppState`. The owner's OK, Correct… and Mark done write only the
/// feedback columns (`WatchmanFeedbackQueries`); Correct… then sends the
/// correction to the session, or starts a new one with it (D26).
@MainActor
@Observable
final class WatchmanJournalViewModel {
    /// One read: the newest nights and the items being decided now.
    struct Snapshot: Equatable, Sendable {
        var nights: [WatchmanNight]
        var deciding: [WatchmanItem]
        /// What the decided items leaned on, by precedent id.
        var precedents: [Int64: String] = [:]
        /// Queued items waiting for their workbench's learning to end, by
        /// workbench id (`WatchmanJournalQueries.waitingForLearningByWorkbench`).
        var waitingForLearning: [Int64: Int] = [:]
    }

    enum Phase: Equatable { case loading, empty, failed, journal }

    /// One row of the night list.
    struct NightRow: Identifiable, Equatable {
        let id: Date
        let title: String
        let line: String
        let live: Bool
        let selected: Bool
    }

    /// A card of Waiting for you or of Decided.
    struct Card: Identifiable, Equatable {
        let id: Int64
        let place: String
        let question: String
        /// The Unsure badge; nil on a waiting card.
        let badge: String?
        let reason: String?
        let choice: String?
        let rationale: String?
        let precedents: [String]
        let meta: String
        let outcome: String?
        let handed: Bool
        /// A stalled session (tuning spec §4b): its own symbol, Open session
        /// and Mark done only.
        var stall = false
        /// OK and Correct… are offered: a twin decision not judged yet.
        var canJudge = false
        /// What the owner said about it: OK'd, or his correction.
        var feedbackLine: String?
        /// Where the correction went, or why it did not.
        var sendLine: String?
        /// The correction is stored but not delivered: Retry is offered.
        var sendFailed = false
        /// Open session is offered: the item has a session.
        var canOpen = false
        /// Mark done is offered (a waiting item the owner can clear).
        var canMarkDone = false
    }

    /// A one-line decision (sure) or a check nobody ran.
    struct Line: Identifiable, Equatable {
        let id: Int64
        let title: String
        let note: String?
        let meta: String
        /// Mark done is offered (a check nobody ran).
        var canMarkDone = false
        /// The line's own symbol; nil = its section's.
        var icon: String?
    }

    /// The symbol of a superseded item's line (its ask was withdrawn), apart
    /// from the owner-answered one.
    static let supersededIcon = "arrow.uturn.backward.circle"
    /// The symbol of a stall card (tuning spec §4b), in `Tone.warning`.
    static let stallIcon = "pause.circle"

    /// The Correct… sheet's draft.
    struct CorrectDraft: Identifiable, Equatable {
        let id: Int64
        let question: String
        let choice: String?
        /// Where the correction goes (`WatchmanJournalCopy.correctNote`).
        let note: String
        var text = ""
        /// The save failed; the sheet stays open with the text.
        var error: String?
        var saving = false

        var canSend: Bool { !saving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        /// Cancel (and Escape) is off while the correction is being saved.
        var canCancel: Bool { !saving }
    }

    /// A correction on its way to a session.
    enum Send: Equatable {
        case sending
        case done(String)
        case failed(String)
    }

    /// What the journal's actions reach beyond its own reads. `write` runs
    /// one feedback write and says whether it wrote; `deliver` types a line
    /// into a session (`SessionLineDelivery`, PROJ-12) and reports a held
    /// line's later tries; `startSession` starts a new session with the
    /// line as its first instruction (the target's start path, never armed)
    /// and returns its id; `open` puts a workbench pane on screen.
    struct Actions {
        var write: @Sendable (WatchmanFeedbackWrite) async throws -> Bool
        var isLive: @MainActor (_ sessionID: Int64) -> Bool
        var deliver: @MainActor (_ line: String, _ itemID: Int64, _ sessionID: Int64,
                                 _ onHeld: @escaping (SessionLineDelivery.HeldEvent) -> Void) async -> SessionLineDelivery.Delivery
        var startSession: @MainActor (_ item: WatchmanItem, _ line: String) async throws -> Int64
        var open: @MainActor (WorkbenchRoute) -> Void

        /// Nothing reachable (the design shots): every write and send fails.
        static var none: Self {
            Self(
                write: { _ in throw WatchmanCorrectionError(reason: "the journal is read-only here") },
                isLive: { _ in false },
                deliver: { _, _, _, _ in .noSession },
                startSession: { _, _ in throw WatchmanCorrectionError(reason: "no terminal is available") },
                open: { _ in }
            )
        }

        /// The writes over the app's database.
        static func write(_ pool: DatabasePool) -> @Sendable (WatchmanFeedbackWrite) async throws -> Bool {
            { change in try await pool.write { try change.apply($0) } }
        }
    }

    /// The selected night as the reading pane draws it.
    struct Page: Equatable {
        let title: String
        let span: String
        let gapLines: [String]
        let cost: String
        let busyLine: String?
        let waiting: [Card]
        let decided: [Card]
        let sureLines: [Line]
        /// Items the owner answered before the twin: lines, never counted.
        let ownerFirst: [Line]
        let decidedCount: Int
        let decidedSummary: String
        let checks: [Line]
    }

    /// How many nights the list reads.
    nonisolated static let nightLimit = 30
    /// The reread while the journal is on screen: the daemon writes from
    /// another process, which a GRDB observation does not see (as Home).
    nonisolated static let tickInterval: Duration = .seconds(30)

    private(set) var phase: Phase = .loading
    private(set) var snapshot = Snapshot(nights: [], deciding: [])
    /// The night the pane shows; nil = the newest.
    var selectedNight: Date?
    /// The workbench the journal is narrowed to; nil = all.
    var scope: Int64?
    /// `watchman status --json`'s `daemon_running`.
    var daemon: WatchmanDaemonState = .unknown
    /// `watchman status --json`'s learning percent of each workbench still
    /// learning (`WatchmanStatus.learningPercents`).
    var learningPercents: [Int64: Int] = [:]
    /// Background AI is paused (`AppState.backgroundAI`): learning does not
    /// run, so the busy line says so instead of a percent.
    var backgroundAIPaused = false
    /// The Correct… sheet; nil = closed.
    var correcting: CorrectDraft?
    /// An OK or Mark done that could not be saved.
    private(set) var actionError: String?
    /// Corrections sent (or not) this run, by item id.
    private(set) var sends: [Int64: Send] = [:]
    /// Sessions a correction started, by item id: Open session opens them.
    private(set) var startedSessions: [Int64: Int64] = [:]
    @ObservationIgnored private let actions: Actions

    @ObservationIgnored private let read: @Sendable () async throws -> Snapshot
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let pool: DatabasePool?
    @ObservationIgnored private let tick: @Sendable (Duration) async -> Void
    /// Bumped by every read: an older reply never overwrites a newer one.
    @ObservationIgnored private var readToken = 0
    /// Corrections stored this run, by item id (Retry's text before the
    /// reread has it).
    @ObservationIgnored private var storedCorrections: [Int64: String] = [:]

    init(
        read: @escaping @Sendable () async throws -> Snapshot,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        pool: DatabasePool? = nil,
        actions: Actions = .none,
        tick: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.read = read
        self.actions = actions
        self.now = now
        self.calendar = calendar
        self.pool = pool
        self.tick = tick
    }

    /// The journal over the app's database; `actions` reach the sessions
    /// (its `write` is replaced by the database's).
    convenience init(pool: DatabasePool, actions: Actions, calendar: Calendar = .current) {
        var actions = actions
        actions.write = Actions.write(pool)
        self.init(read: {
            try await pool.read { db in
                let nights = try WatchmanJournalQueries.nights(db, limit: Self.nightLimit, calendar: calendar)
                let ids = Set(nights.flatMap { $0.items.flatMap(\.precedentIDs) })
                return Snapshot(nights: nights, deciding: try WatchmanJournalQueries.liveDeciding(db),
                                precedents: try WatchmanJournalQueries.precedentTitles(db, ids: ids),
                                waitingForLearning: try WatchmanJournalQueries.waitingForLearningByWorkbench(db))
            }
        }, calendar: calendar, pool: pool, actions: actions)
    }

    // MARK: - Reads

    func load() async {
        readToken += 1
        let token = readToken
        let result: Result<Snapshot, Error>
        do {
            result = .success(try await read())
        } catch {
            result = .failure(error)
        }
        guard token == readToken else { return }
        if case .failure(let error) = result, error is CancellationError { return }
        apply(result)
    }

    /// Takes one read's outcome. A failure while a night is on screen
    /// keeps the night (the next change rereads).
    func apply(_ result: Result<Snapshot, Error>) {
        switch result {
        case .success(let next):
            snapshot = next
            phase = next.nights.isEmpty ? .empty : .journal
        case .failure(let error):
            NSLog("WatchmanJournal: reading the journal: %@", error.localizedDescription)
            if phase != .journal { phase = .failed }
        }
    }

    func retry() async {
        phase = .loading
        await load()
    }

    /// Reads now, again whenever this process changes the journal's tables
    /// and every `tickInterval` (the daemon's writes), until the calling
    /// task ends (the pane's `.task`: the journal left the screen).
    /// `readStatus` rereads `watchman status` at the start and on every
    /// tick, so the daemon line follows a daemon that stops or starts
    /// while the journal is open.
    /// The callback is held by this call only, never by the model (it
    /// captures the app state, which holds the model).
    func watch(readStatus: (() async -> Void)? = nil) async {
        await load()
        await readStatus?()
        let observer = pool.map { pool in Task { await self.observe(pool) } }
        defer { observer?.cancel() }
        await rereadOnTick(readStatus)
    }

    private func rereadOnTick(_ readStatus: (() async -> Void)?) async {
        while !Task.isCancelled {
            await tick(Self.tickInterval)
            guard !Task.isCancelled else { return }
            await load()
            await readStatus?()
        }
    }

    private func observe(_ pool: DatabasePool) async {
        let regions: [any DatabaseRegionConvertible] = WatchmanJournalQueries.observedTables.map { Table($0) }
        let observation = ValueObservation.tracking(regions: regions) { _ in }
        do {
            for try await _ in observation.values(in: pool).dropFirst() {
                guard !Task.isCancelled else { return }
                await load()
            }
        } catch {
            guard !Task.isCancelled else { return }
            NSLog("WatchmanJournal: observing the journal: %@", error.localizedDescription)
        }
    }

    // MARK: - Copy

    var title: String { WatchmanJournalCopy.title }
    var loadingText: String { WatchmanJournalCopy.loading }
    var readFailedText: String { WatchmanJournalCopy.readFailed }
    var retryTitle: String { WatchmanJournalCopy.retry }
    var emptyHint: String { WatchmanJournalCopy.emptyHint }
    var emptyCopy: EmptyStateCopy {
        EmptyStateCopyTable.copy(for: WatchmanJournalCopy.emptyCopyKey, briefingHour: 0)
            ?? EmptyStateCopy(icon: WatchmanStyle.icon, title: "", landsHere: "", feature: nil, primaryAction: nil)
    }

    var daemonLine: String? { daemon == .stopped ? WatchmanJournalCopy.daemonStopped : nil }

    var waitingTitle: String { WatchmanJournalCopy.waitingTitle }
    var decidedTitle: String { WatchmanJournalCopy.decidedTitle }
    var checksTitle: String { WatchmanJournalCopy.checksTitle }
    var choseLabel: String { WatchmanJournalCopy.choseLabel }
    var leanedOn: String { WatchmanJournalCopy.leanedOn }
    var okTitle: String { WatchmanJournalCopy.ok }
    var correctTitle: String { WatchmanJournalCopy.correct }
    var openSessionTitle: String { WatchmanJournalCopy.openSession }
    var markDoneTitle: String { WatchmanJournalCopy.markDone }
    var sheetTitle: String { WatchmanJournalCopy.correctTitle }
    var sheetQuestion: String { WatchmanJournalCopy.correctQuestion }
    var cancelTitle: String { WatchmanJournalCopy.cancel }
    var sendTitle: String { WatchmanJournalCopy.sendCorrection }

    // MARK: - Scope

    var scopeTitle: String {
        scope.flatMap { id in scopeOptions.first { $0.id == id }?.name } ?? WatchmanJournalCopy.scopeAll
    }

    /// Every workbench with an item in the nights read, by name.
    var scopeOptions: [(id: Int64, name: String)] {
        var names: [Int64: String] = [:]
        for item in snapshot.nights.flatMap(\.items) where names[item.workbenchID] == nil {
            names[item.workbenchID] = item.workbenchName.isEmpty ? "#\(item.workbenchID)" : item.workbenchName
        }
        return names.map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    // MARK: - Nights

    /// The nights in scope, newest first.
    var nights: [WatchmanNight] {
        snapshot.nights.map { $0.scoped(to: scope) }.filter { !$0.items.isEmpty }
    }

    var nightRows: [NightRow] {
        let shown = shownNight?.date
        return nights.map { night in
            let live = isLive(night)
            return NightRow(id: night.date, title: nightTitle(night), line: WatchmanJournalCopy.nightListLine(night, live: live),
                            live: live, selected: night.date == shown)
        }
    }

    var page: Page? {
        guard let night = shownNight else { return nil }
        let live = isLive(night)
        let unsure = night.decided.filter(\.unsure)
        let sure = night.decided.filter { !$0.unsure }
        let deciding = snapshot.deciding.filter { scope == nil || $0.workbenchID == scope }
        return Page(
            title: nightTitle(night),
            span: WatchmanJournalCopy.nightSpan(night, live: live, calendar: calendar),
            gapLines: night.gaps.map { WatchmanJournalCopy.gapLine($0, calendar: calendar) },
            cost: WatchmanJournalCopy.cost(night.costUSD, tonight: isTonight(night)),
            // Whatever night is open: something is being decided now, else
            // questions wait for learning.
            busyLine: deciding.first.map { WatchmanJournalCopy.deciding($0.question) } ?? waitingForLearningLine,
            waiting: night.waiting.map(waitingCard),
            decided: unsure.map(decidedCard),
            sureLines: sure.map(sureLine),
            ownerFirst: night.ownerFirst.map(ownerFirstLine),
            decidedCount: night.decided.count,
            decidedSummary: WatchmanJournalCopy.decidedSummary(unsure: unsure.count, sure: sure.count),
            checks: night.checks.map(checkLine)
        )
    }

    // MARK: - Feedback

    /// OK: the twin's decision stands and becomes a precedent (WATCHMAN-03).
    func ok(_ itemID: Int64) async {
        await save(.ok(itemID))
    }

    /// Mark done on a check nobody ran (it was run), or on a waiting item
    /// (the owner dealt with it): either leaves its list.
    func markDone(_ itemID: Int64) async {
        // Every Waiting for you item (parked, handed, a failed handover start)
        // is cleared with owner_done_at; only a check takes check_done_at.
        let waiting = item(itemID).map { $0.isWaitingKind || $0.hasFailedStep } == true
        await save(waiting ? .ownerDone(itemID) : .checkDone(itemID))
    }

    /// Opens the Correct… sheet on a decision.
    func beginCorrect(_ itemID: Int64) {
        guard let item = item(itemID) else { return }
        correcting = CorrectDraft(
            id: itemID, question: WatchmanJournalCopy.question(item), choice: item.choice.isEmpty ? nil : item.choice,
            note: WatchmanJournalCopy.correctNote(item, sessionAlive: item.sessionID > 0 && actions.isLive(item.sessionID)))
    }

    /// Cancel: closes the sheet, never while its correction is being saved.
    func cancelCorrect() {
        guard correcting?.canCancel == true else { return }
        correcting = nil
    }

    /// Send Correction: the owner's words are stored first, so a delivery
    /// that fails keeps them (and offers Retry); then they go to the
    /// session as a typed line, or a new session starts with them. A
    /// decision judged meanwhile keeps the sheet and its text, and says so.
    func sendCorrection() async {
        guard var draft = correcting, draft.canSend, let item = item(draft.id) else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.saving = true
        draft.error = nil
        correcting = draft
        let wrote: Bool
        do {
            wrote = try await actions.write(.correct(item.id, text))
        } catch {
            NSLog("WatchmanJournal: saving the correction of item %lld: %@", item.id, error.localizedDescription)
            keepSheet(draft, error: WatchmanJournalCopy.saveFailed(Self.reason(error)))
            return
        }
        guard wrote else {
            keepSheet(draft, error: WatchmanJournalCopy.alreadyJudged)
            await load()
            return
        }
        if correcting?.id == draft.id { correcting = nil }
        storedCorrections[item.id] = text
        sends[item.id] = .sending
        await load()
        await deliver(item, text: text)
    }

    /// Retry: a stored correction that did not reach a session goes again —
    /// only from Not sent, and once at a time.
    func retrySend(_ itemID: Int64) async {
        guard let item = item(itemID), case .failed? = sendState(item) else { return }
        sends[itemID] = .sending
        await deliver(item, text: storedCorrections[itemID] ?? item.feedbackText)
    }

    /// Open session: the item's session (or the one its correction started)
    /// on its workbench's page; one that stopped is shown, never started.
    /// A session whose row is gone is never opened (its id would land on
    /// another session).
    func openSession(_ itemID: Int64) {
        guard let item = item(itemID) else { return }
        let sessionID = startedSessions[itemID] ?? (item.sessionExists ? item.sessionID : 0)
        guard sessionID > 0 else { return }
        actions.open(WorkbenchRoute(projectID: item.workbenchID, pane: .terminal, subjectID: sessionID))
    }

    private func keepSheet(_ draft: CorrectDraft, error: String) {
        var draft = draft
        draft.saving = false
        draft.error = error
        if correcting?.id == draft.id { correcting = draft }
    }

    private func save(_ change: WatchmanFeedbackWrite) async {
        actionError = nil
        do {
            _ = try await actions.write(change)
        } catch {
            NSLog("WatchmanJournal: saving feedback: %@", error.localizedDescription)
            actionError = WatchmanJournalCopy.saveFailed(Self.reason(error))
            return
        }
        await load()
    }

    /// Sends the stored correction; the caller has set `.sending`.
    private func deliver(_ item: WatchmanItem, text: String) async {
        let line = WatchmanJournalCopy.correctionLine(item, text: text)
        if item.sessionID > 0 {
            let delivery = await actions.deliver(line, item.id, item.sessionID) { [weak self] event in
                self?.heldLineTried(event, item: item)
            }
            if let sent = Self.sentText(delivery, sessionID: item.sessionID) {
                sends[item.id] = .done(sent)
                if Self.reachedSession(delivery) { await markSent(item.id) }
                return
            }
        }
        // No live session (or it ended meanwhile): a new one, in the owner's name.
        do {
            let started = try await actions.startSession(item, line)
            startedSessions[item.id] = started
            sends[item.id] = .done(WatchmanJournalCopy.startedSession(started))
            await markSent(item.id)
        } catch {
            NSLog("WatchmanJournal: starting a session for the correction of item %lld: %@", item.id,
                  error.localizedDescription)
            sends[item.id] = .failed(WatchmanJournalCopy.notSent(Self.reason(error)))
        }
    }

    /// The correction reached a session: stored, so a relaunch does not
    /// call it Not sent. A failed write is logged; this run still shows
    /// where it went.
    private func markSent(_ itemID: Int64) async {
        do {
            _ = try await actions.write(.correctionSent(itemID))
        } catch {
            NSLog("WatchmanJournal: storing that the correction of item %lld was sent: %@", itemID,
                  error.localizedDescription)
        }
    }

    /// A held correction was tried again.
    private func heldLineTried(_ event: SessionLineDelivery.HeldEvent, item: WatchmanItem) {
        guard case let .tried(delivery) = event else { return }
        if let sent = Self.sentText(delivery, sessionID: item.sessionID) {
            sends[item.id] = .done(sent)
            if Self.reachedSession(delivery) { Task { await markSent(item.id) } }
        } else {
            sends[item.id] = .failed(WatchmanJournalCopy.notSent(WatchmanJournalCopy.sessionStopped))
        }
    }

    /// This run's send state, else Not sent for a correction stored but never
    /// delivered (the app quit first).
    private func sendState(_ item: WatchmanItem) -> Send? {
        if let send = sends[item.id] { return send }
        return item.correctionUnsent ? .failed(WatchmanJournalCopy.notSent(WatchmanJournalCopy.appQuit)) : nil
    }

    /// The line is in the session's prompt (submitted, or typed for the
    /// owner's Return). On the clipboard only, held or queued it is not: a
    /// relaunch still offers Retry.
    private static func reachedSession(_ delivery: SessionLineDelivery.Delivery) -> Bool {
        delivery == .submitted || delivery == .typed
    }

    /// Where a delivered line went; nil = no session took it.
    private static func sentText(_ delivery: SessionLineDelivery.Delivery, sessionID: Int64) -> String? {
        switch delivery {
        case .submitted: WatchmanJournalCopy.sentToSession(sessionID)
        case .typed: WatchmanJournalCopy.typedIntoSession(sessionID)
        case .copied: WatchmanJournalCopy.copiedForSession(sessionID)
        case .held, .queued: WatchmanJournalCopy.heldForSession(sessionID)
        case .noSession: nil
        }
    }

    // MARK: - Why a new session did not start (`Not sent — <reason>`)

    nonisolated static let workbenchesNotLoaded = "the workbenches are not loaded yet"

    nonisolated static func startFailure(_ error: WorkbenchesViewModel.TargetStartError, targetID: Int64) -> String {
        switch error {
        case .notOnBoard: "target #\(targetID) is not on a workbench board"
        case .inProgress: "a session on target #\(targetID) is starting right now"
        case let .failed(message): message
        case let .agentNotFound(agent): "\(agent.displayName) was not found on this Mac"
        case let .unsupportedAgent(kind): "this version cannot start a \(kind) session"
        case .cleaningUp: "the session is being deleted"
        }
    }

    private static func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// An item of the nights read, or one being decided.
    private func item(_ id: Int64) -> WatchmanItem? {
        snapshot.nights.lazy.flatMap(\.items).first { $0.id == id } ?? snapshot.deciding.first { $0.id == id }
    }

    // MARK: - Private

    private var shownNight: WatchmanNight? {
        let nights = nights
        return nights.first { $0.date == selectedNight } ?? nights.first
    }

    /// "Waiting for learning (42%): 3 questions" over the workbenches in
    /// scope, at the least learned one's percent among those a status read
    /// gave (an unknown percent is unknown, not 0; none known: no percent);
    /// the paused line while background AI is paused; nil while nothing
    /// waits.
    private var waitingForLearningLine: String? {
        let waiting = snapshot.waitingForLearning.filter { scope == nil || $0.key == scope }
        let count = waiting.values.reduce(0, +)
        guard count > 0 else { return nil }
        if backgroundAIPaused { return WatchmanJournalCopy.waitingForLearningPaused }
        let percent = waiting.keys.compactMap { learningPercents[$0] }.min()
        return WatchmanJournalCopy.waitingForLearning(percent: percent, count: count)
    }

    private func isTonight(_ night: WatchmanNight) -> Bool {
        night.date == WatchmanNight.start(of: now(), calendar: calendar)
    }

    /// Tonight with an item still queued or being decided.
    private func isLive(_ night: WatchmanNight) -> Bool {
        isTonight(night) && !night.pending.isEmpty
    }

    private func nightTitle(_ night: WatchmanNight) -> String {
        WatchmanJournalCopy.nightTitle(night.date, now: now(), calendar: calendar)
    }

    private func sureLine(_ item: WatchmanItem) -> Line {
        Line(id: item.id, title: WatchmanJournalCopy.question(item), note: nil, meta: WatchmanJournalCopy.meta(item))
    }

    private func ownerFirstLine(_ item: WatchmanItem) -> Line {
        Line(id: item.id, title: WatchmanJournalCopy.question(item), note: WatchmanJournalCopy.outcome(item),
             meta: WatchmanJournalCopy.place(item, calendar: calendar),
             icon: item.outcome == "superseded" ? Self.supersededIcon : nil)
    }

    private func checkLine(_ item: WatchmanItem) -> Line {
        Line(id: item.id, title: WatchmanJournalCopy.question(item), note: WatchmanJournalCopy.checkLine,
             meta: WatchmanJournalCopy.place(item, calendar: calendar), canMarkDone: true)
    }

    private func waitingCard(_ item: WatchmanItem) -> Card {
        if item.isStall { return stallCard(item) }
        return Card(id: item.id, place: WatchmanJournalCopy.place(item, calendar: calendar),
                    question: WatchmanJournalCopy.question(item), badge: nil,
                    reason: WatchmanJournalCopy.waitingReason(item), choice: nil, rationale: nil, precedents: [],
                    meta: WatchmanJournalCopy.meta(item), outcome: nil, handed: item.outcome == "handed",
                    canOpen: item.sessionID > 0 && item.sessionExists, canMarkDone: true)
    }

    /// A stalled session: titled by the session, the stored reason, Open
    /// session while its row is there and Mark done (it is not a decision:
    /// no OK, no Correct…).
    private func stallCard(_ item: WatchmanItem) -> Card {
        // The waiting card draws `place` as its meta line; `meta` is the
        // decided card's.
        Card(id: item.id, place: WatchmanJournalCopy.stallMeta(item, calendar: calendar),
             question: WatchmanJournalCopy.stallTitle(item), badge: nil,
             reason: WatchmanJournalCopy.stallReason(item), choice: nil, rationale: nil, precedents: [],
             meta: "", outcome: nil, handed: false, stall: true,
             canOpen: item.sessionID > 0 && item.sessionExists, canMarkDone: true)
    }

    private func decidedCard(_ item: WatchmanItem) -> Card {
        Card(id: item.id, place: WatchmanJournalCopy.place(item, calendar: calendar),
             question: WatchmanJournalCopy.question(item), badge: WatchmanJournalCopy.unsureBadge, reason: nil,
             choice: item.choice.isEmpty ? nil : item.choice,
             rationale: item.rationale.isEmpty ? nil : item.rationale,
             precedents: item.precedentIDs.compactMap { snapshot.precedents[$0] },
             meta: WatchmanJournalCopy.meta(item), outcome: WatchmanJournalCopy.outcome(item), handed: false,
             canJudge: item.feedback.isEmpty, feedbackLine: feedbackLine(item), sendLine: sendLine(item),
             sendFailed: sendState(item).map { if case .failed = $0 { true } else { false } } ?? false,
             canOpen: item.sessionID > 0 || startedSessions[item.id] != nil)
    }

    private func feedbackLine(_ item: WatchmanItem) -> String? {
        switch item.feedback {
        case "ok": WatchmanJournalCopy.okGiven
        case "corrected": WatchmanJournalCopy.corrected(item.feedbackText)
        default: nil
        }
    }

    private func sendLine(_ item: WatchmanItem) -> String? {
        switch sendState(item) {
        case .sending?: WatchmanJournalCopy.sending
        case let .done(text)?, let .failed(text)?: text
        case nil: nil
        }
    }
}

/// Why a correction could not be sent, in words for `Not sent — <reason>`.
struct WatchmanCorrectionError: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}
