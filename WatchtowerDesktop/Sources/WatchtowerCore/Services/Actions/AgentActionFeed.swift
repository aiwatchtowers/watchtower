import Foundation
import GRDB

/// The proposal feed one chat VM composes (the `SkillsCatalog` precedent —
/// one shared piece, composed per VM): observes agent_actions for the bound
/// conversation, and drives Approve/Reject/Retry through the CLI, which is
/// the only status writer (Go owns every transition).
@MainActor
@Observable
package final class AgentActionFeed {
    package private(set) var rows: [AgentAction] = []
    package private(set) var inFlight: Set<Int64> = []
    package var lastError: String?

    private let dbPool: DatabasePool
    private let cliRunner: CLIRunnerProtocol?
    private var observationTask: Task<Void, Never>?
    private var conversationID: Int64?

    package init(dbPool: DatabasePool, cliRunner: CLIRunnerProtocol? = nil) {
        self.dbPool = dbPool
        self.cliRunner = cliRunner
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
    }

    package func stop() {
        observationTask?.cancel()
        observationTask = nil
        conversationID = nil
        rows = []
    }

    package func cards(forTurn turnID: String) -> [AgentAction] {
        rows.filter { $0.turnID == turnID }
    }

    package var pendingCount: Int { rows.filter(\.isPending).count }

    package func approve(_ id: Int64) async { await run("approve", id: id) }
    package func reject(_ id: Int64) async { await run("reject", id: id) }
    package func retry(_ id: Int64) async { await run("apply", id: id) }

    package func approveAllPending(forTurn turnID: String) async {
        for row in cards(forTurn: turnID) where row.isPending {
            await approve(row.id)
        }
    }

    /// Outcomes decided or executed after `after`, rendered for the model.
    /// nil when there is no floor (first turn) or nothing changed.
    package func outcomesBlock(after: Date?) -> String? {
        guard let after, let conversationID else { return nil }
        let floor = Self.timestampString(after)
        let decided = (try? dbPool.read { db in
            try AgentActionQueries.fetchDecidedAfter(db, conversationID: conversationID, after: floor)
        }) ?? []
        return AgentToolsContract.actionsSinceLastTurnBlock(decided)
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

    private func run(_ verb: String, id: Int64) async {
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            lastError = CLIRunnerError.binaryNotFound.localizedDescription
            return
        }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        lastError = nil
        do {
            let data = try await runner.run(args: ["actions", verb, String(id), "--json"])
            if let env = try? JSONDecoder().decode(Envelope.self, from: data),
               let err = env.error, !err.isEmpty {
                lastError = err
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
