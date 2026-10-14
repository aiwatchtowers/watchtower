import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// Session input from the phone (mobile POC spec §5.2, §6.6, PROJ-16):
/// `session_input` (entity: the session id, params `{text}`),
/// `session_finish_request` (the session id; the fixed `finishLine`) and
/// `session_input_cancel` (entity: the original action's id).
///
/// A line goes only from a device the owner allowed to type
/// (`typing_allowed`, else `device_not_allowed`; an unlinked one never gets
/// here — the relay fails it `device_not_linked`), only to a live board
/// `claude` session, and only through the shared `SessionLineDelivery`
/// under every PROJ-12 rule, as one sanitised line. On top of those, right
/// before every paste (the delivery's gate, after its fresh state read) the
/// agent must be idle — the session's resolved state for the current run is
/// Stopped, Finished, Waiting for you or Error, or the run is marked and the
/// agent has not turned to it — and the prompt must hold no text; otherwise
/// the line is held, nothing typed: `agent_busy`, `needs_approval`,
/// `prompt_has_text`, or `state_unknown` when the state read failed. A held
/// line is echoed `held` with its reason, retried on every successful state
/// read (never on a timer), echoed again when its reason changes, and ends
/// `applied` (`delivery: submitted|typed`), `failed` (`cannot_type`,
/// `session_not_running`, `device_not_allowed` after a revoke) or `expired`
/// 24 h after the phone created it. Nothing is typed while the session waits
/// on a permission prompt.
///
/// Held lines are in the sidecar (`held_session_lines`) too: a hub start
/// queues them again (a held record is not `begun`), and one marked as being
/// typed when the hub stopped is `outcome_unknown`, never typed twice. Their
/// later outcomes go through `lateEcho` (the relay gate, after the pass that
/// echoed `held`), one after another. The handler owns its timeout and never
/// awaits the relay gate inside a dispatch.
@MainActor
final class SessionInputHandlers: HubCompanion {
    typealias Status = @MainActor (_ sessionID: Int64) -> SessionAgentStatus?

    /// The fixed line of `session_finish_request` (spec §6.5).
    static let finishLine = "Please wrap up: update the board, then call finish_session with a short summary."
    /// After the app submits a line to a session, the session counts as
    /// busy until a state read shows a hook stamp newer than the submit (its
    /// UserPromptSubmit hook lands asynchronously), or this long passed.
    static let submitSettle: TimeInterval = 30
    /// A held line expires this long after the phone created it.
    static let heldLifetime: TimeInterval = RelayProcessor.sessionRequestMaxAge
    /// This app launch: `TerminalCenter.runs` numbers restart at every launch,
    /// so a held line's run counts only within the launch that held it.
    nonisolated static let launch = UUID().uuidString
    nonisolated static let defaultTimeout: Duration = .seconds(30)
    static let kinds: [ActionKind] = [.sessionInput, .sessionFinishRequest, .sessionInputCancel]
    static let timeoutMessage = "The Mac did not finish this in time — check the session on the Mac"

    private static let logger = Logger(subsystem: Constants.bundleID, category: "SessionInputHandlers")

    private let dbPool: DatabasePool
    private let sidecar: HubSyncState
    private let lineDelivery: SessionLineDelivery
    private let terminalCenter: TerminalCenter
    private let status: Status
    private let deviceGrant: SessionStartStopHandlers.Grant
    private let lateEcho: RelayProcessor.LateEcho
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    /// What the gate found during the current try of a line, by record name;
    /// read (and cleared) once the try ends.
    private var verdicts: [String: Verdict] = [:]
    /// The lines this handler holds in `lineDelivery`: record name → session.
    private var owned: [String: Int64] = [:]
    /// Lines on their first try, inside `send` (no sidecar row yet; the
    /// relay's `begun` covers them).
    private var firstTries: Set<String> = []
    private var running = true
    /// The later echoes, one after another.
    private var echoes: Task<Void, Never>?

