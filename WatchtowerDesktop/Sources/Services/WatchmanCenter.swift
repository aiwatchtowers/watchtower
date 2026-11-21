import Foundation
import Observation
import WatchtowerCore

/// Settings → Profile → Watchman (#1823, phase 1) over `watchtower watchman …`:
/// `status --json` for the screen, `learn --workbench N --start --json`
/// (Start Learning, after the owner has seen the estimate) and
/// `backtest --workbench N --json` (Run Backtest Now / Retry). App-wide on
/// `AppState`, so a learning pass or a backtest the owner started keeps its
/// busy line when Settings closes and opens again.
///
/// Both owner verbs block until the CLI finishes (a backtest takes minutes);
/// meanwhile `watch()` rereads the status every `pollInterval` for the
/// progress line. Phase 2 adds editing (`editing`): each learned workbench's
/// `profile --json` with `profile set|unpin` (category texts and the sleep
/// window) and `limits list|add|remove`. Every write goes through the CLI;
/// nothing here writes the database.
///
/// Phase 2 (#1823, D47): the arming controls — Hand to Watchman / Take back
/// on the session strip and the target panel, the tray's Hand all running
/// sessions — go through `watchman arm|disarm --json` (one implementation of
/// arming, its sidecar and git hooks) and read the arming from the status.
@MainActor
@Observable
final class WatchmanCenter {
    nonisolated static let pollInterval: Duration = .seconds(3)
    /// How often a session strip on screen rereads while its workbench still
    /// learns: its chip's percent follows the learner (tuning spec §3).
    nonisolated static let learningPollInterval: Duration = .seconds(30)
    /// A whole backtest: up to 8 × 30 model calls plus the judge.
    nonisolated static let backtestTimeout: TimeInterval = 6 * 3600
    /// The first learning pass runs under its own budget in the CLI.
    nonisolated static let learnTimeout: TimeInterval = 2 * 3600
    /// `profile set|unpin`, `limits add|remove`: one row write each.
    nonisolated static let editTimeout: TimeInterval = 60

    private(set) var state: WatchmanSettingsState = .loading
    /// Workbenches whose `learn --start` this app runs now.
    private(set) var learningHere: Set<Int64> = []
    /// Workbenches whose `backtest` this app runs now.
    private(set) var backtestHere: Set<Int64> = []
    /// One line per workbench under its controls: busy, refused, failed.
    private(set) var notices: [Int64: String] = [:]
    /// A reread that failed while a status is on screen: the screen keeps
    /// the last status and shows this line.
    private(set) var readError: String?
    /// Profiles, limits and the lines of their failed reads and edits.
    private(set) var editing = WatchmanEditingData()

    /// The last status read: the arming the controls show; nil before one.
    private(set) var lastStatus: WatchmanStatus?
    /// Arming scopes whose `arm`/`disarm` (or its check) this app runs now.
    private(set) var armingHere: Set<WatchmanArmScope> = []
    /// One line per scope under its control: a failed arm or take back.
    private(set) var armNotices: [WatchmanArmScope: String] = [:]
    /// The arm or instruction sheet on screen. Setting it (or nil, Cancel)
    /// drops the last confirm's failure line.
    var sheet: WatchmanArmSheetRequest? {
        didSet {
            sheetGeneration += 1
            if sheet?.token != oldValue?.token { sheetError = nil }
        }
    }
    /// Bumped by every sheet change (opened, replaced, cancelled): a sheet
    /// whose read started before one is not opened.
    @ObservationIgnored private var sheetGeneration = 0
    /// Scopes whose sheet is being opened (the check, the read), with the
    /// sheet generation each open started in. An open that another sheet
    /// made stale (the generation moved on) no longer blocks a fresh one.
    @ObservationIgnored private var opening: [WatchmanArmScope: Int] = [:]

    /// Starts opening `scope`'s sheet; nil while a current open of it runs.
    private func beginOpening(_ scope: WatchmanArmScope) -> Int? {
        if let started = opening[scope], started == sheetGeneration { return nil }
        opening[scope] = sheetGeneration
        return sheetGeneration
    }

