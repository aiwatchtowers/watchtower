import Foundation
import Observation
import WatchtowerCore

/// What the Slack driver needs of `SlackAccountsViewModel`: the accounts it
/// lists and its built-in sign-in (`slack add --app-return`, the **Add
/// workspace** button). A seam so the driver's tests run without a database.
@MainActor
protocol SlackAccountsConnecting: AnyObject {
    var accounts: [SlackAccount] { get }
    var isConnecting: Bool { get }
    /// A `slack add`/`slack login` runs (not the Re-login route read).
    var isSigningIn: Bool { get }
    /// The serial of the newest sign-in run (bumped as each begins).
    var authRunSerial: Int { get }
    var error: String? { get }
    /// The last ended `slack add`/`slack login` run.
    var lastAuthRun: SlackAuthRun? { get }
    /// `builtin_app` of `slack accounts --json`: the build signs in through its own app.
    var builtinApp: Bool { get }
    func addAccount(daemonPolicy: DaemonRestartPolicy) async
    func cancelConnect()
    func refreshAsync() async
}

extension SlackAccountsViewModel: SlackAccountsConnecting {}

/// The connect assistant's Slack driver (agent connect spec §5.3; playbook
/// `docs/guide/connect/slack.md`). It runs each call on the models the
/// Connections → Slack buttons use, so it adds no writer of its own:
///
/// - `connect_start` with `code` (the connect link or code from the app's
///   About page) is the paste field's **Connect** on `SlackConnectFlowModel`
///   (the `slack connect serve` child, the Slack `Registry`'s one flow). The
///   panel's **Start** is the customer's press (SLACKFULL-01, ask #1721), so
///   the start skips the flow's confirm, as a pasted code does. With no
///   option it is the organization's first open `SlackApps` row, as the
///   connect section offers it, else the build's own **Add workspace**
///   (`slack add`).
/// - `connect_start` with `pkce` waits behind the `.slackPKCE` confirm card;
///   once confirmed, the next `slack_config_token` runs the update
///   (`slack app adopt --enable-pkce` through `SlackAppSetupModel`), which
///   opens no sign-in. Without that consent the token runs the create
///   (`slack app create`, then the admin's own connect and the link).
/// - The token reaches the CLI on stdin only (SLACKFULL-02,
///   `SlackAppSetupModel`); it is never kept here, logged or returned.
///
/// Flows live on this driver. A sign-in it did not start (a paste, a clicked
/// link, a Reconnect, **Add workspace**) gets its own id the first time
/// `status()` sees it; its end is read off the model it ran on.
@MainActor
@Observable
final class SlackConnectDriver: ConnectServiceDriving, ConnectLiveProbing {
    static let configTokenKind = "slack_config_token"
    static let startOptions: Set<String> = ["pkce", "code"]

    let service = "slack"
    let secretKinds: Set<String> = [configTokenKind]

    private enum Kind {
        /// Our start on the connect flow model, for this workspace app.
        case connect(SlackConnectTarget)
        /// Our `slack add` (the build's own app); its run is the one after
        /// `serialBefore`.
        case add(serialBefore: Int)
        /// A confirmed PKCE update: waits for the token, then the adopt runs.
        case update(running: Bool)
        /// A sign-in someone else started: on the connect flow, or a
        /// `slack add`/`slack login` run (`serial`, its `authRunSerial`).
        case foreign(onFlow: Bool, serial: Int)

        var isOurs: Bool {
            if case .foreign = self { false } else { true }
        }
    }

    private struct Flow {
        var kind: Kind
        var outcome: ConnectWaitOutcome?
        var cancelled = false
    }

    private var flows: [String: Flow] = [:]