    init(
        dbPool: DatabasePool,
        sidecar: HubSyncState,
        lineDelivery: SessionLineDelivery,
        terminalCenter: TerminalCenter,
        status: @escaping Status,
        deviceGrant: @escaping SessionStartStopHandlers.Grant,
        lateEcho: @escaping RelayProcessor.LateEcho,
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = SessionInputHandlers.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.sidecar = sidecar
        self.lineDelivery = lineDelivery
        self.terminalCenter = terminalCenter
        self.status = status
        self.deviceGrant = deviceGrant
        self.lateEcho = lateEcho
        self.now = now
        self.timeout = timeout
        self.sleep = sleep
    }

    func register(on dispatcher: MobileHubCommandDispatcher) {
        for kind in Self.kinds {
            dispatcher.register(kind) { try await self.handle($0) }
        }
    }

    /// The echo of one action; a timeout is `outcome_unknown`.
    func handle(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        try await withHandlerTimeout(timeout, sleep: sleep, message: Self.timeoutMessage) {
            switch action.kind {
            case .sessionInput, .sessionFinishRequest: try await self.send(action)
            case .sessionInputCancel: try self.cancel(action)
            default: .failed(.unsupportedInPOC)
            }
        }
    }

    /// Waits for the later echoes queued so far (tests).
    func echoesSettled() async {
        await echoes?.value
    }

    // MARK: - HubCompanion

    /// The hub calls it on the main actor: the held lines go back in the
    /// queue.
    nonisolated func start() {
        MainActor.assumeIsolated { requeueHeldLines() }
    }

    /// Its held lines leave `lineDelivery` (their rows stay for the next
    /// start); later events are ignored.
    nonisolated func stop() {
        MainActor.assumeIsolated {
            running = false
            for (recordName, sessionID) in owned {
                lineDelivery.dropHeld(sessionID: sessionID) { $0 == .input(recordName) }
            }
            owned = [:]
        }
    }

    // MARK: - Input and finish

    /// One phone line and where it goes.
    private struct PhoneLine {
        let action: ActionRequestPayload
        let sessionID: Int64
        let line: String

        var recordName: String { action.recordName }
        var key: SessionLineDelivery.LineKey { .input(action.recordName) }
    }

    private enum Verdict {
        case hold(ActionReason)
        case fail(ActionReason)
        /// The line is over elsewhere (cancelled, finished, its hub
        /// stopped): nothing more to say about it.
        case gone
    }

    private enum Resolution {
        case final(ActionOutcome)
        case held(ActionReason)
        case gone
    }

    private func send(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard let sessionID = action.entityID.flatMap(Int64.init) else {
            return .failed(.invalidParams, message: "\(action.kind.rawValue) needs a session id")
        }
        let line: String
        if action.kind == .sessionFinishRequest {
            line = Self.finishLine
        } else {
            guard case let .string(text)? = action.params["text"] else {
                return .failed(.invalidParams, message: "session_input needs a text")
            }
            line = SessionInputText.normalize(text)
            guard !line.isEmpty else { return .failed(.invalidParams, message: "The message is empty") }
            guard line.count <= SessionInputText.maxLength else {
                return .failed(.invalidParams, message: "The message is longer than \(SessionInputText.maxLength) characters")
            }
        }
        guard deviceGrant(action.deviceID).typingAllowed else {
            return .failed(.deviceNotAllowed, message: Self.notAllowedMessage)
        }
        guard try await isBoardSession(sessionID) else {
            return .failed(.notFound, message: "This session no longer exists on the Mac")
        }
        guard terminalCenter.liveIDs.contains(sessionID) else {
            return .failed(.sessionNotRunning, message: Self.notRunningMessage)
        }
        let phone = PhoneLine(action: action, sessionID: sessionID, line: line)
        firstTries.insert(phone.recordName)
        let delivery = await deliverLine(phone)
        firstTries.remove(phone.recordName)
        return settleFirstTry(delivery, of: phone)
    }

    /// The line's first try (or its first try after a hub start).
    private func deliverLine(_ line: PhoneLine) async -> SessionLineDelivery.Delivery {
        await lineDelivery.deliverLine(
            line.line, key: line.key, sessionID: line.sessionID,
            // A handler gone (its hub rebuilt) drops its lines: the new
            // hub's start queues them again from the sidecar.
            gate: { [weak self] _ in self?.gate(line) ?? .drop },
            onHeldEvent: { [weak self] in self?.heldEvent($0, of: line) }
        )
    }