    /// Ends an open: only its own entry (a fresh open may have replaced it).
    private func endOpening(_ scope: WatchmanArmScope, _ generation: Int) {
        if opening[scope] == generation { opening[scope] = nil }
    }
    /// The sheet's confirm runs now (the check again, the arm or the save):
    /// its buttons wait.
    private(set) var confirming = false
    /// The sheet's last confirm failed: `Could not save: …` with Retry; the
    /// sheet and its text stay.
    private(set) var sheetError: String?
    /// The last instruction the app saw per session or target (the
    /// database read before a sheet, a status read, a hand-over, a save):
    /// the chip's tooltip, and the sheet's pre-fill when the read fails.
    private(set) var instructions: [WatchmanArmScope: String] = [:]
    /// A session's title for the arm sheet's list; AppState wires the
    /// workbench sessions. nil: "Session N".
    @ObservationIgnored var sessionTitle: (Int64) -> String? = { _ in nil }
    /// Reads a scope's stored instruction from `watchman_instructions`
    /// (`WatchmanInstructionQueries`) right before a sheet opens, so a text
    /// kept over Take back or a restart pre-fills it (D7). AppState wires
    /// the database; nil: only what this app saw.
    @ObservationIgnored var readInstruction: (@Sendable (WatchmanArmScope) async throws -> String)?

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// The status read the controls started and that runs now: controls
    /// appearing together share it.
    @ObservationIgnored private var inFlightRead: Task<Void, Never>?
    /// Bumped by every read: an older reply never overwrites a newer one.
    @ObservationIgnored private var readToken = 0
    /// Bumped by every limits read, and per workbench by every profile read.
    @ObservationIgnored private var limitsToken = 0
    @ObservationIgnored private var profileTokens: [Int64: Int] = [:]
    /// Learned workbenches whose profile read ended (read or failed) since
    /// the last `refresh()`; a cancelled read leaves its workbench out, so
    /// the next read retries it.
    @ObservationIgnored private var profilesAsked: Set<Int64> = []
    /// Bumped by `refresh()`: a profile read started before it never marks
    /// its workbench read for the new round.
    @ObservationIgnored private var profileGeneration = 0

    /// `status`: one already read (a design shot draws the controls on it);
    /// the app reads its own on first use.
    init(
        runner: any CLIRunnerProtocol,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        status: WatchmanStatus? = nil
    ) {
        self.runner = runner
        self.sleep = sleep
        lastStatus = status
        daemon = status?.daemon ?? .unknown
        if let status { remember(status) }
    }

    /// Each armed session's own instruction, as the status printed it.
    private func remember(_ status: WatchmanStatus) {
        for session in status.armedSessions.values {
            instructions[.session(session.id)] = session.instructions
        }
    }

    /// `daemon_running` of the last status read; unknown before one, or
    /// from a CLI that does not print it (the journal's daemon line).
    private(set) var daemon: WatchmanDaemonState = .unknown

    /// A learning pass or a backtest is under way here or in the daemon.
    var needsPolling: Bool {
        if !learningHere.isEmpty || !backtestHere.isEmpty { return true }
        return lastStatus?.workbenches.contains { row in
            // A relabel pass runs in the daemon: keep reading until it is done.
            if row.isRelabelling { return true }
            switch WatchmanWorkbenchPhase.of(row) {
            case .learning, .running: return true
            default: return false
            }
        } ?? false
    }

    func phase(of row: WatchmanWorkbenchStatus) -> WatchmanWorkbenchPhase {
        WatchmanWorkbenchPhase.of(
            row, learningHere: learningHere.contains(row.workbench), backtestHere: backtestHere.contains(row.workbench)
        )
    }

    // MARK: - Reads

    func load() async {
        readToken += 1
        let token = readToken
        do {
            let data = try await runner.run(args: ["watchman", "status", "--json"])
            let status = try JSONDecoder().decode(WatchmanStatus.self, from: data)
            guard token == readToken else { return }
            if status.ok {
                lastStatus = status
                daemon = status.daemon
                readError = nil
                remember(status)
                apply()
            } else {
                readFailed(Self.replyError(data) ?? "the status reply was not ok")
            }
        } catch {
            guard token == readToken, !(error is CancellationError) else { return }
            readFailed(Self.message(error))
        }
        // Also after a failed read: the workbenches of the last status read.
        await loadNewProfiles()
    }

    /// Reads everything again: the status, each learned workbench's
    /// profile and the limits. Opening Settings and **Retry** run it.
    func refresh() async {
        profilesAsked.removeAll()
        profileGeneration += 1
        await load()
        await loadLimits()
    }

    /// Replaces the section only when no status was read yet.
    private func readFailed(_ message: String) {
        if lastStatus == nil {
            state = .readFailed(message)
        } else {
            readError = message
        }
    }

