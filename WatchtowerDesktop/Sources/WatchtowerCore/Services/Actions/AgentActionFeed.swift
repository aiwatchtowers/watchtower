import Foundation
import GRDB

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
    package var lastError: String?

    private let dbPool: DatabasePool
    private let cliRunner: CLIRunnerProtocol?
    /// Safety-net poll cadence, at `IdeasViewModel.pollInterval`'s 30 s: the
    /// turn-boundary refresh is what makes proposals feel immediate, this only
    /// has to catch a turn that never reaches its end. Injectable for tests.
    private let pollInterval: Duration
    private var observationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var conversationID: Int64?

    package init(dbPool: DatabasePool, cliRunner: CLIRunnerProtocol? = nil, pollInterval: Duration = .seconds(30)) {
        self.dbPool = dbPool
        self.cliRunner = cliRunner
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

    package func approve(_ id: Int64) async {
        lastError = nil
        await run("approve", id: id)
    }

    package func reject(_ id: Int64) async {
        lastError = nil
        await run("reject", id: id)
    }

    package func retry(_ id: Int64) async {
        lastError = nil
        await run("apply", id: id)
    }

    /// One owner gesture over several rows: the error is cleared once, up
    /// front, so a failure on row 1 still shows after row 2 succeeds.
    package func approveAllPending(forTurn turnID: String) async {
        lastError = nil
        for row in cards(forTurn: turnID) where row.isPending {
            await run("approve", id: row.id)
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

    /// Never clears `lastError` — its callers own that, so one gesture over
    /// several rows accumulates rather than erasing its own failures.
    private func run(_ verb: String, id: Int64) async {
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            lastError = CLIRunnerError.binaryNotFound.localizedDescription
            return
        }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        do {
            let data = try await runner.run(args: ["actions", verb, String(id), "--json"])
            if let env = try? JSONDecoder().decode(Envelope.self, from: data),
               let err = env.error, !err.isEmpty {
                lastError = err
            }
        } catch {
            lastError = error.localizedDescription
        }
        // The CLI wrote on its own connection; the observation will never fire
        // for it (TargetWatchesViewModel.refreshEvents precedent).
        refresh()
    }
}