    /// Settles a first try: a final outcome, or the line held (its row
    /// stored for a hub restart).
    private func settleFirstTry(_ delivery: SessionLineDelivery.Delivery, of line: PhoneLine) -> ActionOutcome {
        switch resolve(delivery, of: line) {
        case let .final(outcome):
            lineDelivery.dropHeld(sessionID: line.sessionID) { $0 == line.key }
            return outcome
        case .gone:
            lineDelivery.dropHeld(sessionID: line.sessionID) { $0 == line.key }
            return .failed(.outcomeUnknown, message: Self.timeoutMessage)
        case let .held(reason):
            do {
                try sidecar.saveHeldLine(HubSyncState.HeldSessionLine(
                    action: try RelayCoder.makeEncoder().encode(line.action), recordName: line.recordName,
                    sessionID: line.sessionID, line: line.line, run: terminalCenter.runs[line.sessionID],
                    launch: Self.launch, reason: reason.rawValue
                ))
            } catch {
                // Not kept for a restart, so not kept at all: a held
                // line must be known to the ledger's next run.
                lineDelivery.dropHeld(sessionID: line.sessionID) { $0 == line.key }
                Self.logger.error("held line not stored: \(error.localizedDescription, privacy: .public)")
                return .failed(.writeFailed, message: "The Mac could not hold this message: \(error.localizedDescription)")
            }
            owned[line.recordName] = line.sessionID
            return .held(reason)
        }
    }

    /// PROJ-16's conditions right before a paste. The verdict is kept for
    /// the try's outcome. A held line's retry goes only while this handler
    /// runs and only by claiming its sidecar row for typing first: a row
    /// gone (cancelled, finished) or already claimed (another try of it)
    /// means the line is over here — dropped, never typed.
    private func gate(_ line: PhoneLine) -> SessionLineDelivery.GateAnswer {
        let retry = !firstTries.contains(line.recordName)
        if retry, !running {
            verdicts[line.recordName] = .gone
            return .drop
        }
        if let verdict = verdict(line) {
            verdicts[line.recordName] = verdict
            return .hold
        }
        guard retry else {
            verdicts[line.recordName] = nil
            return .go
        }
        do {
            guard try sidecar.claimHeldLineForTyping(line.recordName) else {
                verdicts[line.recordName] = .gone
                return .drop
            }
        } catch {
            // Not marked, a restart could type it twice: hold it.
            Self.logger.error("held line not marked typing: \(error.localizedDescription, privacy: .public)")
            verdicts[line.recordName] = .hold(.stateUnknown)
            return .hold
        }
        verdicts[line.recordName] = nil
        return .go
    }

    private func verdict(_ line: PhoneLine) -> Verdict? {
        if let failure = standingFailure(line) { return .fail(failure) }
        // The state was read right before (the delivery's fresh read): a
        // session it does not list was deleted.
        guard let current = status(line.sessionID) else { return .fail(.sessionNotRunning) }
        if current.state.kind == .needsApproval { return .hold(.needsApproval) }
        guard Self.isIdle(current), !justSubmitted(line.sessionID, status: current) else { return .hold(.agentBusy) }
        if terminalCenter.promptHoldsText(line.sessionID) { return .hold(.promptHasText) }
        return nil
    }

    /// A line went into the session within `submitSettle` and no hook has
    /// reported since: the agent is turning to it (its Working may not be
    /// written yet).
    private func justSubmitted(_ sessionID: Int64, status: SessionAgentStatus) -> Bool {
        guard let submitted = lineDelivery.submittedAt(sessionID),
              now().timeIntervalSince(submitted) < Self.submitSettle else { return false }
        guard let stamp = status.at.flatMap(SessionAgentStatus.parseStamp) else { return true }
        return stamp <= submitted
    }

    /// What ends a line whatever the session does: its age, its device's
    /// grant.
    private func standingFailure(_ line: PhoneLine) -> ActionReason? {
        if now().timeIntervalSince(line.action.createdAt) > Self.heldLifetime { return .expired }
        if !deviceGrant(line.action.deviceID).typingAllowed { return .deviceNotAllowed }
        return nil
    }