    /// Reads once, then again every `pollInterval` while something runs.
    /// The view restarts it whenever `needsPolling` changes.
    func watch() async {
        await refresh()
        while needsPolling, !Task.isCancelled {
            do { try await sleep(Self.pollInterval) } catch { return }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    // MARK: - Owner verbs

    func startLearning(workbench: Int64) async {
        guard learningHere.insert(workbench).inserted else { return }
        notices[workbench] = nil
        apply()
        let args = ["watchman", "learn", "--workbench", String(workbench), "--start", "--json"]
        let failure = await call(args, origin: .owner, timeout: Self.learnTimeout).failure
        learningHere.remove(workbench)
        if let failure { notices[workbench] = WatchmanSettingsCopy.learnFailed(failure) }
        await load()
    }

    func runBacktest(workbench: Int64) async {
        // Reads the last polled status; the CLI's own refusal while the relabel pass is unfinished is the backstop.
        guard lastStatus?.workbench(workbench)?.isRelabelling != true else { return }
        guard backtestHere.insert(workbench).inserted else { return }
        notices[workbench] = nil
        apply()
        let args = ["watchman", "backtest", "--workbench", String(workbench), "--json"]
        let outcome = await call(args, origin: .owner, timeout: Self.backtestTimeout)
        backtestHere.remove(workbench)
        // A run that started and failed is a `failed` row the status shows
        // with its error; the notice is only for a call that never got that far.
        if let failure = outcome.failure, !Self.hasBacktestRow(outcome.stdout) {
            notices[workbench] = failure == "busy" ? WatchmanSettingsCopy.busy : failure
        }
        await load()
    }

    // MARK: - Arming

    /// `arm` and `disarm` print their reply at once, after the branch
    /// protection check (15 s budget) at most.
    nonisolated static let armTimeout: TimeInterval = 120

    /// Why the controls have no fresh arming to show: the last read failed
    /// (with or without an older status on screen); nil otherwise.
    var armingReadError: String? {
        if let readError { return readError }
        if case let .readFailed(message) = state { return message }
        return nil
    }

    /// Rereads the status for a control, the panel or the tray that became
    /// visible (an arm made elsewhere shows then). No timer: only appearing
    /// rereads. Reads already running are shared, not repeated.
    func reread() async {
        if let inFlightRead { return await inFlightRead.value }
        let read = Task { await load() }
        inFlightRead = read
        await read.value
        inFlightRead = nil
    }

    /// `reread`, then again every `learningPollInterval` while `workbench`
    /// is still learning (nil: once), until the calling task ends — the
    /// session strip, whose chip reads `Watchman · learning <p>%` meanwhile.
    func reread(followingLearning workbench: Int64?) async {
        await reread()
        guard let workbench else { return }
        while lastStatus?.workbench(workbench)?.isStillLearning == true, !Task.isCancelled {
            do { try await sleep(Self.learningPollInterval) } catch { return }
            guard !Task.isCancelled else { return }
            await reread()
        }
    }

    /// Hand to Watchman: `arm --check` first, then always the sheet — the
    /// moment to give the session an instruction (tuning spec §2): the
    /// first-time one on a first time or a warning, the short one
    /// otherwise, the tray's for every running session. `workbench` names
    /// the first-time sheet; `title` the session or target the short one
    /// names (nil: the session's own title, else its id). The field is
    /// pre-filled with the scope's stored instruction (`storedInstruction`);
    /// the tray's starts empty. True when the sheet opened — the tray then
    /// brings the main window up for it.
    /// One sheet at a time: while one is open nothing replaces it (the tray
    /// only brings it up, so a draft is never lost), and a press while the
    /// same scope's sheet is being opened does nothing.
    @discardableResult
    func handTo(_ scope: WatchmanArmScope, workbench: String?, title: String? = nil) async -> Bool {
        if sheet != nil { return true }
        if let started = opening[scope], started == sheetGeneration { return false }
        guard armingHere.insert(scope).inserted, let generation = beginOpening(scope) else { return false }
        defer { endOpening(scope, generation) }
        armNotices[scope] = nil
        let check = await check(scope)
        armingHere.remove(scope)
        switch check {
        case let .failed(message):
            armNotices[scope] = WatchmanArmingCopy.armFailed(message)
            return false
        case let .reply(reply):
            if let refusal = Self.allRunningRefusal(scope, reply) {
                armNotices[scope] = refusal
                return false
            }
            // The tray's field starts empty and never clears: no read.
            let stored = scope == .allRunning ? StoredInstruction(field: "", known: "") : await storedInstruction(scope)
            // Another sheet opened (or one was opened and cancelled) meanwhile: it wins.
            guard sheet == nil, sheetGeneration == generation else { return sheet != nil }
            remember(stored, scope)
            sheet = makeSheet(scope, workbench: workbench, title: title, reply: reply,
                              instruction: stored.field, stored: stored.known)
            return true
        }
    }

    /// What a sheet opens with: the field's text, and the stored text when
    /// a fresh database read says what it is (nil otherwise: an empty field
    /// then never clears it).
    struct StoredInstruction {
        let field: String
        let known: String?
    }

    /// The scope's stored instruction. Only a successful database read makes
    /// it known; when the read fails the last text this app saw only fills
    /// the field, since another writer may have changed it since. Nothing is
    /// remembered here: the caller does (`remember`) once its read is still
    /// current, so a stale read never puts old text in the chip's tooltip.
    private func storedInstruction(_ scope: WatchmanArmScope) async -> StoredInstruction {
        if let readInstruction, let text = try? await readInstruction(scope) {
            return StoredInstruction(field: text, known: text)
        }
        return StoredInstruction(field: instructions[scope] ?? "", known: nil)
    }

    /// Keeps a fresh read's text as the last one this app saw.
    private func remember(_ stored: StoredInstruction, _ scope: WatchmanArmScope) {
        if let known = stored.known { instructions[scope] = known }
    }

    /// The tray's Hand all running sessions to Watchman: the same check and
    /// sheet as a control's. True when the sheet opened.
    func handAllRunning() async -> Bool {
        await handTo(.allRunning, workbench: nil)
    }

    /// Instruction… on an armed chip or panel: the edit sheet, pre-filled
    /// with the scope's stored instruction (`storedInstruction`).
    /// The same one-sheet rule as `handTo`.
    func editInstruction(_ scope: WatchmanArmScope, title: String? = nil) async {
        guard scope != .allRunning, sheet == nil, let generation = beginOpening(scope) else { return }
        defer { endOpening(scope, generation) }
        let stored = await storedInstruction(scope)
        guard sheet == nil, sheetGeneration == generation else { return }
        remember(stored, scope)
        sheet = WatchmanArmSheetRequest(
            scope: scope, sessions: [], instruction: stored.field, stored: stored.known,
            content: .edit(subject: subject(scope, title)))
    }

    /// The sheet's Hand over or Save with the field's text: arms its scope
    /// (or saves the instruction) and closes it. A failure keeps the sheet
    /// and its text with `Could not save: …`; Retry calls this again.
    /// Every running session (the tray) is checked again first: when the
    /// running set changed since the sheet opened, the sheet shows the new
    /// set and asks again; otherwise exactly the confirmed sessions are armed
    /// (`--only`), so a session started meanwhile is never armed unseen. One
    /// confirm at a time; a sheet dismissed during the check arms nothing.
    /// `token` is the sheet the button was pressed on: a sheet replaced
    /// before this runs is not confirmed.
    func confirmSheet(token: UUID, instruction: String) async {
        guard !confirming, let request = sheet, request.token == token else { return }
        confirming = true
        sheetError = nil
        defer { confirming = false }
        switch request.content.mode {
        case .edit:
            await saveInstruction(request, text: instruction)
        case .firstTime, .short:
            await armFromSheet(request, only: [],
                               instruction: Self.instructionFlag(instruction, stored: request.stored, tray: false))
        case .tray:
            await confirmAllRunning(request, instruction: instruction)
        }
    }

    /// The tray's confirm: the running set checked again, then exactly it.
    private func confirmAllRunning(_ request: WatchmanArmSheetRequest, instruction: String) async {
        let check = await check(.allRunning)
        // Another sheet (or none) since the press: this confirm is void.
        guard sheet?.token == request.token else { return }
        switch check {
        case let .failed(message):
            sheetError = WatchmanArmingCopy.saveFailed(message)
        case let .reply(reply):
            if let refusal = Self.allRunningRefusal(.allRunning, reply) {
                // Nothing runs any more: the sheet and the typed text stay.
                sheetError = refusal
            } else if Set(reply.sessions ?? []) != Set(request.sessions) {
                sheet = makeSheet(.allRunning, workbench: nil, title: nil, reply: reply, instruction: instruction,
                                  stored: "", notice: WatchmanArmingCopy.sessionsChanged)
            } else {
                await armFromSheet(request, only: request.sessions,
                                   instruction: Self.instructionFlag(instruction, stored: "", tray: true))
            }
        }
    }

    /// The `--instructions-file -` text a hand-over passes; nil passes no
    /// flag, so the stored text stays. The tray's empty field keeps each
    /// session's text; a single scope's empty field clears only a text the
    /// sheet was pre-filled with (the owner emptied it); an unknown stored
    /// text (nil) is never cleared.
    nonisolated static func instructionFlag(_ typed: String, stored: String?, tray: Bool) -> String? {
        if !blank(typed) { return typed }
        guard !tray, let stored, !blank(stored) else { return nil }
        return ""
    }

    nonisolated private static func blank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The arm behind a sheet: on success it closes and remembers the text;
    /// on failure the sheet stays with the line.
    private func armFromSheet(_ request: WatchmanArmSheetRequest, only: [Int64], instruction: String?) async {
        let scope = request.scope
        guard let outcome = await runArm(scope, only: only, instruction: instruction) else {
            // Nothing was sent: every running session without a set, or the
            // scope's own arm or Take back runs.
            if sheet?.token == request.token {
                sheetError = scope == .allRunning && only.isEmpty
                    ? WatchmanArmingCopy.nothingToHandOver : WatchmanArmingCopy.armInProgress
            }
            return
        }
        let onScreen = sheet?.token == request.token
        if let failure = outcome.failure {
            if onScreen {
                sheetError = WatchmanArmingCopy.saveFailed(failure)
            } else {
                armNotices[scope] = WatchmanArmingCopy.armFailed(failure)
            }
        } else {
            if onScreen { sheet = nil }
            if let instruction {
                // Only the sessions the CLI armed: one dropped meanwhile kept its own text.
                let armed = scope == .allRunning
                    ? (outcome.reply?.sessions ?? only).filter { !(outcome.reply?.dropped ?? []).contains($0) }
                        .map(WatchmanArmScope.session)
                    : [scope]
                let stored = Self.stored(instruction)
                for each in armed { instructions[each] = stored }
            }
            armNotices[scope] = outcome.notice
        }
        await load()
    }

    /// Edit mode's Save: `watchman instruct … --text-file -`, the text on
    /// stdin; the stored text as Go kept it (trimmed, clipped). An empty
    /// field over a stored text the sheet could not read reads it again
    /// first (Retry does too): none stored saves; a stored one replaces the
    /// sheet pre-filled with it, so it is cleared only once seen; a failed
    /// read refuses.
    private func saveInstruction(_ request: WatchmanArmSheetRequest, text: String) async {
        // An empty file clears: never over a stored text the owner did not see.
        if Self.blank(text), request.stored == nil {
            let stored = await storedInstruction(request.scope)
            guard sheet?.token == request.token else { return }
            guard let known = stored.known else {
                sheetError = WatchmanArmingCopy.instructionUnread
                return
            }
            remember(stored, request.scope)
            if !Self.blank(known) {
                sheet = WatchmanArmSheetRequest(
                    scope: request.scope, sessions: [], instruction: known, stored: known,
                    content: .edit(subject: request.content.subject ?? "", notice: WatchmanArmingCopy.instructionShown))
                return
            }
        }
        let args = ["watchman", "instruct"] + request.scope.flags() + ["--text-file", "-", "--json"]
        let outcome = await call(args, stdin: Data(text.utf8), timeout: Self.editTimeout)
        if let failure = outcome.failure {
            if sheet?.token == request.token { sheetError = WatchmanArmingCopy.saveFailed(failure) }
            return
        }
        let reply = try? JSONDecoder().decode(WatchmanInstructReply.self, from: outcome.stdout)
        instructions[request.scope] = reply?.instructions ?? Self.stored(text)
        if sheet?.token == request.token { sheet = nil }
        await load()
    }

    /// The text as Go stores it: trimmed and clipped.
    nonisolated private static func stored(_ text: String) -> String {
        WatchmanArmingCopy.clipped(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Every running session is armed only as an explicit set: a check that
    /// lists none (nothing runs) or cannot list them (an older CLI) stops here.
    private static func allRunningRefusal(_ scope: WatchmanArmScope, _ reply: WatchmanArmReply) -> String? {
        guard scope == .allRunning else { return nil }
        guard let sessions = reply.sessions else { return WatchmanArmingCopy.updateCLI }
        return sessions.isEmpty ? WatchmanArmingCopy.nothingToHandOver : nil
    }

    private func makeSheet(
        _ scope: WatchmanArmScope,
        workbench: String?,
        title: String?,
        reply: WatchmanArmReply,
        instruction: String,
        stored: String?,
        notice: String? = nil
    ) -> WatchmanArmSheetRequest {
        let sessions = reply.sessions ?? []
        let names = sessions.map { id in sessionTitle(id).map { "#\(id) \($0)" } ?? WatchmanArmingCopy.sessionFallback(id) }
        let content = WatchmanArmSheetContent.handOver(
            scope, workbench: workbench, reply: reply, subject: subject(scope, title), sessions: names, notice: notice)
        return WatchmanArmSheetRequest(scope: scope, sessions: sessions, instruction: instruction, stored: stored,
                                       content: content)
    }

    /// "#41 Ship task 3": the given title, else the session's own.
    private func subject(_ scope: WatchmanArmScope, _ title: String?) -> String {
        var own = title
        if own == nil, case let .session(id) = scope { own = sessionTitle(id) }
        return WatchmanArmingCopy.subject(scope, title: own)
    }

    /// `watchman arm --check`: writes nothing.
    func check(_ scope: WatchmanArmScope) async -> WatchmanArmCheck {
        let outcome = await call(["watchman", "arm"] + scope.flags() + ["--check", "--json"], timeout: Self.armTimeout)
        if let failure = outcome.failure { return .failed(failure) }
        guard let reply = try? JSONDecoder().decode(WatchmanArmReply.self, from: outcome.stdout) else {
            return .failed(WatchmanArmingCopy.replyUnreadable)
        }
        return .reply(reply)
    }

    /// `watchman arm`, then the status again. The scope's notice is the
    /// failure, or what the reply has to say (warnings, the D21 line, the
    /// sidecar note); an unreadable reply after exit 0 lets the status say.
    /// A press while the scope's arm or Take back runs does nothing (nil).
    /// `instruction` goes on stdin with `--instructions-file -` (nil: no
    /// flag, the stored text stays).
    @discardableResult
    func arm(_ scope: WatchmanArmScope, only: [Int64] = [], instruction: String? = nil) async -> WatchmanArmReply? {
        guard let outcome = await runArm(scope, only: only, instruction: instruction) else { return nil }
        armNotices[scope] = outcome.failure.map(WatchmanArmingCopy.armFailed) ?? outcome.notice
        await load()
        return outcome.failure == nil ? outcome.reply : nil
    }

    /// One `watchman arm` call: its failure line, or its reply and the
    /// notice that stays under the control.
    struct ArmOutcome {
        let failure: String?
        let reply: WatchmanArmReply?

        /// After a success: what the reply has to say, or that the state is
        /// reread when the reply could not be read.
        var notice: String? {
            reply.map(WatchmanArmingCopy.armedNotice) ?? WatchmanArmingCopy.rereading
        }
    }

    /// Runs `watchman arm`; nil when it did not run (the scope's arm or Take
    /// back runs, or every running session without an explicit set).
    private func runArm(_ scope: WatchmanArmScope, only: [Int64], instruction: String?) async -> ArmOutcome? {
        // Every running session only ever as an explicit set.
        if scope == .allRunning, only.isEmpty {
            armNotices[scope] = WatchmanArmingCopy.nothingToHandOver
            return nil
        }
        // One arm of a scope at a time, as one Take back.
        guard armingHere.insert(scope).inserted else { return nil }
        armNotices[scope] = nil
        // `--only` goes with every running session only (the CLI refuses it
        // with --session or --target).
        let onlyFlags = scope != .allRunning || only.isEmpty ? [] : ["--only", only.map(String.init).joined(separator: ",")]
        let textFlags = instruction == nil ? [] : ["--instructions-file", "-"]
        let outcome = await call(["watchman", "arm"] + scope.flags() + onlyFlags + textFlags + ["--json"],
                                 stdin: instruction.map { Data($0.utf8) }, timeout: Self.armTimeout)
        armingHere.remove(scope)
        return ArmOutcome(failure: outcome.failure,
                          reply: try? JSONDecoder().decode(WatchmanArmReply.self, from: outcome.stdout))
    }

    /// Take back: `watchman disarm`, then the status again.
    func disarm(_ scope: WatchmanArmScope) async {
        guard armingHere.insert(scope).inserted else { return }
        armNotices[scope] = nil
        let outcome = await call(["watchman", "disarm"] + scope.flags(disarm: true) + ["--json"], timeout: Self.armTimeout)
        armingHere.remove(scope)
        if let failure = outcome.failure {
            armNotices[scope] = WatchmanArmingCopy.takeBackFailed(failure)
        } else if let reply = try? JSONDecoder().decode(WatchmanDisarmReply.self, from: outcome.stdout),
                  !reply.sidecarError.isEmpty {
            armNotices[scope] = WatchmanArmingCopy.takeBackSidecarNote
        }
        await load()
    }

    // MARK: - Editing (phase 2)

    /// Reads the profile of each workbench the last status shows learned
    /// and whose read has not ended since `refresh()`, also while polling
    /// goes on for another. A failed read keeps what was read before and
    /// shows its line.
    private func loadNewProfiles() async {
        for row in lastStatus?.workbenches ?? [] where row.isLearned && !profilesAsked.contains(row.workbench) {
            let generation = profileGeneration
            if await loadProfile(workbench: row.workbench), generation == profileGeneration {
                profilesAsked.insert(row.workbench)
            }
        }
    }

    private func loadLimits() async {
        limitsToken += 1
        let token = limitsToken
        do {
            let data = try await runner.run(args: ["watchman", "limits", "list", "--json"])
            let limits = try JSONDecoder().decode(WatchmanLimits.self, from: data)
            guard token == limitsToken else { return }
            editing.limits = limits
            editing.limitsReadError = nil
        } catch {
            guard token == limitsToken, !(error is CancellationError) else { return }
            editing.limitsReadError = Self.message(error)
        }
    }

    /// True only when this read published its profile or its error; false
    /// when it was cancelled or a newer read overtook it.
    @discardableResult
    private func loadProfile(workbench: Int64) async -> Bool {
        let token = (profileTokens[workbench] ?? 0) + 1
        profileTokens[workbench] = token
        do {
            let data = try await runner.run(args: ["watchman", "profile", "--workbench", String(workbench), "--json"])
            let profile = try JSONDecoder().decode(WatchmanProfile.self, from: data)
            guard profileTokens[workbench] == token else { return false }
            editing.profiles[workbench] = profile
            editing.profileReadErrors[workbench] = nil
        } catch {
            if error is CancellationError { return false }
            guard profileTokens[workbench] == token else { return false }
            editing.profileReadErrors[workbench] = Self.message(error)
        }
        return true
    }

    /// Saves and pins a category's text or, under `sleep_window`, the sleep
    /// window: checked here first (the window's `HH:MM-HH:MM`, a text's 1–20
    /// lines), then written to a temporary file for `profile set
    /// --text-file`. True once saved, so the editor closes; otherwise the
    /// entry's line says why.
    @discardableResult
    func saveProfile(workbench: Int64, key: String, text: String) async -> Bool {
        let slot = WatchmanEditSlot.profile(workbench: workbench, key: key)
        let checked = key == WatchmanProfileEntry.sleepWindowKey ? Self.sleepWindow(text) : Self.profileText(text)
        let value: String
        switch checked {
        case let .success(text): value = text
        case let .failure(problem):
            editing.errors[slot] = problem.line
            return false
        }
        guard editing.saving.insert(slot).inserted else { return false }
        defer { editing.saving.remove(slot) }
        editing.errors[slot] = nil
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchman-profile-\(UUID().uuidString).txt")
        do {
            try Data(value.utf8).write(to: file, options: .atomic)
        } catch {
            editing.errors[slot] = WatchmanSettingsCopy.saveFailed(SessionReportCenter.errorLine(error))
            return false
        }
        // The CLI has read it by the time it exits; a leftover file in the temporary directory is harmless.
        defer { try? FileManager.default.removeItem(at: file) }
        let args = ["watchman", "profile", "set", "--workbench", String(workbench), "--key", key,
                    "--text-file", file.path]
        if let failure = await call(args, timeout: Self.editTimeout).failure {
            editing.errors[slot] = WatchmanSettingsCopy.saveFailed(failure)
            return false
        }
        await reloadAfterProfileChange(workbench: workbench, key: key)
        return true
    }

    /// Unpins an entry: the next weekly rebuild replaces it.
    func unpin(workbench: Int64, key: String) async {
        let slot = WatchmanEditSlot.profile(workbench: workbench, key: key)
        guard editing.saving.insert(slot).inserted else { return }
        defer { editing.saving.remove(slot) }
        editing.errors[slot] = nil
        let args = ["watchman", "profile", "unpin", "--workbench", String(workbench), "--key", key]
        if let failure = await call(args, timeout: Self.editTimeout).failure {
            editing.errors[slot] = WatchmanSettingsCopy.unpinFailed(failure)
            return
        }
        await reloadAfterProfileChange(workbench: workbench, key: key)
    }

    /// Adds an owner's limit after the same checks the CLI makes
    /// (`ValidateLimitPattern`; an unclosed quote is left to the CLI, whose
    /// error shows). True once added, so the form closes.
    @discardableResult
    func addLimit(kind: WatchmanLimitKind, pattern: String) async -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.limitProblem(kind: kind, pattern: pattern) {
            editing.errors[.limits] = problem
            return false
        }
        guard editing.saving.insert(.limits).inserted else { return false }
        defer { editing.saving.remove(.limits) }
        editing.errors[.limits] = nil
        // `=` keeps a pattern that starts with "-" a value, not a flag.
        let args = ["watchman", "limits", "add", "--kind=\(kind.rawValue)", "--pattern=\(pattern)"]
        if let failure = await call(args, timeout: Self.editTimeout).failure {
            editing.errors[.limits] = WatchmanSettingsCopy.addFailed(failure)
            return false
        }
        await loadLimits()
        return true
    }

    /// Removes an owner's limit; a built-in row has no id to pass.
    func removeLimit(id: Int64) async {
        guard editing.saving.insert(.limits).inserted else { return }
        defer { editing.saving.remove(.limits) }
        editing.errors[.limits] = nil
        if let failure = await call(["watchman", "limits", "remove", "--id", String(id)], timeout: Self.editTimeout).failure {
            editing.errors[.limits] = WatchmanSettingsCopy.removeFailed(failure)
            return
        }
        await loadLimits()
    }

    /// Drops an edit's line (the owner cancelled or opened the editor again).
    func clearError(_ slot: WatchmanEditSlot) {
        editing.errors[slot] = nil
    }

    private func reloadAfterProfileChange(workbench: Int64, key: String) async {
        await loadProfile(workbench: workbench)
        // The sleep section reads the window and its pin from the status.
        if key == WatchmanProfileEntry.sleepWindowKey { await load() }
    }

    struct EditProblem: Error, Equatable {
        let line: String
    }

    /// `"00:30-07:45"` as the CLI stores it (ASCII digits only); the edges
    /// are trimmed, and an en dash (as the screen shows it) and spaces
    /// around the dash are accepted.
    static func sleepWindow(_ text: String) -> Result<String, EditProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "–", with: "-")
        let window = #/(?<start>(?:[01][0-9]|2[0-3]):[0-5][0-9]) *- *(?<end>(?:[01][0-9]|2[0-3]):[0-5][0-9])/#
        guard let match = trimmed.wholeMatch(of: window) else {
            return .failure(EditProblem(line: WatchmanSettingsCopy.sleepBadFormat))
        }
        return .success("\(match.output.start)-\(match.output.end)")
    }

    /// A category text: its non-blank lines, 1 to 20 of them.
    static func profileText(_ text: String) -> Result<String, EditProblem> {
        let lines = WatchmanProfileEntry(key: "", text: text, pinned: false, updatedAt: "").lines
        if lines.isEmpty { return .failure(EditProblem(line: WatchmanSettingsCopy.profileEmptyText)) }
        if lines.count > WatchmanProfileEntry.maxLines {
            return .failure(EditProblem(line: WatchmanSettingsCopy.profileTooLong(lines: lines.count)))
        }
        return .success(lines.joined(separator: "\n"))
    }

    /// The form's line for a pattern the CLI would refuse; nil when it may go.
    static func limitProblem(kind: WatchmanLimitKind, pattern: String) -> String? {
        if pattern.isEmpty { return WatchmanSettingsCopy.limitEmptyPattern }
        if pattern.contains(where: \.isNewline) { return WatchmanSettingsCopy.limitOneLine }
        if kind == .tool, pattern.contains(where: \.isWhitespace) { return WatchmanSettingsCopy.limitToolBlanks }
        return nil
    }

    // MARK: - Private

    private func apply() {
        guard let status = lastStatus else { return }
        state = .of(status, learningHere: learningHere, backtestHere: backtestHere)
    }

    /// Runs an owner verb: its stdout and, unless it succeeded, its error
    /// line (`"busy"` when the Watchman lock is held). A verb that calls a
    /// model (`learn`, `backtest`: `ModelCommands`) names its origin;
    /// `stdin` is an owner's text read from `-`.
    private func call(
        _ args: [String], origin: CLIOrigin? = nil, stdin: Data? = nil, timeout: TimeInterval
    ) async -> (failure: String?, stdout: Data) {
        do {
            let result = if let origin {
                try await runner.captureModel(args: args, origin: origin, timeout: timeout)
            } else if let stdin {
                try await runner.capture(args: args, stdin: stdin, timeout: timeout)
            } else {
                try await runner.capture(args: args, timeout: timeout)
            }
            if let error = Self.replyError(result.stdout) { return (error, result.stdout) }
            guard result.exitCode != 0 else { return (nil, result.stdout) }
            let line = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init)
            return (line ?? (result.exitCode == -1 ? "timed out" : "exit code \(result.exitCode)"), result.stdout)
        } catch {
            return (Self.message(error), Data())
        }
    }

