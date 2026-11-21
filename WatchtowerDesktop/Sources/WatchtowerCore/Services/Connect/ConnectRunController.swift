import Foundation
import Observation
import WatchtowerInterface

/// A card in the connect panel only the customer can answer (spec §5.3).
package enum ConnectPendingCard: Equatable, Sendable {
    /// The secure field: `kind` names where the value goes, `label` is the agent's.
    case secret(kind: String, label: String)
    case confirm(ConnectAssistantConfirm)
}

/// The rules of one connect assistant run (agent connect spec §5.3, §5.4,
/// §8): turns each tool call that reaches the run's socket into a decision —
/// run it on the service's driver, refuse it, hold it behind a card the
/// customer must press, or answer `waiting`/`timeout`.
///
/// - At most `maxStarts` `connect_start` calls per run, one flow at a time,
///   the policy checked before the driver.
/// - A call that waits on the customer or a flow (`connect_wait`,
///   `request_secret`, a confirm-gated call, `company_check`) is held at most
///   `callBudget` (`ConnectWire.waitBudget`), then answers
///   `{"state":"waiting"}`; the agent's next call re-attaches to the same
///   step. One step waits at most `maxWaitPerStep` over at most
///   `maxCallsPerStep` calls, then answers `{"state":"timeout"}`, drops its
///   card and fails the run with `.timedOut` — except the wait on a flow
///   that left the status while a newer start is underway, which ends alone.
/// - No tool call resolves a card: only `answerConfirm`, `sendSecret` and
///   `cancelSecret`, which the panel calls.
/// - A secret goes from `sendSecret` straight to the driver; nothing here
///   keeps, logs or returns it.
@MainActor
@Observable
package final class ConnectRunController {
    package static let maxStarts = 5
    package static let maxWaitPerStep: Duration = .seconds(900)
    /// 15 minutes of 45-s calls.
    package static let maxCallsPerStep = 20
    /// The company Publish's token card (spec §5.4).
    package static let publishTokenKind = "slack_config_token"
    package static let publishTokenLabel = "Slack configuration access token"
    /// What the customer is waiting on, after "Waiting for you to ".
    package static let flowWaitStep = "finish signing in in your browser"
    package static let checkWaitStep = "approve the sign-in in your browser"
    /// How long a held `connect_wait` pauses before asking the driver again
    /// after the driver answered `.waiting` early.
    package static let repollPause: Duration = .seconds(1)

    package private(set) var pendingCard: ConnectPendingCard?
    package private(set) var startsUsed = 0
    package private(set) var failure: ConnectAssistantFailure?
    /// The flow this run started (or adopted from `connect_status` after a reopen).
    package private(set) var activeFlow: String?
    private var waitingStep: String?
    private var busyShown = false
    private var connectedAccounts: Int?
    private var ended = false
    private var flowStarting = false

    private let driver: any ConnectServiceDriving
    private let callBudget: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let elapsed: @Sendable () -> Duration
    @ObservationIgnored private var cardStep: Step?
    @ObservationIgnored private var flowStep: Step?
    @ObservationIgnored private var checkStep: Step?

    package init(
        driver: any ConnectServiceDriving,
        clock: some Clock<Duration> = ContinuousClock(),
        callBudget: Duration = ConnectWire.waitBudget
    ) {
        self.driver = driver
        self.callBudget = callBudget
        let origin = clock.now
        sleep = { try await clock.sleep(for: $0) }
        elapsed = { origin.duration(to: clock.now) }
    }

    /// What the panel shows.
    package var state: ConnectAssistantState {
        if let failure { return .failed(failure) }
        switch pendingCard {
        case let .secret(_, label): return .secret(label: label)
        case let .confirm(confirm): return .confirm(confirm)
        case nil: break
        }
        if let waitingStep { return .waiting(step: waitingStep) }
        if busyShown { return .busy }
        if let connectedAccounts { return .done(accounts: connectedAccounts, noun: Self.noun(driver.service)) }
        return .thinking
    }

    package static func noun(_ service: String) -> ConnectAssistantAccountNoun {
        switch service {
        case "slack": .workspace
        case "jira": .site
        default: .account
        }
    }

    // MARK: - Panel

    /// The customer's answer to the confirm card. Called only by the panel.
    package func answerConfirm(_ yes: Bool) {
        guard let step = cardStep, case .confirm = pendingCard else { return }
        pendingCard = nil
        guard yes else { return finish(step, .result(Self.json(ConnectPending(state: "declined")))) }
        switch step.purpose {
        case let .start(options):
            // A flow may have appeared while the card was open (adopted by
            // connect_wait): no second flow, no counted start.
            guard activeFlow == nil, !flowStarting, startsUsed < Self.maxStarts else {
                return finish(step, .error(.busy, "a \(driver.service) sign-in is already running"))
            }
            startsUsed += 1
            flowStarting = true
            step.work = Task { [weak self, driver] in
                let result = await driver.start(options: options)
                self?.started(result, step: step)
            }
        case .publish:
            step.resetBudget()
            pendingCard = .secret(kind: Self.publishTokenKind, label: Self.publishTokenLabel)
        case .replaceCheck:
            guard let company = driver as? any ConnectCompanyDriving, let vendor = step.vendor else { return }
            cardStep = nil
            step.resetBudget()
            runCheck(step, vendor: vendor, company: company)
        case .secret, .flow, .check:
            break
        }
    }

    /// The secret card's value. Called only by the panel; the value goes to
    /// the driver and is kept nowhere.
    package func sendSecret(_ value: String) {
        guard let step = cardStep, case let .secret(kind, _) = pendingCard else { return }
        pendingCard = nil
        let driver = driver
        if case .publish = step.purpose, let company = driver as? any ConnectCompanyDriving {
            step.work = Task { [weak self] in
                let reply = Self.reply(await company.publish(token: value))
                self?.finish(step, reply)
            }
        } else {
            step.work = Task { [weak self] in
                let reply = Self.sent(await driver.submitSecret(kind: kind, value: value))
                self?.finish(step, reply)
            }
        }
    }

    /// The customer closed the secret card without sending.
    package func cancelSecret() {
        guard let step = cardStep, case .secret = pendingCard else { return }
        pendingCard = nil
        finish(step, .result(Self.json(ConnectPending(state: "cancelled"))))
    }

    /// The run is over (panel closed, app quitting): the card goes, every held
    /// call answers `closed`, later calls too. A running flow keeps today's
    /// behaviour (spec §8): nothing on the driver is cancelled.
    package func end() {
        ended = true
        pendingCard = nil
        waitingStep = nil
        flowStep?.work?.cancel()  // only the wait on the flow, never the flow
        for step in [cardStep, flowStep, checkStep].compactMap(\.self) {
            step.wakeAll(.closed)
        }
        cardStep = nil
        flowStep = nil
        checkStep = nil
    }

    // MARK: - Calls

    package func handle(_ req: ConnectWireRequest) async -> ConnectWireResponse {
        await reply(to: req).response(req.id)
    }

    private func reply(to req: ConnectWireRequest) async -> Reply {
        guard !ended else { return Self.closed }
        // After a timeout the panel shows the error with Retry (a fresh
        // run); no call may open a new card or wait behind it.
        guard failure == nil || !Self.stepTools.contains(req.tool) else { return Self.stopped }
        guard let args = (try? JSONSerialization.jsonObject(with: req.args)) as? [String: Any] else {
            return .error(.badArgs, "the arguments are not a JSON object")
        }
        switch req.tool {
        case "connect_status": return await status()
        case "connect_start": return await start(args)
        case "connect_wait": return await waitOnFlow()
        case "connect_cancel": return await cancelFlow()
        case "request_secret": return await requestSecret(args)
        case "set_fields": return await setFields(args)
        case "choose": return await choose(args)
        case "company_draft", "company_check", "company_publish":
            guard let company = driver as? any ConnectCompanyDriving else { return unknownTool(req.tool) }
            return await companyCall(req.tool, args, company)
        case "slack_live_probe": return await liveProbe(args)
        default: return unknownTool(req.tool)
        }
    }

    private func status() async -> Reply {
        let before = activeFlow
        let status = await driver.status()
        // A flow the status no longer shows has ended outside this run. Only
        // the flow the snapshot was taken for: a start that finished during
        // the await is newer than the snapshot.
        if let before, activeFlow == before, status.flow?.id != before, !ended { forgetFlow(before) }
        return Self.result(status)
    }

    private func liveProbe(_ args: [String: Any]) async -> Reply {
        guard let prober = driver as? any ConnectLiveProbing else { return unknownTool("slack_live_probe") }
        guard let provider = args["provider"] as? String, ["claude", "codex"].contains(provider) else {
            return .error(.badArgs, "provider must be claude or codex")
        }
        return Self.reply(await prober.liveProbe(provider: provider))
    }

    private func start(_ args: [String: Any]) async -> Reply {
        if let flowID = activeFlow, cardStep == nil, !flowStarting {
            // The flow may have ended outside this run's wait (cancelled in
            // another window): then it no longer makes this start busy.
            let current = await driver.status().flow?.id
            if let refusal = stoppedSince() { return refusal }
            if activeFlow == flowID, current != flowID { forgetFlow(flowID) }
        }
        if let step = cardStep {
            guard case .start = step.purpose else { return Self.cardOpen }
            return await attach(step)  // a re-call: never an answer to the card
        }
        guard driver.policyAllows() else { return .error(.policy, "your organization's policy blocks \(driver.service)") }
        guard let options = Self.strings(args) else { return .error(.badArgs, "connect_start options must be strings or booleans") }
        guard startsUsed < Self.maxStarts else { return .error(.limit, "this run has used its \(Self.maxStarts) sign-ins") }
        guard activeFlow == nil, !flowStarting else { return .error(.busy, "a \(driver.service) sign-in is already running") }
        if let confirm = driver.confirmNeeded(tool: "connect_start", options: options) {
            return await attach(showCard(.confirm(confirm), purpose: .start(options)))
        }
        startsUsed += 1
        flowStarting = true
        return startedReply(await driver.start(options: options))
    }

    private func started(_ result: Result<String, ConnectDriverError>, step: Step) {
        finish(step, startedReply(result))
    }

    private func startedReply(_ result: Result<String, ConnectDriverError>) -> Reply {
        flowStarting = false
        switch result {
        case let .success(flowID):
            if !ended {  // a start that lands after the run ended leaves the panel alone
                // The older flow is over for this run: its uncollected answer
                // goes, and calls still held on it are answered.
                if let old = flowStep {
                    if old.outcome == nil { retire(old, reason: "a newer sign-in replaced this one") }
                    flowStep = nil
                }
                activeFlow = flowID
                busyShown = false
                connectedAccounts = nil
            }
            return Self.result(ConnectStarted(flowID: flowID))
        case let .failure(error):
            if error == .busy, !ended { busyShown = true }
            return Self.reply(error)
        }
    }

    /// The status no longer shows the flow: it stops making starts busy.
    /// Leaving the status is no proof of failure (a sign-in that succeeded
    /// leaves it too), so its step stays and its own wait still answers the
    /// calls held on it; a newer start that succeeds retires that step.
    private func forgetFlow(_ flowID: String) {
        if activeFlow == flowID { activeFlow = nil }
    }

    /// Ends a flow step that no longer has a flow to wait on.
    private func retire(_ step: Step, reason: String) {
        step.work?.cancel()
        finish(step, Self.result(ConnectWaited(state: "failed", reason: reason)))
    }

    /// A flow step's cached answer, when it belongs to the flow a call now
    /// waits on (or no newer flow runs); an older flow's answer is dropped.
    private func cachedFlowAnswer() -> Step? {
        guard let step = flowStep, step.outcome != nil else { return nil }
        guard activeFlow == nil || activeFlow == step.flowID else {
            flowStep = nil
            return nil
        }
        return step
    }

    private func waitOnFlow() async -> Reply {
        // A flow that ended between two calls: its answer waits here.
        if let step = cachedFlowAnswer() { return await attach(step) }
        // An unfinished flow that left the status is still waited on: the
        // driver's wait reports how it ended.
        var waitFor = activeFlow ?? flowStep?.flowID
        if waitFor == nil {
            let adopted = await driver.status().flow?.id  // a reopened run resumes the flow it left
            if let refusal = stoppedSince() { return refusal }
            if let step = cachedFlowAnswer() { return await attach(step) }
            if activeFlow == nil, flowStep == nil { activeFlow = adopted }
            waitFor = activeFlow ?? flowStep?.flowID
        }
        guard let flowID = waitFor else { return .error(.failed, "no sign-in is running; call connect_start first") }
        let step: Step
        if let current = flowStep, current.flowID == flowID {
            step = current
        } else {
            if let old = flowStep, old.outcome == nil { retire(old, reason: "a newer sign-in replaced this one") }
            step = Step(purpose: .flow, flowID: flowID)
            flowStep = step
        }
        if step.outcome == nil { waitingStep = Self.flowWaitStep }
        if step.work == nil, step.outcome == nil {
            step.work = Task { [weak self, driver, sleep] in
                // The driver may answer `.waiting` early: while a call is
                // held on the step, ask it again after a short pause, so the
                // agent's re-calls (and the step's budget) stay 45 s apart.
                var outcome = await driver.wait(flowID: flowID)
                while outcome == .waiting, step.isHeld, !Task.isCancelled {
                    do { try await sleep(Self.repollPause) } catch { return }
                    outcome = await driver.wait(flowID: flowID)
                }
                await self?.flowWaited(outcome, step: step)
            }
        }
        return await attach(step)
    }

    /// The refusal for a call whose run ended or timed out while it awaited the driver.
    private func stoppedSince() -> Reply? {
        if ended { return Self.closed }
        return failure == nil ? nil : Self.stopped
    }

    private func flowWaited(_ outcome: ConnectWaitOutcome, step: Step) async {
        guard !Task.isCancelled, flowStep === step else { return }
        switch outcome {
        case .waiting:
            step.work = nil  // nobody is held: the next call asks the driver again
        case let .connected(account):
            if activeFlow == step.flowID { activeFlow = nil }
            finish(step, Self.result(ConnectWaited(state: "connected", account: account)))
            let accounts = await driver.status().accounts.count
            // A newer start since then owns the panel's state.
            if !ended, activeFlow == nil, !flowStarting { connectedAccounts = accounts }
        case let .failed(reason):
            if activeFlow == step.flowID { activeFlow = nil }
            finish(step, Self.result(ConnectWaited(state: "failed", reason: reason)))
        }
    }

    private func cancelFlow() async -> Reply {
        let leftStatus = flowStep  // a newer step made during the await is not this call's to retire
        let flowID: String? = if let activeFlow { activeFlow } else { await driver.status().flow?.id }
        guard let flowID else {
            // No flow runs any more, but a step may still wait on one that
            // left the status: the agent gave it up, so its held calls are
            // answered and the next connect_wait does not wait on it.
            if !ended, let step = leftStatus, step === flowStep, step.outcome == nil {
                retire(step, reason: "the sign-in was cancelled")
            }
            return Self.result(ConnectDone())
        }
        await driver.cancel(flowID: flowID)
        if activeFlow == flowID { activeFlow = nil }
        if let step = flowStep, step.flowID == flowID { retire(step, reason: "the sign-in was cancelled") }
        return Self.result(ConnectDone())
    }

    private func requestSecret(_ args: [String: Any]) async -> Reply {
        guard let kind = args["kind"] as? String, let label = args["label"] as? String,
              !label.isEmpty, label.count <= 80 else {
            return .error(.badArgs, "request_secret needs a kind and a label of at most 80 characters")
        }
        guard driver.secretKinds.contains(kind),
              !(driver is any ConnectCompanyDriving && kind == Self.publishTokenKind) else {
            return .error(.badArgs, "kind \(kind) is not a \(driver.service) secret")
        }
        if let step = cardStep {
            guard case .secret(kind) = step.purpose else { return Self.cardOpen }
            return await attach(step)
        }
        return await attach(showCard(.secret(kind: kind, label: label), purpose: .secret(kind)))
    }

    private func setFields(_ args: [String: Any]) async -> Reply {
        guard let fields = args as? [String: String] else { return .error(.badArgs, "set_fields values must be strings") }
        // A Quick Connection's `enable` is a connect_start option behind the
        // customer's confirm card, never a field (preflight F4).
        guard !fields.keys.contains(where: { $0.lowercased() == "enable" }) else {
            return .error(.badArgs, "enable is a connect_start option: the customer confirms it in the panel")
        }
        switch await driver.setFields(fields) {
        case .success: return Self.result(ConnectDone())
        case let .failure(error): return Self.reply(error)
        }
    }

    private func choose(_ args: [String: Any]) async -> Reply {
        guard let what = args["what"] as? String else { return .error(.badArgs, "choose needs what") }
        var select: [String]?
        if let raw = args["select"] {
            guard let ids = raw as? [String] else { return .error(.badArgs, "select must be a list of ids") }
            select = ids
        }
        switch await driver.choose(kind: what, select: select) {
        case let .success(items): return Self.result(ConnectChoices(items: items))
        case let .failure(error): return Self.reply(error)
        }
    }

    // MARK: - Company

    private func companyCall(_ tool: String, _ args: [String: Any], _ company: any ConnectCompanyDriving) async -> Reply {
        switch tool {
        case "company_draft":
            guard let rawFields = args["fields"] else { return Self.draftRead(company.draftView()) }
            guard let vendor = args["vendor"] as? String, let fields = rawFields as? [String: String] else {
                return .error(.badArgs, "company_draft save needs a vendor and string fields")
            }
            switch await company.saveDraft(vendor: vendor, fields: fields) {
            case .success: return Self.result(ConnectDone())
            case let .failure(error): return Self.reply(error)
            }
        case "company_check":
            guard let vendor = args["vendor"] as? String else { return .error(.badArgs, "company_check needs a vendor") }
            return await check(vendor, company)
        default:
            if let step = cardStep {
                guard case .publish = step.purpose else { return Self.cardOpen }
                return await attach(step)
            }
            guard let confirm = company.confirmNeeded(tool: "company_publish", options: [:]) else {
                return .error(.failed, "the company setup is not ready to publish")
            }
            return await attach(showCard(.confirm(confirm), purpose: .publish))
        }
    }

    /// The read, re-encoded through `ConnectCompanyDraft`: only the shape's
    /// keys leave, so a secret the driver's view carried is dropped.
    private static func draftRead(_ view: Data) -> Reply {
        guard let draft = try? JSONDecoder().decode(ConnectCompanyDraft.self, from: view) else {
            return .error(.failed, "the company draft could not be read")
        }
        return result(draft)
    }

    private func check(_ vendor: String, _ company: any ConnectCompanyDriving) async -> Reply {
        if let step = cardStep {
            guard case .replaceCheck = step.purpose, step.vendor == vendor else { return Self.cardOpen }
            return await attach(step)
        }
        if let current = checkStep {
            if current.vendor == vendor { return await attach(current) }
            // A finished check of another vendor, collected or not, does not block this one.
            guard current.outcome != nil else {
                return .error(.busy, "a \(current.vendor ?? "") check is still running")
            }
            checkStep = nil
        }
        // A check that would replace a stored company asks the customer first (spec §5.4).
        if let confirm = company.confirmNeeded(tool: "company_check", options: ["vendor": vendor]) {
            return await attach(showCard(.confirm(confirm), purpose: .replaceCheck, vendor: vendor))
        }
        let step = Step(purpose: .check, vendor: vendor)
        runCheck(step, vendor: vendor, company: company)
        return await attach(step)
    }

    private func runCheck(_ step: Step, vendor: String, company: any ConnectCompanyDriving) {
        checkStep = step
        waitingStep = Self.checkWaitStep
        step.work = Task { [weak self] in
            let reply = Self.reply(await company.check(vendor: vendor))
            guard let self, self.checkStep === step else { return }
            self.waitingStep = nil
            self.finish(step, reply)
        }
    }

    // MARK: - Steps

    private func showCard(_ card: ConnectPendingCard, purpose: Step.Purpose, vendor: String? = nil) -> Step {
        let step = Step(purpose: purpose, vendor: vendor)
        cardStep = step
        pendingCard = card
        return step
    }

    /// Sets the step's answer and wakes its held calls; an answer nobody is
    /// holding for waits for the agent's next call.
    private func finish(_ step: Step, _ reply: Reply) {
        guard step.outcome == nil else { return }
        step.outcome = reply
        if step === flowStep { waitingStep = nil }
        step.wakeAll(.resolved)
    }

    /// Hands the step's answer to one call and forgets the step.
    private func consume(_ step: Step) -> Reply? {
        guard let outcome = step.outcome else { return nil }
        if cardStep === step { cardStep = nil }
        if flowStep === step { flowStep = nil }
        if checkStep === step { checkStep = nil }
        return outcome
    }

    /// Holds the call on `step` for at most `callBudget`, within the step's
    /// own budget.
    private func attach(_ step: Step) async -> Reply {
        if let outcome = consume(step) { return outcome }
        guard step.calls < Self.maxCallsPerStep, step.spent < Self.maxWaitPerStep else { return await timeOut(step) }
        step.calls += 1
        let budget = min(callBudget, Self.maxWaitPerStep - step.spent)
        let from = elapsed()
        let wake = await step.hold(for: budget, sleep: sleep)
        step.addSpent(elapsed() - from)
        if ended { return Self.closed }  // the run ended while the call was held
        if let outcome = consume(step) { return outcome }
        switch wake {
        case .closed, .cancelled: return Self.closed
        case .resolved, .elapsed:
            if step.spent >= Self.maxWaitPerStep || step.calls >= Self.maxCallsPerStep { return await timeOut(step) }
            return .result(Self.json(ConnectPending(state: "waiting")))
        }
    }

    /// The step's 15 minutes are spent: its card goes, a flow it waited on
    /// is cancelled, and the run fails with `.timedOut` (Retry).
    private func timeOut(_ step: Step) async -> Reply {
        let reply = Reply.result(Self.json(ConnectPending(state: "timeout")))
        if step === flowStep, step.flowID != activeFlow, replacementStarting {
            // A flow that left the status runs out while a newer start is
            // underway: only its own wait ends; the run and the new start go on.
            step.work?.cancel()
            finish(step, reply)
            _ = consume(step)
            return reply
        }
        // The run shows the error with Retry: no card stays open behind it.
        pendingCard = nil
        if let card = cardStep, card !== step, card.work == nil {  // still unanswered
            finish(card, reply)
            _ = consume(card)
        }
        let abandonedFlow = step === flowStep ? step.flowID : nil
        if step === flowStep || step === checkStep {
            step.work?.cancel()
            waitingStep = nil
        }
        if let abandonedFlow, activeFlow == abandonedFlow { activeFlow = nil }
        failure = .timedOut
        finish(step, reply)
        _ = consume(step)
        if let abandonedFlow { await driver.cancel(flowID: abandonedFlow) }
        return reply
    }

    /// A `connect_start` is on the driver now, or behind a confirm card the
    /// customer has not answered yet (a declined or refused card that the
    /// agent has not collected starts nothing).
    private var replacementStarting: Bool {
        if flowStarting { return true }
        guard let card = cardStep, card.outcome == nil, case .start = card.purpose else { return false }
        return true
    }

    private func unknownTool(_ tool: String) -> Reply {
        .error(.unknownTool, "\(tool) is not a \(driver.service) tool")
    }

    // MARK: - Replies

    private static let closed = Reply.error(.closed, "the connect run has ended")
    private static let cardOpen = Reply.error(.busy, "the customer has a card open in the panel")
    private static let stopped = Reply.error(.closed, "this run stopped waiting; the customer can press Retry")
    /// The calls that open a card or wait on a step.
    private static let stepTools: Set<String> = [
        "connect_start", "connect_wait", "request_secret", "company_check", "company_publish"
    ]

    private static func json(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
    }

    private static func result(_ value: some Encodable) -> Reply {
        .result(json(value))
    }

    private static func reply(_ result: Result<Data, ConnectDriverError>) -> Reply {
        switch result {
        case let .success(data): .result(data)
        case let .failure(error): reply(error)
        }
    }

    /// `request_secret`'s answer: the verb's result, never the secret.
    private static func sent(_ result: Result<Data, ConnectDriverError>) -> Reply {
        switch result {
        case let .success(data):
            guard let raw = try? RawJSON(data: data) else {
                return .error(.failed, "the Watchtower app built an unreadable result")
            }
            return Self.result(ConnectSecretSent(state: "sent", result: raw))
        case let .failure(error):
            return reply(error)
        }
    }

    private static func reply(_ error: ConnectDriverError) -> Reply {
        switch error {
        case .busy: .error(.busy, "a sign-in of this service is already running")
        case .policy: .error(.policy, "your organization's policy blocks this")
        case let .failed(message): .error(.failed, message)
        case let .badArgs(message): .error(.badArgs, message)
        }
    }

    /// `connect_start` options as the driver takes them: strings as they
    /// are, booleans as "true"/"false"; anything else is refused.
    private static func strings(_ args: [String: Any]) -> [String: String]? {
        var out: [String: String] = [:]
        for (key, value) in args {
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                out[key] = number.boolValue ? "true" : "false"
            } else if let string = value as? String {
                out[key] = string
            } else {
                return nil
            }
        }
        return out
    }
}