    /// The agent is idle for the current run: its turn ended — Stopped,
    /// Finished, Waiting for you (or Ready to check, its #534 form when the
    /// open asks are all checks or reviews) or Error by a hook state of this
    /// run — or the run is marked and no turn began (spec §6.6).
    static func isIdle(_ status: SessionAgentStatus) -> Bool {
        guard status.state.live else { return false }
        guard status.at != nil else { return status.runMarked }
        switch status.state.kind {
        case .stopped, .finished, .waitingOnAsk, .readyToCheck, .failed: return true
        case .notStarted, .running, .working, .background, .needsApproval: return false
        }
    }

    private func resolve(_ delivery: SessionLineDelivery.Delivery, of line: PhoneLine) -> Resolution {
        let verdict = verdicts.removeValue(forKey: line.recordName)
        switch delivery {
        case .submitted: return .final(.applied(["delivery": .string("submitted")]))
        case .typed: return .final(.applied(["delivery": .string("typed")]))
        case .copied: return .final(.failed(.cannotType, message: Self.cannotTypeMessage))
        case .noSession:
            if case .gone? = verdict { return .gone }
            return .final(.failed(.sessionNotRunning, message: Self.notRunningMessage))
        case .held, .queued:
            switch verdict {
            case .gone?: return .gone
            case let .fail(reason)?: return .final(Self.failure(reason))
            case let .hold(reason)?: return .held(reason)
            case nil:
                // Held by the delivery itself: another line is going to the
                // session, a permission prompt, or a failed state read.
                if delivery == .queued { return .held(.agentBusy) }
                return .held(status(line.sessionID)?.state.kind == .needsApproval ? .needsApproval : .stateUnknown)
            }
        }
    }

    /// A held line's try (or its skipped try at a permission prompt).
    private func heldEvent(_ event: SessionLineDelivery.HeldEvent, of line: PhoneLine) {
        guard running else { return }
        switch event {
        case .awaitingApproval:
            if let failure = standingFailure(line) {
                finish(line, Self.failure(failure))
            } else {
                stillHeld(line, .needsApproval)
            }
        case let .tried(delivery):
            switch resolve(delivery, of: line) {
            case let .final(outcome): finish(line, outcome)
            case let .held(reason): stillHeld(line, reason)
            case .gone: break
            }
        }
    }

