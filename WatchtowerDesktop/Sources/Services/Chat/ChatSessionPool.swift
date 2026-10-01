import Foundation
import GRDB
import WatchtowerCore

/// App-wide owner of warm chat sessions (spec §1.4) — on `AppState`, so it
/// survives navigation (the center house pattern). All decisions come from
/// `ChatSessionPolicy`; this type only applies them. CHAT-03.
///
/// Admission: a requested session is created *pending* and queued (FIFO).
/// It launches only when the policy grants a slot AND every process that
/// slot displaces has exited — so the bound holds for real processes and a
/// config-change replacement never overlaps (or races `session_id` writes
/// with) the process it replaces. A busy session is never evicted: with
/// three turns in flight the fourth conversation waits, its turn held, until
/// a turn finishes. Admission re-runs on every retirement completing, turn
/// finishing, process ending and policy tick.
@MainActor
@Observable
final class ChatSessionPool {
    typealias ProcessFactory = @MainActor ([String]) throws -> any ChatSessionProcess

    /// Every session this pool owns, launched or pending.
    private(set) var clients: [Int64: ChatSessionClient] = [:]
    /// The config of the most recent `session(for:config:)` request.
    @ObservationIgnored private(set) var lastConfig: ChatSessionConfig?
    /// One subscriber: the main `ChatViewModel` (reload, feed refresh, titles).
    @ObservationIgnored var onTurnFinished: ((Int64) -> Void)?

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let processFactory: ProcessFactory
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let closeGrace: Duration
    @ObservationIgnored private let killAfter: Duration
    @ObservationIgnored private var policyTask: Task<Void, Never>?
    /// Pending conversation ids, oldest request first.
    @ObservationIgnored private var queue: [Int64] = []
    /// Processes told to close that have not exited yet; each still holds a slot.
    @ObservationIgnored private var retirements: [Int: (conversationID: Int64, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var nextRetirementKey = 0

    init(
        dbPool: DatabasePool,
        processFactory: @escaping ProcessFactory = { try FoundationChatSessionProcess.launch(arguments: $0) },
        clock: @escaping () -> Date = Date.init,
        closeGrace: Duration = .seconds(2),
        killAfter: Duration = ChatSessionClient.defaultKillAfter
    ) {
        self.dbPool = dbPool
        self.processFactory = processFactory
        self.clock = clock
        self.closeGrace = closeGrace
        self.killAfter = killAfter
    }

    func client(for conversationID: Int64?) -> ChatSessionClient? {
        conversationID.flatMap { clients[$0] }
    }

    /// The session for this conversation — reused when compatible and alive,
    /// otherwise a new one (pending until admitted). Never throws: a spawn
    /// failure yields a dead client whose next turn fails visibly with
    /// `provider_unavailable`.
    func session(for conversationID: Int64, config: ChatSessionConfig) -> ChatSessionClient {
        lastConfig = config
        if let existing = clients[conversationID], existing.isAlive, existing.config.isCompatible(with: config) {
            existing.touch()
            return existing
        }
        if let stale = clients.removeValue(forKey: conversationID) { retire(stale) }
        let arguments = ChatSessionClient.arguments(for: config, dbPath: dbPool.path)
        let factory = processFactory
        let client = ChatSessionClient(config: config, spawn: { try factory(arguments) },
                                       store: ChatTurnStore(dbPool: dbPool), clock: clock, launchImmediately: false)
        client.onTurnFinished = { [weak self] id in
            self?.onTurnFinished?(id)
            self?.admit()
        }
        client.onEnded = { [weak self] in self?.admit() }
        clients[conversationID] = client
        queue.removeAll { $0 == conversationID }
        queue.append(conversationID)
        admit()
        return client
    }

    /// Opening a conversation or the first keystroke: be ready at Enter.
    func prewarm(conversationID: Int64, config: ChatSessionConfig) {
        _ = session(for: conversationID, config: config)
    }

    func close(conversationID: Int64) {
        queue.removeAll { $0 == conversationID }
        if let client = clients.removeValue(forKey: conversationID) { retire(client) }
    }

    /// A chat project's instructions, sources or files changed (or it was
    /// deleted): its sessions run on the old prompt, and none may record its
    /// session id again (the write just cleared the stored ones — a late
    /// `session_ready` would put one back). A launched busy one finishes its
    /// turn first, then is replaced on the next request or policy tick;
    /// every other one closes now — a pending one too, since its argv
    /// already carries the old `--resume`. A turn a pending one held never
    /// reached a provider: it is re-sent on a fresh session (no `--resume`,
    /// replaying the history) with the new prompt — out of the project when
    /// it was deleted (owner decision 2026-10-01: never left "Stopped").
    ///
    /// They all leave the queue first: closing one re-runs admission, which
    /// must not launch another stale one still waiting behind it.
    func retireSessions(projectID: Int64, deleted: Bool = false) {
        let stale = clients.filter { $0.value.config.projectID == projectID }
        queue.removeAll { stale[$0] != nil }
        for (id, client) in stale {
            client.retireAfterTurn()
            guard !client.isBusy || client.isPending else { continue }
            let held = client.surrenderHeldTurn()
            close(conversationID: id)
            guard let held else { continue }
            var fresh = client.config
            fresh.resumeSessionID = nil
            if deleted { fresh.projectID = nil }
            let command = held.command
            let replayed = ChatTurnCommand(turnID: command.turnID, text: command.text,
                                           attachments: command.attachments, replay: true)
            session(for: id, config: fresh)
                .startTurn(ChatTurnRequest(command: replayed, assistantMessageID: held.assistantMessageID))
        }
    }

    /// App quit: every session gets `close`, then one SIGTERM after the
    /// grace, then SIGKILL if it still lives; retirements already in flight
    /// are awaited too. Returns once every process is gone.
    func closeAll() async {
        stopPolicy()
        let all = Array(clients.values)
        clients = [:]
        queue = []
        let inFlight = retirements.values.map(\.task)
        let grace = closeGrace
        let kill = killAfter
        await withTaskGroup(of: Void.self) { group in
            for client in all {
                group.addTask { await client.close(grace: grace, killAfter: kill) }
            }
            for task in inFlight {
                group.addTask { await task.value }
            }
        }
    }

    /// One policy poll: expire idle sessions, drop dead ones, admit waiters.
    func tick() {
        evict(ChatSessionPolicy.decide(sessions: snapshots(), now: clock(), wanted: nil, retiring: retirements.count))
        admit()
    }

    func startPolicy() {
        policyTask?.cancel()
        policyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ChatSessionPolicy.pollInterval)
                self?.tick()
            }
        }
    }

    func stopPolicy() {
        policyTask?.cancel()
        policyTask = nil
    }

    // MARK: - Private

    /// Launches queued sessions, oldest first, while the policy grants slots.
    private func admit() {
        while let id = queue.first {
            guard let client = clients[id], client.isPending else {
                queue.removeFirst()
                continue
            }
            // The process this session replaces must be gone first.
            if retirements.values.contains(where: { $0.conversationID == id }) { return }
            let actions = ChatSessionPolicy.decide(sessions: snapshots(), now: clock(), wanted: id,
                                                   retiring: retirements.count)
            let evicted = evict(actions)
            // No slot (every session busy), or a slot that frees only once the
            // evicted processes exit — their retirement re-runs admission.
            guard actions.contains(.spawn(id)), !evicted else { return }
            queue.removeFirst()
            client.launch()
        }
    }

    /// Launched sessions only: a pending one holds no process yet.
    private func snapshots() -> [ChatSessionPolicy.SessionSnapshot] {
        clients.values.filter { !$0.isPending }.map {
            ChatSessionPolicy.SessionSnapshot(conversationID: $0.conversationID, lastActivity: $0.lastActivity,
                                              busy: $0.isBusy, alive: $0.isAlive)
        }
    }

    /// Applies the evictions; returns whether any live process was retired.
    @discardableResult
    private func evict(_ actions: [ChatSessionPolicy.PoolAction]) -> Bool {
        var retiredProcess = false
        for case let .evict(id) in actions {
            guard let client = clients.removeValue(forKey: id) else { continue }
            if retire(client) { retiredProcess = true }
        }
        return retiredProcess
    }

    /// Closes a session. A client with a live process is tracked until the
    /// process exits (it still holds a slot); returns whether it was.
    @discardableResult
    ///
    /// Ordering is load-bearing: the retirement is recorded BEFORE
    /// `abandon()`, because abandoning a busy client finishes its turn, which
    /// fires `onTurnFinished` → `admit()` synchronously — and admission must
    /// already see this process as holding a slot (CHAT-03).
    private func retire(_ client: ChatSessionClient) -> Bool {
        guard client.hasLiveProcess else {
            client.abandon()
            return false
        }
        let key = nextRetirementKey
        nextRetirementKey += 1
        let grace = closeGrace
        let kill = killAfter
        let task = Task { [weak self] in
            await client.close(grace: grace, killAfter: kill)
            self?.retirementFinished(key)
        }
        retirements[key] = (client.conversationID, task)
        // Synchronously: a running turn keeps its text as `partial` right now.
        client.abandon()
        return true
    }

    private func retirementFinished(_ key: Int) {
        retirements[key] = nil
        admit()
    }
}