    @ObservationIgnored private let accounts: any SlackAccountsConnecting
    @ObservationIgnored private let connectFlow: SlackConnectFlowModel?
    @ObservationIgnored private let setup: SlackAppSetupModel
    @ObservationIgnored private let policy: () -> ManagedPolicy
    @ObservationIgnored private let daemonPolicy: () -> DaemonRestartPolicy
    @ObservationIgnored private let runner: (any CLIRunnerProtocol)?
    /// After a Live probe: the Connections pane re-reads its verdicts.
    @ObservationIgnored private let onProbed: () async -> Void
    @ObservationIgnored private let makeFlowID: () -> String

    init(
        accounts: any SlackAccountsConnecting,
        connectFlow: SlackConnectFlowModel?,
        setup: SlackAppSetupModel,
        policy: @escaping () -> ManagedPolicy,
        daemonPolicy: @escaping () -> DaemonRestartPolicy = { .restart },
        runner: (any CLIRunnerProtocol)?,
        onProbed: @escaping () async -> Void = {},
        makeFlowID: @escaping () -> String = { "slack-" + UUID().uuidString.lowercased() }
    ) {
        self.accounts = accounts
        self.connectFlow = connectFlow
        self.setup = setup
        self.policy = policy
        self.daemonPolicy = daemonPolicy
        self.runner = runner
        self.onProbed = onProbed
        self.makeFlowID = makeFlowID
    }

    // MARK: - Status

    func status() async -> ConnectStatus {
        await accounts.refreshAsync()
        await setup.reloadRecords()  // a failed read keeps the last records
        let live = accounts.accounts.filter { !$0.isGone }
        return ConnectStatus(
            service: service,
            accounts: live.map { ConnectStatus.Account(name: $0.displayName, status: $0.status) },
            policyLocked: !policyAllows(),
            flow: currentFlow(),
            setup: setupStage.map(ConnectStatus.Setup.init(stage:)))
    }

    /// Our running flow, else the sign-in someone else runs (its id minted
    /// the first time it is seen).
    private func currentFlow() -> ConnectStatus.Flow? {
        if let active = activeFlow {
            return ConnectStatus.Flow(id: active.id, state: Self.state(active.flow.kind, connectFlow?.step))
        }
        guard let state = foreignState else { return nil }
        return ConnectStatus.Flow(id: foreignFlowID(), state: state)
    }

    private static func state(_ kind: Kind, _ step: SlackConnectFlowModel.Step?) -> String {
        switch kind {
        case .connect, .foreign: if case .browser = step { "browser" } else { "starting" }
        case .add: "browser"
        case let .update(running): running ? "updating" : "waiting_for_token"
        }
    }

    /// A sign-in this driver did not start: the connect flow (a clicked link,
    /// a Reconnect, a paste) or `slack add`. The setup's own admin connect is
    /// the setup's (`setup` stage `running`).
    private var foreignState: String? {
        guard !setup.isRunning, activeFlow == nil else { return nil }
        if let flow = connectFlow, flow.isRunning {
            return switch flow.step {
            case .confirming: "confirming"
            case .browser: "browser"
            default: "starting"
            }
        }
        return accounts.isSigningIn ? "browser" : nil
    }

    /// The running foreign sign-in's id: the one already watched, else a new
    /// one, watched until that sign-in ends.
    private func foreignFlowID() -> String {
        let onFlow = connectFlow?.isRunning == true
        // A sign-in run is one attempt: a newer run (serial) is a new id.
        let serial = onFlow ? 0 : accounts.authRunSerial
        if let watched = flows.first(where: { flow in
            guard case let .foreign(watchedOnFlow, watchedSerial) = flow.value.kind, flow.value.outcome == nil else { return false }
            return watchedOnFlow == onFlow && watchedSerial == serial
        }) {
            return watched.key
        }
        let id = begin(.foreign(onFlow: onFlow, serial: serial))
        let before = Set(accounts.accounts.map(\.id))
        Task { [weak self] in
            await ObservedWait { [weak self] in self?.foreignRunning(onFlow: onFlow, serial: serial) != true }.wait()
            await self?.foreignEnded(id, onFlow: onFlow, serial: serial, before: before)
        }
        return id
    }