    /// Still held: a changed reason is stored and echoed.
    private func stillHeld(_ line: PhoneLine, _ reason: ActionReason) {
        do {
            guard var row = try sidecar.heldLine(line.recordName) else { return }
            let changed = row.reason != reason.rawValue
            guard changed || row.typing else { return }
            row.reason = reason.rawValue
            row.typing = false
            try sidecar.saveHeldLine(row)
            if changed { echo(line.action, .held(reason)) }
        } catch {
            Self.logger.error("held line not updated: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The line's end: out of the queue and the sidecar, its outcome echoed.
    private func finish(_ line: PhoneLine, _ outcome: ActionOutcome) {
        lineDelivery.dropHeld(sessionID: line.sessionID) { $0 == line.key }
        owned[line.recordName] = nil
        do {
            try sidecar.removeHeldLine(line.recordName)
        } catch {
            Self.logger.error("held line not removed: \(error.localizedDescription, privacy: .public)")
        }
        echo(line.action, outcome)
    }

    /// A later echo, after the ones queued before it.
    private func echo(_ action: ActionRequestPayload, _ outcome: ActionOutcome) {
        let previous = echoes
        let lateEcho = self.lateEcho
        echoes = Task {
            await previous?.value
            do {
                try await lateEcho(action, outcome)
            } catch {
                Self.logger.error("late echo \(action.recordName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Revoke (spec §10)

    /// The device lost its typing grant or its link: each of its held lines
    /// not being typed right now fails `device_not_allowed`.
    func revoked(deviceID: String) {
        for line in storedLines() where line.phone.action.deviceID == deviceID && !line.row.typing {
            finish(line.phone, .failed(.deviceNotAllowed, message: Self.notAllowedMessage))
        }
    }

    // MARK: - Cancel

    /// Drops the original's held line and echoes it `cancelled`; a line
    /// already gone (delivered, failed, being typed) is left as it is. Only
    /// the phone that sent the line may cancel it.
    private func cancel(_ action: ActionRequestPayload) throws -> ActionOutcome {
        guard let originalID = action.entityID, !originalID.isEmpty else {
            return .failed(.invalidParams, message: "session_input_cancel needs the original action id")
        }
        let recordName = ActionRequestPayload.recordName(id: originalID)
        guard let row = try sidecar.heldLine(recordName), !row.typing,
              let phone = Self.phoneLine(row) else { return .applied() }
        guard phone.action.deviceID == action.deviceID else {
            return .failed(.deviceNotAllowed, message: "Only the phone that sent this message can cancel it")
        }
        finish(phone, ActionOutcome(status: .cancelled, reason: .cancelled, result: nil, errorMessage: "Cancelled on the phone"))
        return .applied()
    }

    // MARK: - Hub start

    private func requeueHeldLines() {
        running = true
        for line in storedLines() {
            let phone = line.phone
            if line.row.typing {
                finish(phone, .failed(.outcomeUnknown, message: "Your Mac restarted while typing this — check the session on the Mac"))
            } else if let failure = standingFailure(phone) {
                finish(phone, Self.failure(failure))
            } else if line.row.launch != Self.launch || !terminalCenter.liveIDs.contains(phone.sessionID)
                        || terminalCenter.runs[phone.sessionID] != line.row.run {
                finish(phone, .failed(.sessionNotRunning, message: Self.notRunningMessage))
            } else {
                // An earlier hub's copy in the queue goes first.
                lineDelivery.dropHeld(sessionID: phone.sessionID) { $0 == phone.key }
                owned[phone.recordName] = phone.sessionID
                Task { await self.retry(phone) }
            }
        }
    }

    /// A held line queued again: settled like a held try.
    private func retry(_ line: PhoneLine) async {
        let delivery = await deliverLine(line)
        guard running else { return }
        switch resolve(delivery, of: line) {
        case let .final(outcome): finish(line, outcome)
        case let .held(reason): stillHeld(line, reason)
        case .gone: break
        }
    }

    private func storedLines() -> [(row: HubSyncState.HeldSessionLine, phone: PhoneLine)] {
        let rows: [HubSyncState.HeldSessionLine]
        do {
            rows = try sidecar.heldLines()
        } catch {
            Self.logger.error("held lines unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return rows.compactMap { row in
            guard let phone = Self.phoneLine(row) else {
                Self.logger.warning("undecodable held line \(row.recordName, privacy: .public): dropped")
                try? sidecar.removeHeldLine(row.recordName)
                return nil
            }
            return (row, phone)
        }
    }

    private static func phoneLine(_ row: HubSyncState.HeldSessionLine) -> PhoneLine? {
        guard let action = try? RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: row.action) else { return nil }
        return PhoneLine(action: action, sessionID: row.sessionID, line: row.line)
    }

    // MARK: - Helpers

    static let notAllowedMessage = "This phone is not allowed to type into sessions — Allow it in Settings → Mobile on the Mac"
    static let notRunningMessage = "The session is not running on the Mac"
    static let cannotTypeMessage = "The session can't take typed text — it is on the Mac's clipboard"

    private static func failure(_ reason: ActionReason) -> ActionOutcome {
        switch reason {
        case .expired: ActionOutcome(status: .expired, reason: .expired, result: nil,
                                     errorMessage: "Held for a day without the session getting idle")
        case .deviceNotAllowed: .failed(reason, message: notAllowedMessage)
        case .sessionNotRunning: .failed(reason, message: notRunningMessage)
        default: .failed(reason)
        }
    }

    /// A live or stopped `claude` session of a workbench: the phone sees
    /// nothing else.
    private func isBoardSession(_ sessionID: Int64) async throws -> Bool {
        try await dbPool.read { db in
            guard let row = try TerminalSessionQueries.fetch(db, id: sessionID),
                  row.kind == .claude, let projectID = row.projectID else { return false }
            return try WorkbenchQueries.fetch(db, id: projectID) != nil
        }
    }
}

extension ActionOutcome {
    static func held(_ reason: ActionReason) -> Self {
        Self(status: .held, reason: reason, result: nil, errorMessage: nil)
    }
}

extension ActionRequestPayload {
    /// The record name of the action with id `id`.
    static func recordName(id: String) -> String { "action-\(id)" }
}