    /// The backtest reply names its row (`backtest_id`/`status`): the run
    /// started, so its outcome is the row's.
    private static func hasBacktestRow(_ data: Data) -> Bool {
        struct Reply: Decodable {
            let backtestID: Int64?
            let status: String?

            enum CodingKeys: String, CodingKey {
                case status
                case backtestID = "backtest_id"
            }
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return false }
        return (reply.backtestID ?? 0) > 0 || !(reply.status ?? "").isEmpty
    }

    /// The `error` of a `{"ok":false,"error":…}` reply; nil for any other.
    private static func replyError(_ data: Data) -> String? {
        struct Reply: Decodable {
            let ok: Bool
            let error: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.ok else { return nil }
        return reply.error.flatMap { $0.isEmpty ? nil : $0 } ?? "failed"
    }

    private static func message(_ error: Error) -> String {
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init)
            return line ?? (code == -1 ? "timed out" : "exit code \(code)")
        }
        return SessionReportCenter.errorLine(error)
    }
}

/// The arm or instruction sheet of one control: the scope it arms (or
/// whose instruction it edits) and what it shows.
struct WatchmanArmSheetRequest: Identifiable, Equatable {
    let scope: WatchmanArmScope
    /// The sessions the check covered: the set the owner confirms.
    let sessions: [Int64]
    /// The field's text when the sheet opens: the scope's stored
    /// instruction ("" for the tray, or none known), or the tray's typed
    /// text when the running set changed.
    let instruction: String
    /// The scope's stored instruction as read when the sheet opened; nil
    /// when it could not be read and the app saw none: an empty field then
    /// never clears it.
    let stored: String?
    let content: WatchmanArmSheetContent
    /// Unique per presented sheet: a confirm acts only on the sheet it was
    /// pressed on.
    let token = UUID()
    var id: UUID { token }
}