    /// Whether that attempt still runs: the connect flow, or the sign-in run
    /// with that serial (it has ended once its end, or a later one, is recorded).
    private func foreignRunning(onFlow: Bool, serial: Int) -> Bool {
        if onFlow { return connectFlow?.isRunning == true }
        return (accounts.lastAuthRun?.serial ?? 0) < serial
    }

    private func foreignEnded(_ id: String, onFlow: Bool, serial: Int, before: Set<Int>) async {
        guard let flow = flows[id], flow.outcome == nil else { return }
        let outcome: ConnectWaitOutcome
        if onFlow, let step = connectFlow?.step {
            outcome = Self.outcome(step, cancelled: flow.cancelled)
        } else {
            let run = accounts.lastAuthRun
            outcome = await authOutcome(run?.serial == serial ? run?.end : nil, before: before, cancelled: flow.cancelled)
        }
        guard flows[id]?.outcome == nil else { return }
        flows[id]?.outcome = outcome
    }

    /// The setup's stage folded into one: `running` while a create or update
    /// runs, else the least finished record's (`pending_create`, `install`,
    /// `approval`, `link_missing`), `done` when every record is, nil with none.
    private var setupStage: String? {
        if setup.isRunning { return "running" }
        let order = ["pending_create", "install", "approval", "link_missing"]
        for stage in order where setup.records.contains(where: { $0.stage == stage }) {
            return stage
        }
        return setup.records.isEmpty ? nil : "done"
    }

    // MARK: - Start

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        guard policyAllows() else { return .failure(.policy) }
        if let unknown = options.keys.sorted().first(where: { !Self.startOptions.contains($0) }) {
            return .failure(.badArgs("Slack's connect_start takes pkce or code, not \(unknown)"))
        }
        let code = options["code"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pkce = Self.isOn(options["pkce"])
        if pkce, !code.isEmpty { return .failure(.badArgs("pkce updates the app and code connects an account: pick one")) }
        guard !busy else { return .failure(.busy) }
        if pkce {
            // Confirmed by the customer (`confirmNeeded`): the token comes next.
            return .success(begin(.update(running: false)))
        }
        if !code.isEmpty {
            guard let target = SlackConnectTarget.parse(code) else {
                return .failure(.badArgs(SlackConnectFlowModel.pasteInvalid))
            }
            return startConnect(target)
        }
        if let target = openOrganizationApp { return startConnect(target) }
        guard accounts.builtinApp else {
            return .failure(.badArgs("Slack needs option code: the connect link or code from the About tab of "
                + "the workspace's Watchtower app"))
        }
        return .success(startAdd())
    }

    /// Any Slack sign-in, setup or confirmed update running here or elsewhere in the app.
    private var busy: Bool {
        if activeFlow != nil { return true }
        if accounts.isConnecting || setup.isRunning { return true }
        guard let flow = connectFlow else { return false }
        return !flow.canStart || flow.companyRunning()
    }

    /// The connect section's first `SlackApps` (MDM) row: an app the
    /// organization set up whose workspace is not connected through it yet.
    private var openOrganizationApp: SlackConnectTarget? {
        let live = accounts.accounts.filter { !$0.isGone }
        let open = (policy().slackApps ?? []).first { app in
            !live.contains { $0.teamID == app.teamID && $0.clientID == app.clientID }
        }
        return open.map { SlackConnectTarget(teamID: $0.teamID, clientID: $0.clientID) }
    }

    /// The flow this driver started and runs now (one at a time).
    private var activeFlow: (id: String, flow: Flow)? {
        flows.first { $0.value.kind.isOurs && $0.value.outcome == nil }.map { ($0.key, $0.value) }
    }

    private func begin(_ kind: Kind) -> String {
        let id = makeFlowID()
        flows[id] = Flow(kind: kind)
        return id
    }

