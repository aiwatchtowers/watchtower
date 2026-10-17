import CryptoKit
import Foundation
import GRDB
import os

/// The proposal feed one chat VM composes (the `SkillsCatalog` precedent —
/// one shared piece, composed per VM): observes agent_actions for the bound
/// conversation, and drives Approve/Reject/Retry through the CLI, which is
/// the only status writer (Go owns every transition).
///
/// Every row this feed shows is written by a `watchtower` SUBPROCESS — the
/// chat-mode MCP server inserts proposals mid-turn, `watchtower actions …`
/// transitions them. GRDB `ValueObservation` fires only on the app's own
/// writer connection, so the observation alone would never see any of it
/// (`DigestViewModel`, `IdeasViewModel`, `CatchUpViewModel`,
/// `TargetWatchesViewModel.refreshEvents` all hit the same wall). Three
/// readers close the gap: `refresh()` after every CLI call, a safety-net
/// poll while started, and the chat VMs' stream-end hook. The observation
/// stays for same-process writes.
@MainActor
@Observable
package final class AgentActionFeed {
    package private(set) var rows: [AgentAction] = []
    package private(set) var inFlight: Set<Int64> = []
    /// Why the last Approve/Reject/Retry on a row failed, keyed by row id —
    /// rendered on that row's card, so a failure shows where the owner
    /// clicked (an SQLITE_BUSY approve leaves the row `pending`, with nothing
    /// on the row itself to say it failed). Cleared when the row's next CLI
    /// call starts.
    package private(set) var rowErrors: [Int64: RowError] = [:]
    /// Failures that belong to no single row: the observation, a refresh, the
    /// outcomes read.
    package var lastError: String?
    /// Runs after every Approve/Reject/Retry with the row as re-read from
    /// disk (nil when it is gone) — the automation editor refreshes the
    /// Automations list once a `save_automation` lands.
    @ObservationIgnored package var onDecision: ((Int64, AgentAction?) -> Void)?

    private let dbPool: DatabasePool
    private let cliRunner: CLIRunnerProtocol?
    /// `watchtower automations wake` (spec §7.4): sent after a decision on a
    /// row an automation run proposed, so the run waiting on it resumes now
    /// rather than on the executor's next poll. Nil = never wake.
    private let automationsWake: (() async throws -> Void)?
    /// Safety-net poll cadence, at `IdeasViewModel.pollInterval`'s 30 s: the
    /// turn-boundary refresh is what makes proposals feel immediate, this only
    /// has to catch a turn that never reaches its end. Injectable for tests.
    private let pollInterval: Duration
    private var observationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var conversationID: Int64?

    /// The verb is kept so the card retries what actually failed: a failed
    /// Reject must never turn into a button that approves.
    package struct RowError: Equatable, Sendable {
        package let verb: String
        package let message: String

        package var isApprove: Bool { verb == "approve" }

        package init(verb: String, message: String) {
            self.verb = verb
            self.message = message
        }
    }

    package init(
        dbPool: DatabasePool,
        cliRunner: CLIRunnerProtocol? = nil,
        automationsWake: (() async throws -> Void)? = nil,
        pollInterval: Duration = .seconds(30)
    ) {
        self.dbPool = dbPool
        self.cliRunner = cliRunner
        self.automationsWake = automationsWake
        self.pollInterval = pollInterval
    }

    package func start(conversationID: Int64) {
        stop()
        self.conversationID = conversationID
        let pool = dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try AgentActionQueries.fetchByConversation(db, conversationID: conversationID)
            }
            do {
                for try await rows in observation.values(in: pool) {
                    guard !Task.isCancelled, let self else { break }
                    self.rows = rows
                }
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                self?.refresh()
            }
        }
    }

    package func stop() {
        observationTask?.cancel()
        observationTask = nil
        pollTask?.cancel()
        pollTask = nil
        conversationID = nil
        rows = []
        rowErrors = [:]
    }

    /// One-shot refetch from disk. The only thing that can surface a row a
    /// subprocess wrote: called after every CLI call, on the poll, and by the
    /// chat VMs when a streamed turn ends.
    ///
    /// A read failure keeps the rows it already has — stale cards beat empty
    /// ones — but says so: silently swallowing it leaves the owner looking at
    /// a proposal list that stopped tracking reality with no sign of it.
    package func refresh() {
        guard let conversationID else { return }
        do {
            rows = try dbPool.read { db in
                try AgentActionQueries.fetchByConversation(db, conversationID: conversationID)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    package func cards(forTurn turnID: String) -> [AgentAction] {
        rows.filter { $0.turnID == turnID }
    }

    package var pendingCount: Int { rows.filter(\.isPending).count }

    /// Proposals whose turn has no message to hang a card under — a stream that
    /// failed before any assistant text persisted leaves exactly this. Terminal
    /// rows are dropped: they need no decision, so surfacing them would only be
    /// noise. Static and pure so the two chat lists share one rule.
    package static func unattached(rows: [AgentAction], messageTurnIDs: Set<String>) -> [AgentAction] {
        rows.filter { !messageTurnIDs.contains($0.turnID) && !$0.isTerminal }
    }

    /// `shownArgs` is the row's `args_json` exactly as the card rendered it:
    /// its digest rides `--args-sha256`, and Go refuses the approve when the
    /// stored args are no longer what the owner saw. `patch` carries the
    /// owner's card edits (`actions approve --patch`, e.g. a Slack message's
    /// text); Go merges and approves them in one write.
    package func approve(_ id: Int64, shownArgs: String, patch: String? = nil) async {
        let pin = ["--args-sha256", Self.argsSHA256(shownArgs)]
        await run("approve", id: id, extra: pin + (patch.map { ["--patch", $0] } ?? []))
    }

    /// Hex sha256 of the args text's UTF-8 bytes — Go `tools.ArgsSHA256` over
    /// the stored `args_json`.
    package static func argsSHA256(_ argsJSON: String) -> String {
        SHA256.hash(data: Data(argsJSON.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    package func reject(_ id: Int64) async {
        await run("reject", id: id)
    }

    /// Re-runs `apply` for a `failed`/`approved` row.
    package func retry(_ id: Int64) async {
        await run("apply", id: id)
    }

    /// The rows "Approve all" covers. A session-applied call is left to its
    /// own card, which offers Approve only while its chat session holds it
    /// and the call is readable.
    package func bulkApprovable(forTurn turnID: String) -> [AgentAction] {
        cards(forTurn: turnID).filter { $0.isPending && !$0.isSessionApplied }
    }

    /// One owner gesture over several rows: each row keeps its own error, so a
    /// failure on row 1 still shows on its card after row 2 succeeds.
    package func approveAllPending(forTurn turnID: String) async {
        for row in bulkApprovable(forTurn: turnID) {
            await approve(row.id, shownArgs: row.argsJSON)
        }
    }

    /// Outcomes decided or executed after `after`, rendered for the model.
    /// nil when there is no floor (first turn) or nothing changed.
    ///
    /// A read failure returns nil AND records the error rather than passing an
    /// empty list off as "nothing was decided" — telling the model no decision
    /// landed on a proposal the owner did approve is worse than saying nothing.
    package func outcomesBlock(after: Date?) -> String? {
        guard let after, let conversationID else { return nil }
        let floor = Self.timestampString(after)
        do {
            let decided = try dbPool.read { db in
                try AgentActionQueries.fetchDecidedAfter(db, conversationID: conversationID, after: floor)
            }
            return AgentToolsContract.actionsSinceLastTurnBlock(decided)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    package static func timestampString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return fmt.string(from: date)
    }

    /// Only `error` is read: it surfaces regardless of `ok`/`applied_ok`, so
    /// an approve/apply that exits 0 but failed to execute still reports.
    private struct Envelope: Decodable {
        let error: String?
    }

    /// Clears only this row's error: another row's failure stays on its card.
    /// `lastError` is reset too — the `refresh()` below re-reports a read that
    /// still fails.
    private func run(_ verb: String, id: Int64, extra: [String] = []) async {
        rowErrors[id] = nil
        lastError = nil
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            rowErrors[id] = RowError(verb: verb, message: CLIRunnerError.binaryNotFound.localizedDescription)
            return
        }
        inFlight.insert(id)
        var completed = false
        do {
            let data = try await runner.run(args: ["actions", verb, String(id)] + extra + ["--json"])
            completed = true
            if let env = try? JSONDecoder().decode(Envelope.self, from: data),
               let err = env.error, !err.isEmpty {
                rowErrors[id] = RowError(verb: verb, message: err)
            }
        } catch {
            rowErrors[id] = RowError(verb: verb, message: error.localizedDescription)
        }
        inFlight.remove(id)
        // The CLI wrote on its own connection; the observation will never fire
        // for it (TargetWatchesViewModel.refreshEvents precedent).
        refresh()
        onDecision?(id, rows.first { $0.id == id })
        if completed { await wakeIfAutomationRun(id) }
    }

    /// Wakes on any call the CLI completed, an envelope error included: an
    /// approve whose apply failed still moved the row, and a spurious wake
    /// only costs the executor one early poll. The row is read from disk —
    /// the strip's feed has no conversation, so `rows` never holds it. A
    /// failed read or wake is logged and never reported as the decision
    /// failing: the decision landed, the run resumes on its next poll anyway.
    private func wakeIfAutomationRun(_ id: Int64) async {
        guard let automationsWake else { return }
        do {
            let contextType = try await dbPool.read { db in try AgentActionQueries.contextType(db, id: id) }
            guard contextType == Self.automationRunContext else { return }
            try await automationsWake()
        } catch {
            Self.log.error("automations wake after deciding action \(id) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated package static let automationRunContext = "automation_run"
    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "agent-actions")
}