/// A call's answer before it gets its request id.
private enum Reply {
    case result(Data)
    case error(ConnectWireError, String)

    func response(_ id: Int64) -> ConnectWireResponse {
        switch self {
        case let .result(data): .result(id: id, json: data)
        case let .error(code, message): ConnectWireResponse(id: id, error: code, message: message)
        }
    }
}

/// One step a call can wait on: a card, a flow or a company check. Its
/// budget counts every call held on it.
@MainActor
private final class Step {
    enum Purpose {
        case start([String: String])
        case secret(String)
        case publish
        case flow
        case check
        /// A company check behind the Replace confirm card.
        case replaceCheck
    }

    enum Wake { case resolved, elapsed, closed, cancelled }

    let purpose: Purpose
    let flowID: String?
    let vendor: String?
    var outcome: Reply?
    var work: Task<Void, Never>?
    private(set) var spent: Duration = .zero
    var calls = 0
    private var held: [Int: (CheckedContinuation<Wake, Never>, Task<Void, Never>)] = [:]
    private var nextKey = 0

    init(purpose: Purpose, flowID: String? = nil, vendor: String? = nil) {
        self.purpose = purpose
        self.flowID = flowID
        self.vendor = vendor
    }

    /// A call is held on the step right now.
    var isHeld: Bool { !held.isEmpty }

    func addSpent(_ duration: Duration) { spent += duration }

    func resetBudget() {
        spent = .zero
        calls = 0
    }

    /// Suspends until the step is woken, `budget` passes on the run's clock,
    /// or the calling task is cancelled.
    func hold(for budget: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) async -> Wake {
        let key = nextKey
        nextKey += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .cancelled) }
                let timer = Task { [weak self] in
                    do { try await sleep(budget) } catch { return }
                    self?.wake(key, .elapsed)
                }
                held[key] = (continuation, timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(key, .cancelled) }
        }
    }

    func wakeAll(_ wake: Wake) {
        for key in Array(held.keys) { self.wake(key, wake) }
    }

    private func wake(_ key: Int, _ wake: Wake) {
        guard let (continuation, timer) = held.removeValue(forKey: key) else { return }
        timer.cancel()
        continuation.resume(returning: wake)
    }
}