    private func startConnect(_ target: SlackConnectTarget) -> Result<String, ConnectDriverError> {
        guard let flow = connectFlow else { return .failure(.failed(Self.listenerMissing)) }
        // The panel shows this run, so no flow sheet goes up over it.
        guard flow.start(target, byAssistant: true) else { return .failure(.busy) }
        let id = begin(.connect(target))
        Task { [weak self] in
            // `isRunning` stays true after a Cancel until the child answers
            // the start (observed: `cancelAfterStart`).
            await ObservedWait { !flow.isRunning }.wait()
            self?.connectEnded(id, step: flow.step)
            // The result is the panel's to show: no sheet waits for its Done.
            if flow.startedByAssistant { flow.dismiss() }
        }
        return .success(id)
    }

    private func connectEnded(_ id: String, step: SlackConnectFlowModel.Step) {
        guard let flow = flows[id], flow.outcome == nil else { return }
        flows[id]?.outcome = Self.outcome(step, cancelled: flow.cancelled)
    }

    /// How a connect flow ended, read off the step it left.
    private static func outcome(_ step: SlackConnectFlowModel.Step, cancelled: Bool) -> ConnectWaitOutcome {
        switch step {
        case let .connected(workspace): .connected(account: workspace)
        case .failed: .failed(reason: SlackConnectSheetContent(step: step)?.body ?? signInFailed)
        default: .failed(reason: cancelled ? Self.cancelled : signInEnded)
        }
    }

    private func startAdd() -> String {
        let serialBefore = accounts.authRunSerial
        let id = begin(.add(serialBefore: serialBefore))
        let before = Set(accounts.accounts.map(\.id))
        Task { [weak self, accounts, daemonPolicy] in
            await accounts.addAccount(daemonPolicy: daemonPolicy())
            // One sign-in at a time (`busy`): a run that ended since is this
            // one; none (the CLI missing) leaves `error`.
            guard let self, let flow = flows[id], flow.outcome == nil else { return }
            let run = accounts.lastAuthRun.flatMap { $0.serial == serialBefore + 1 ? $0 : nil }
            let outcome = await authOutcome(run?.end, before: before, cancelled: flow.cancelled)
            guard flows[id]?.outcome == nil else { return }
            flows[id]?.outcome = outcome
        }
        return id
    }

    /// How a sign-in run ended: connected only on a success, naming the
    /// account it added (a live row not in `before`, read after a refresh)
    /// or the one a `slack login` re-bound; otherwise failed.
    private func authOutcome(_ end: SlackAuthRunEnd?, before: Set<Int>, cancelled: Bool) async -> ConnectWaitOutcome {
        switch end {
        case let .succeeded(accountID):
            await accounts.refreshAsync()  // the VM's own reload is fire-and-forget
            let rows = accounts.accounts
            // The account the run names (Re-login's, or the one `slack add` printed) wins.
            if let accountID {
                return rows.first { $0.id == accountID }.map { .connected(account: $0.displayName) }
                    ?? .failed(reason: Self.signInEnded)
            }
            // Else the newest row not there before (`slack add` may seed the legacy account #1 first).
            let added = rows.filter { !before.contains($0.id) && !$0.isGone }.max { $0.id < $1.id }
            return added.map { .connected(account: $0.displayName) } ?? .failed(reason: Self.signInEnded)
        case .cancelled:
            return .failed(reason: Self.cancelled)
        case let .failed(message):
            return .failed(reason: message)
        case nil:
            return .failed(reason: cancelled ? Self.cancelled : (accounts.error ?? Self.signInEnded))
        }
    }

    // MARK: - Wait and cancel

    func wait(flowID: String) async -> ConnectWaitOutcome {
        guard let flow = flows[flowID] else { return .failed(reason: Self.unknownFlow) }
        if let outcome = flow.outcome { return outcome }
        await ObservedWait { [weak self] in self?.flows[flowID]?.outcome != nil }.wait()
        return flows[flowID]?.outcome ?? .waiting
    }

    /// The run ended (panel closed) while a sign-in it started still runs:
    /// the flow goes on as today's (spec §8), so its sheet and **Cancel**
    /// show again. A reopened panel still finds it through `status`/`wait`.
    func runEnded() {
        guard let flow = connectFlow, flow.startedByAssistant, flow.isRunning else { return }
        flow.handToSheet()
    }

    func cancel(flowID: String) async {
        guard let flow = flows[flowID], flow.outcome == nil else { return }
        switch flow.kind {
        case let .connect(target):
            // Only while the flow model still runs this start.
            guard let model = connectFlow, model.isRunning, Self.target(of: model.step) == target else { return }
            flows[flowID]?.cancelled = true
            model.cancel()
        case let .add(serialBefore):
            // Only our own run: a newer sign-in from the sheet is not ours to cancel.
            guard accounts.isSigningIn, accounts.authRunSerial == serialBefore + 1 else { return }
            flows[flowID]?.cancelled = true
            accounts.cancelConnect()
        case .update(running: false):
            flows[flowID]?.outcome = .failed(reason: Self.cancelled)
        case .update(running: true):
            break  // the update runs to its end: Slack's side may already have changed
        case let .foreign(onFlow, serial):
            guard foreignRunning(onFlow: onFlow, serial: serial), onFlow || accounts.authRunSerial == serial else { return }
            flows[flowID]?.cancelled = true
            if onFlow { connectFlow?.cancel() } else { accounts.cancelConnect() }
        }
    }

    /// The app a running step works on; nil off a running step.
    private static func target(of step: SlackConnectFlowModel.Step) -> SlackConnectTarget? {
        switch step {
        case let .starting(target), let .browser(_, target, _), let .confirming(_, target): target
        case .idle, .connected, .failed: nil
        }
    }

    // MARK: - The configuration token

    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        guard kind == Self.configTokenKind else { return .failure(.badArgs("kind \(kind) is not a Slack secret")) }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.badArgs("the configuration token is empty")) }
        guard policyAllows() else { return .failure(.policy) }
        guard !setup.isRunning else { return .failure(.busy) }
        if let active = activeFlow, case .update(running: false) = active.flow.kind {
            let updateID = active.id
            flows[updateID]?.kind = .update(running: true)
            setup.prepareUpdate()
            setup.startAdopt(token: token, appID: nil)
            var result = await finishRun()
            let outcome = await updateOutcome(result)
            if result.result == "ok" {
                // The update signs nobody in: connected only when an account
                // of the workspace already is.
                let connected = if case .connected = outcome { true } else { false }
                result.connected = connected
                result.message = connected ? Self.updated : Self.updatedNotConnected
            }
            flows[updateID]?.outcome = outcome
            return .success(Self.json(result))
        }
        // The create's admin connect needs the connect flow free.
        guard !busy else { return .failure(.busy) }
        setup.startCreate(token: token)
        return .success(Self.json(await finishRun()))
    }

    /// Waits for the run `startCreate`/`startAdopt` began and reads how it ended.
    private func finishRun() async -> SlackConfigTokenResult {
        guard setup.isRunning else {
            return SlackConfigTokenResult(result: "stopped", message: "The setup did not start. Try again.")
        }
        await ObservedWait { [setup] in !setup.isRunning }.wait()
        guard !setup.isRunning else {
            return SlackConfigTokenResult(result: "running", message: "The setup goes on; Connections → Slack shows how it ends.")
        }
        return SlackConfigTokenResult(phase: setup.phase, form: setup.form, model: setup)
    }

    /// The confirmed update's flow end: connected only when an account of
    /// the updated workspace is; the update itself signs nobody in.
    private func updateOutcome(_ result: SlackConfigTokenResult) async -> ConnectWaitOutcome {
        guard result.result == "ok" else { return .failed(reason: result.message) }
        await accounts.refreshAsync()
        // An account through this very app (team and client id), not removed or revoked.
        if let account = accounts.accounts.first(where: {
            !$0.isGone && !$0.isRevoked && !result.teamID.isEmpty
                && $0.teamID == result.teamID && $0.clientID == result.clientID
        }) {
            return .connected(account: account.displayName)
        }
        return .failed(reason: Self.updatedNotConnected)
    }

    // MARK: - The rest of the protocol

    func setFields(_: [String: String]) async -> Result<Void, ConnectDriverError> {
        .failure(.badArgs("Slack takes no fields"))
    }

    func choose(kind _: String, select _: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        .failure(.badArgs("Slack has nothing to choose"))
    }

    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        tool == "connect_start" && Self.isOn(options["pkce"]) ? .slackPKCE : nil
    }

    func policyAllows() -> Bool {
        PolicySourceMap.allowed(service, policy: policy())
    }

    // MARK: - Slack Live

    func liveProbe(provider: String) async -> Result<Data, ConnectDriverError> {
        guard let runner else { return .failure(.failed(CLIRunnerError.binaryNotFound.localizedDescription)) }
        let out: Data
        do {
            // `slack live probe` refuses a provider it does not know (LLMTRANSPORT-01).
            out = try await runner.run(args: ["slack", "live", "probe", "--provider", provider, "--json"], timeout: 150)
        } catch CLIRunnerError.nonZeroExit(_, let stderr) {
            let reason = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(reason.isEmpty ? "the Slack Live check failed" : String(reason.prefix(300))))
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        await onProbed()
        guard let object = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let row = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return .failure(.failed("the Slack Live check gave no result"))
        }
        return .success(row)
    }

    // MARK: - Helpers

    /// A `pkce` option's value: on unless "false" or "0".
    private static func isOn(_ value: String?) -> Bool {
        guard let value else { return false }
        return !["false", "0"].contains(value.lowercased())
    }

    private static func json(_ result: SlackConfigTokenResult) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(result)) ?? Data(#"{"result":"failed"}"#.utf8)
    }

    static let cancelled = "the sign-in was cancelled"
    static let unknownFlow = "this Slack sign-in is no longer running; call connect_status"
    static let signInEnded = "the Slack sign-in ended without connecting"
    static let signInFailed = "Slack did not finish the sign-in"
    static let listenerMissing = "Watchtower's connect listener is not running; reopen Connections → Slack and try again"
    static let updated = "The app is updated, and your account in this workspace is connected through it."
    static let updatedNotConnected = "The app is updated, but no account of yours is connected through it yet. "
        + "Connect through the app's connect link or code."
}

/// The `slack_config_token` result: how the create or update ended, as
/// `docs/guide/connect/slack.md` steps 9 and 14 branch on it. `result`:
/// `ok` (connected, the link on the About page), `link_failed` (connected,
/// no link), `approval` (an admin must approve the install), `not_connected`
/// (the app exists, the owner is not connected), `existing_app` (the
/// workspace has Watchtower's app: update it with `pkce`), `need_app_id`,
/// `confirm_app`, `pending_create`, `builtin_app_deferred`, or a problem's
/// code (`bad_token`, `not_allowed`, `not_collaborator`, …). Never the token.
struct SlackConfigTokenResult: Encodable, Equatable {
    var result: String
    var workspace: String?
    var teamID = ""
    var clientID = ""
    var appID: String?
    /// Absent (null) when the outcome says nothing about it.
    var connected: Bool? // swiftlint:disable:this discouraged_optional_boolean
    var linkWritten: Bool? // swiftlint:disable:this discouraged_optional_boolean
    var message: String

    private enum CodingKeys: String, CodingKey {
        case result, workspace, connected, message
        case teamID = "team_id", clientID = "client_id", appID = "app_id", linkWritten = "link_written"
    }

    init(result: String, message: String) {
        self.result = result
        self.message = message
    }

    @MainActor
    init(phase: SlackAppSetupModel.Phase, form: SlackAppSetupModel.Form, model: SlackAppSetupModel) {
        switch phase {
        case let .finished(outcome):
            self.init(outcome, model: model)
        case .editing:
            // A run that ended on a form: the sheet would ask for more.
            switch form {
            case let .adopt(adopt) where adopt.confirm != nil:
                self.init(result: "confirm_app", message: Self.byHand)
                set(adopt.target)
            case let .adopt(adopt) where adopt.needsAppID:
                self.init(result: "need_app_id", message: "Watchtower needs the app's App ID. " + Self.byHand)
                set(adopt.target)
            case let .adopt(adopt):
                self.init(result: "existing_app", message: "The workspace already has Watchtower's app: update it "
                    + "(connect_start with pkce) instead of creating one.")
                set(adopt.target)
            case let .pending(target):
                self.init(result: "pending_create", message: SlackAppSetupModel.pendingBody(target.workspace))
                set(target)
            case .create, .addLink:
                self.init(result: "stopped", message: Self.byHand)
            }
        case .running:
            self.init(result: "running", message: "The setup goes on; Connections → Slack shows how it ends.")
        }
    }

    @MainActor
    private init(_ outcome: SlackAppSetupModel.Outcome, model: SlackAppSetupModel) {
        switch outcome {
        case let .success(target):
            self.init(result: "ok", message: SlackAppSetupModel.successBody)
            set(target, connected: true)
        case let .linkFailed(target):
            self.init(result: "link_failed", message: SlackAppSetupModel.linkFailedBody)
            set(target, connected: true)
        case let .approval(target):
            self.init(result: "approval", message: SlackAppSetupModel.approvalBody)
            set(target, connected: false)
        case let .notConnected(target):
            self.init(result: "not_connected", message: SlackAppSetupModel.installLine(target.workspace))
            set(target, connected: false)
        case .linkDone:
            self.init(result: "ok", message: SlackAppSetupModel.linkDoneBody)
            linkWritten = true
        case let .builtinAppDeferred(workspace):
            self.init(result: "builtin_app_deferred", message: SlackAppSetupModel.builtinAppDeferredBody(workspace))
            self.workspace = workspace
        case let .problem(problem):
            self.init(result: Self.code(problem), message: model.problemLine(problem))
        }
    }

    private mutating func set(_ target: SlackSetupTarget, connected: Bool? = nil) { // swiftlint:disable:this discouraged_optional_boolean
        workspace = target.workspace.isEmpty ? nil : target.workspace
        teamID = target.teamID
        clientID = target.clientID
        appID = target.appID.isEmpty ? nil : target.appID
        linkWritten = target.linkWritten
        self.connected = connected
    }

    private static let byHand = "Use Set up by hand in the assistant's panel."

    // swiftlint:disable:next cyclomatic_complexity
    private static func code(_ problem: SlackAppSetupModel.Problem) -> String {
        switch problem {
        case .badToken: "bad_token"
        case .notAllowed: "not_allowed"
        case .notCollaborator: "not_collaborator"
        case .network: "network"
        case .refused: "refused"
        case .busy: "busy"
        case .storage: "storage"
        case .wrongTeam: "wrong_team"
        case .wrongWorkspace: "wrong_workspace"
        case .noRecord: "no_record"
        case .noApp: "no_app"
        case .idsRejected: "bad_ids"
        case .notPending: "no_pending"
        case .saveFailed: "save_failed"
        case .stopped: "stopped"
        case .unreadableAnswer: "unreadable_answer"
        }
    }
}

/// Waits until `condition` holds, re-checked on each change of the
/// `@Observable` state it reads, or until the waiting task is cancelled. No
/// clock: the wait ends on the event.
@MainActor
private final class ObservedWait {
    private let condition: @MainActor () -> Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ condition: @escaping @MainActor () -> Bool) {
        self.condition = condition
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.continuation = continuation
                if Task.isCancelled { resume() } else { check() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume() }
        }
    }

    private func check() {
        guard continuation != nil else { return }
        let met = withObservationTracking(condition) {
            Task { @MainActor [weak self] in self?.check() }
        }
        if met { resume() }
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }
}
