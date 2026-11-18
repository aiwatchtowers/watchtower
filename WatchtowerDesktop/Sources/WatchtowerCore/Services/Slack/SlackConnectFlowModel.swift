import Foundation
import Observation

/// What a connect flow connects: a workspace through a company's app.
/// `accountID` re-binds that account row (Reconnect); nil lets Go pick the
/// team's live row or a new one.
package struct SlackConnectTarget: Equatable, Sendable {
    package let teamID: String
    package let clientID: String
    package let accountID: Int64?

    package init(teamID: String, clientID: String, accountID: Int64? = nil) {
        self.teamID = teamID
        self.clientID = clientID
        self.accountID = accountID
    }

    /// The connect link or the `<team id>:<client id>` code, as Go's
    /// `slackconnect.ParseConnectInput` reads them (`TestParseConnectInput`):
    /// http only, host exactly `127.0.0.1:18551`, path `/slack/connect`, one
    /// `team` and one `client`, ids matching the plan's patterns. nil for
    /// anything else.
    package static func parse(_ text: String) -> Self? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("http://") || input.contains("/") { return parseLink(input) }
        guard let colon = input.firstIndex(of: ":") else { return nil }
        return valid(team: String(input[..<colon]), client: String(input[input.index(after: colon)...]))
    }

    private static func parseLink(_ input: String) -> Self? {
        guard let url = URLComponents(string: input),
              url.scheme == "http", url.user == nil, url.password == nil,
              url.host == "127.0.0.1", url.port == 18551, url.path == "/slack/connect",
              url.fragment == nil, let items = url.queryItems else { return nil }
        let teams = items.filter { $0.name == "team" }, clients = items.filter { $0.name == "client" }
        guard teams.count == 1, clients.count == 1,
              let team = teams[0].value, let client = clients[0].value else { return nil }
        return valid(team: team, client: client)
    }

    private static func valid(team: String, client: String) -> Self? {
        guard ManagedPolicy.isSlackTeamID(team), ManagedPolicy.isSlackClientID(client) else { return nil }
        return Self(teamID: team, clientID: client)
    }
}

/// `watchtower slack accounts --json` (plan B Task 3): what each account's
/// Re-login goes through. Removed rows are listed too.
package struct SlackAccountsDocument: Decodable, Equatable, Sendable {
    package struct Account: Decodable, Equatable, Sendable {
        package let id: Int64
        package let teamID: String
        package let clientID: String
        package let sharedApp: Bool
        /// "builtin" | "connect" | "move" (`slackmode.Relogin`).
        package let relogin: String

        package init(id: Int64, teamID: String, clientID: String, sharedApp: Bool = false, relogin: String) {
            self.id = id
            self.teamID = teamID
            self.clientID = clientID
            self.sharedApp = sharedApp
            self.relogin = relogin
        }

        private enum CodingKeys: String, CodingKey {
            case id, relogin
            case teamID = "team_id"
            case clientID = "client_id"
            case sharedApp = "shared_app"
        }
    }

    package let builtinApp: Bool
    package let accounts: [Account]

    package init(builtinApp: Bool, accounts: [Account]) {
        self.builtinApp = builtinApp
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
        case builtinApp = "builtin_app"
    }

    package init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        builtinApp = try box.decode(Bool.self, forKey: .builtinApp)
        accounts = try box.decodeIfPresent([Account].self, forKey: .accounts) ?? []
    }

    package static let args = ["slack", "accounts", "--json"]
}

/// Where a Reconnect / Re-login goes (plan B A7, A14).
package enum SlackReloginRoute: Equatable, Sendable {
    /// The build's own Slack app: `slack login` / `auth login` as before.
    case builtin
    /// The connect flow, skip-confirm, re-binding the account.
    case flow(SlackConnectTarget)
    /// No app to sign in with here (on the retired shared app, or no client
    /// id known): the connect section, for a link, a code or an MDM row.
    case connectSection

    /// The route of account `accountID` in `doc`. The legacy Workspace block
    /// (account #1) with no row yet signs in with the build's app when there
    /// is one, else goes to the connect section.
    package static func route(accountID: Int64, in doc: SlackAccountsDocument) -> Self {
        guard let account = doc.accounts.first(where: { $0.id == accountID }) else {
            return doc.builtinApp ? .builtin : .connectSection
        }
        switch account.relogin {
        case "builtin":
            return .builtin
        case "connect":
            guard ManagedPolicy.isSlackTeamID(account.teamID), ManagedPolicy.isSlackClientID(account.clientID) else {
                return .connectSection
            }
            return .flow(SlackConnectTarget(teamID: account.teamID, clientID: account.clientID, accountID: account.id))
        default:
            return .connectSection
        }
    }
}

/// Connecting a workspace's app by link, pasted code, MDM row or Reconnect
/// (screens spec §4.3/§4.5; plan B Task 14). Held on `AppState` beside the
/// listener host and the one consumer of its events. One flow at a time: a
/// start while a flow runs (here, or a legacy sign-in through
/// `externalBusy`) is refused. The flow lives in memory only: it has no
/// deadline (A22) and ends on its callback, **Cancel**, or the child's exit.
/// Owns every string of the flow's sheet.
@MainActor
@Observable
package final class SlackConnectFlowModel {
    package enum Failure: Equatable, Sendable {
        case teamMismatch, denied
        /// "Could not connect: <reason>."
        case other(String)
    }

    package enum Step: Equatable, Sendable {
        case idle
        /// A link reached the listener: nothing goes to Slack before **Connect**.
        case confirming(flow: String, target: SlackConnectTarget)
        /// `start` sent; the child has not answered yet (no flow id).
        case starting(SlackConnectTarget)
        case browser(flow: String, target: SlackConnectTarget, since: Date)
        case connected(workspace: String)
        case failed(Failure, retry: SlackConnectTarget)
    }

    package private(set) var step: Step = .idle {
        didSet { settleRun() }
    }
    /// The connect section's field.
    package var pasteText = "" {
        didSet { if pasteText != oldValue { pasteError = nil } }
    }
    package private(set) var pasteError: String?
    /// Bumped when a Reconnect sends the owner to the connect section (no app
    /// to sign in with): the pane unfolds the section and focuses its field.
    package private(set) var connectSectionRequest = 0
    /// The last request a pane acted on: a pane that mounts after the
    /// Reconnect (it opened Connections → Slack) still sees it once.
    @ObservationIgnored private var handledConnectSectionRequest = 0

    /// A link arrived and the confirm sheet is up: AppState brings the app
    /// forward on Connections → Slack.
    @ObservationIgnored package var onLink: (() -> Void)?
    /// An account was written (connected, or re-bound): reload and restart.
    @ObservationIgnored package var onConnected: ((SlackConnectedAccount) -> Void)?
    /// Another sign-in runs (`slack login`, `auth login`): no flow may start.
    @ObservationIgnored package var externalBusy: () -> Bool = { false }

    @ObservationIgnored private let host: SlackConnectListenerHost
    @ObservationIgnored private let now: () -> Date
    /// Cancel landed before the child named the started flow: cancel it once
    /// it does. Until then no new flow starts.
    @ObservationIgnored private var cancelAfterStart = false
    /// Flows the owner cancelled, until each one's answer arrives: a late
    /// `connected` is still shown (the account was written), the expected
    /// `failed(cancelled)` is not.
    @ObservationIgnored private var cancelledFlows: Set<String> = []

    package init(host: SlackConnectListenerHost, now: @escaping () -> Date = Date.init) {
        self.host = host
        self.now = now
        host.onEvent = { [weak self] in self?.handle($0) }
        host.onChildEnded = { [weak self] in self?.childEnded() }
    }

    // MARK: - State

    /// A flow runs or waits for the child's answer: starts are refused.
    package var isRunning: Bool {
        switch step {
        case .confirming, .starting, .browser: true
        case .idle, .connected, .failed: cancelAfterStart
        }
    }

    /// The paste field, MDM rows and Reconnect may start a flow now.
    package var canStart: Bool { !isRunning && !externalBusy() }

    /// The flow sheet is up (every step but idle).
    package var showsSheet: Bool { step != .idle }

    // MARK: - Starting

    /// The paste field's **Connect**: a link or code skips the confirm (the
    /// owner's own press); anything else is an inline error, nothing starts.
    @discardableResult
    package func connectPasted() -> Bool {
        guard let target = SlackConnectTarget.parse(pasteText) else {
            pasteError = pasteInvalid
            return false
        }
        guard start(target) else { return false }
        pasteText = ""
        return true
    }

    /// Starts a flow without the confirm (paste, MDM, Reconnect, the setup's
    /// admin connect). False when one already runs: nothing is sent.
    @discardableResult
    package func start(_ target: SlackConnectTarget) -> Bool {
        guard canStart else { return false }
        host.ensureRunning()
        step = .starting(target)
        if !host.send(.start(teamID: target.teamID, clientID: target.clientID, accountID: target.accountID)) {
            step = .failed(.other(listenerDown), retry: target)
        }
        return true
    }

    /// Where a Reconnect goes; `.builtin` is the caller's to run.
    @discardableResult
    package func reconnect(_ route: SlackReloginRoute) -> Bool {
        switch route {
        case .builtin:
            return false
        case let .flow(target):
            return start(target)
        case .connectSection:
            connectSectionRequest += 1
            return true
        }
    }

    /// The pane's check on appear and on each request: true once per
    /// request, so the section unfolds and its field takes focus once.
    package func takeConnectSectionRequest() -> Bool {
        guard connectSectionRequest > handledConnectSectionRequest else { return false }
        handledConnectSectionRequest = connectSectionRequest
        return true
    }

    // MARK: - Sheet buttons

    /// The confirm's **Connect**.
    package func confirm() {
        guard case let .confirming(flow, target) = step, !externalBusy() else { return }
        if host.send(.confirm(flow: flow)) {
            step = .browser(flow: flow, target: target, since: now())
        } else {
            step = .failed(.other(listenerDown), retry: target)
        }
    }

    /// **Cancel** on the confirm or the browser step: the child drops the
    /// flow; nothing is stored. The sheet closes at once.
    package func cancel() {
        switch step {
        case let .confirming(flow, _), let .browser(flow, _, _):
            cancelledFlows.insert(flow)
            host.send(.cancel(flow: flow))
        case .starting:
            cancelAfterStart = true
        case .idle, .connected, .failed:
            break
        }
        step = .idle
    }

    /// **Start again** after a failure: the same target, skip-confirm.
    package func startAgain() {
        guard case let .failed(_, retry) = step else { return }
        step = .idle
        start(retry)
    }

    /// **Done** / **Close**.
    package func dismiss() {
        switch step {
        case .connected, .failed: step = .idle
        default: break
        }
    }

    // MARK: - Events

    private func handle(_ event: SlackConnectEvent) {
        switch event {
        case .listening:
            break
        case .portBusy:
            failRunning(.other("port 18551 is busy"))
        case let .link(flow, teamID, clientID):
            // A link while a flow runs (or waits for its start's answer) is
            // refused and the running sheet stays. The child keeps one flow too
            // and answers such a link `busy`; one it took before our `start`
            // reached it would refuse that start forever (no deadline, A22), so
            // a link that is not shown is always cancelled.
            guard !isRunning else {
                cancelledFlows.insert(flow)
                host.send(.cancel(flow: flow))
                return
            }
            step = .confirming(flow: flow, target: SlackConnectTarget(teamID: teamID, clientID: clientID))
            onLink?()
        case let .browser(flow):
            browserOpened(flow)
        case let .connected(account):
            connected(account)
        case let .failed(flow, reason, message):
            failed(flow: flow, reason: reason, message: message)
        case .busy:
            // The answer to our start: another flow holds the child. (A link
            // opened during our flow answers busy too; it is not ours to show.)
            if case let .starting(target) = step {
                step = .failed(.other("another Slack connection is still running"), retry: target)
            } else if cancelAfterStart {
                cancelAfterStart = false
            }
        }
    }

    private func browserOpened(_ flow: String) {
        if cancelAfterStart {
            cancelAfterStart = false
            cancelledFlows.insert(flow)
            host.send(.cancel(flow: flow))
            return
        }
        guard case let .starting(target) = step else { return } // an unknown flow
        step = .browser(flow: flow, target: target, since: now())
    }

    private func connected(_ account: SlackConnectedAccount) {
        // Any written account reloads the list, whoever's flow it was.
        defer { onConnected?(account) }
        let ours: Bool = switch step {
        case let .browser(flow, _, _), let .confirming(flow, _): flow == account.flow
        // A cancelled flow's late success shows only while nothing newer runs.
        case .starting: false
        default: cancelledFlows.contains(account.flow) && !cancelAfterStart
        }
        // A connect that won the race with Cancel: the account is written.
        cancelledFlows.remove(account.flow)
        guard ours else { return }
        let name = account.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        step = .connected(workspace: name.isEmpty ? account.teamID : name)
    }

    private func failed(flow: String, reason: SlackConnectFailure, message: String) {
        if flow.isEmpty {
            // A refused start (bad ids, policy, purge): it answers the latest start.
            if cancelAfterStart {
                cancelAfterStart = false
            } else if case let .starting(target) = step {
                step = .failed(Self.failure(reason, message), retry: target)
            }
            return
        }
        if cancelledFlows.remove(flow) != nil { return }
        if cancelAfterStart {
            // The cancelled start's answer: the child began it, then failed it.
            cancelAfterStart = false
            return
        }
        switch step {
        case let .starting(target):
            // A start the child began, then could not open (its flow id
            // comes with the failure): it answers that start.
            step = reason == .cancelled ? .idle : .failed(Self.failure(reason, message), retry: target)
        case let .browser(current, target, _) where current == flow,
             let .confirming(current, target) where current == flow:
            step = reason == .cancelled ? .idle : .failed(Self.failure(reason, message), retry: target)
        default:
            break // an unknown flow
        }
    }

    /// The child ended: a flow it held is gone (the restart has none).
    private func childEnded() {
        cancelAfterStart = false
        cancelledFlows = []
        failRunning(.other(listenerDown))
    }

    private func failRunning(_ failure: Failure) {
        switch step {
        case let .confirming(_, target), let .starting(target), let .browser(_, target, _):
            step = .failed(failure, retry: target)
        case .idle, .connected, .failed:
            break
        }
    }

    private static func failure(_ reason: SlackConnectFailure, _ message: String) -> Failure {
        switch reason {
        case .teamMismatch: return .teamMismatch
        case .denied: return .denied
        default:
            var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasSuffix(".") { text.removeLast() }
            return .other(text.isEmpty ? "Slack did not finish the sign-in" : text)
        }
    }

    // MARK: - The setup's admin connect (plan B A4, Task 13)

    /// The flow a caller awaits (`run`), resumed when it ends.
    @ObservationIgnored private var runWaiter: CheckedContinuation<Bool, Never>?

    /// Starts `target` skip-confirm and returns once that flow ends: true when
    /// it connected, false when it failed, was cancelled or could not start.
    /// The ended flow leaves no sheet behind (the caller shows its own state).
    package func run(_ target: SlackConnectTarget) async -> Bool {
        guard runWaiter == nil, start(target) else { return false }
        return await withCheckedContinuation { waiter in
            runWaiter = waiter
            settleRun()
        }
    }

    private func settleRun() {
        guard let waiter = runWaiter else { return }
        let connected: Bool
        switch step {
        case .confirming, .starting, .browser: return
        case .connected: connected = true
        case .idle, .failed: connected = false
        }
        runWaiter = nil
        if step != .idle { step = .idle }
        waiter.resume(returning: connected)
    }

    // MARK: - Strings (screens spec §4.2–§4.4)

    package static let pasteInvalid =
        "That is not a Watchtower connect link or code. Copy it again from the app's About tab in Slack."
    static let listenerDown = "Watchtower's connect listener stopped"
    private var pasteInvalid: String { Self.pasteInvalid }
    private var listenerDown: String { Self.listenerDown }

    /// The sheet of the current step; nil while idle.
    package var sheet: SlackConnectSheetContent? { SlackConnectSheetContent(step: step) }

    /// The browser step's wait, once past 5 minutes (A22: no deadline; the
    /// line says how long, **Cancel** stays). nil before, or off that step.
    package func waitingLine(at date: Date) -> String? {
        guard case let .browser(_, _, since) = step else { return nil }
        let minutes = Int(max(0, date.timeIntervalSince(since)) / 60)
        guard minutes >= 5 else { return nil }
        return minutes < 120 ? "Waiting for Slack since \(minutes) min" : "Waiting for Slack since \(minutes / 60) h"
    }
}

/// What the connect sheet shows for one step of the flow (screens spec
/// §4.3): every string, the icon and the buttons. A pure value, so the
/// sheet's shots render any step.
package struct SlackConnectSheetContent: Equatable, Sendable {
    package enum Icon: Equatable, Sendable { case progress, success, warning, denied }

    package enum Action: Equatable, Sendable { case cancel, connect, done, close, startAgain }

    package struct Button: Equatable, Sendable {
        package let title: String
        package let action: Action
        /// The sheet's one prominent action.
        package let isPrimary: Bool
    }

    package let icon: Icon?
    package let title: String?
    package let body: String
    package let note: String?
    /// The confirm's disclosure line and its privacy link (#1769).
    package let disclosure: String?
    package let privacyLink: String?
    package let privacyURL: URL
    package let buttons: [Button]

    package init?(step: SlackConnectFlowModel.Step) {
        var icon: Icon?, title: String?, note: String?, disclosure: String?
        let body: String
        let buttons: [Button]
        switch step {
        case .idle:
            return nil
        case let .confirming(_, target):
            title = "Connect a Slack workspace?"
            body = "A link asks Watchtower to connect workspace \(target.teamID) through app \(target.clientID). "
                + "Connect only if you opened this link yourself."
            // The link names no workspace, so its team id stands in.
            disclosure = SlackDisclosureCopy.connectLine(workspace: target.teamID)
            buttons = [Self.cancel, Button(title: "Connect", action: .connect, isPrimary: true)]
        case .starting, .browser:
            icon = .progress
            body = "Finish in your browser: Slack asks you to allow Watchtower."
            note = "If Slack says your admin must approve the app, connect again once they have."
            buttons = [Self.cancel]
        case let .connected(workspace):
            icon = .success
            title = "Connected to \(workspace)"
            body = "The first sync starts now. Digests and the Inbox fill in after it."
            buttons = [Button(title: "Done", action: .done, isPrimary: true)]
        case let .failed(failure, _):
            switch failure {
            case .teamMismatch:
                icon = .warning
                body = "Slack signed you in to a different workspace than the link names. Nothing was saved."
            case .denied:
                icon = .denied
                body = "You did not allow Watchtower in Slack. Nothing was saved."
            case let .other(reason):
                icon = .warning
                body = "Could not connect: \(reason). Nothing was saved."
            }
            buttons = [Button(title: "Close", action: .close, isPrimary: false),
                       Button(title: "Start again", action: .startAgain, isPrimary: true)]
        }
        self.icon = icon
        self.title = title
        self.body = body
        self.note = note
        self.disclosure = disclosure
        privacyLink = disclosure == nil ? nil : SlackDisclosureCopy.privacyLink
        privacyURL = SlackDisclosureCopy.privacyURL
        self.buttons = buttons
    }

    private static let cancel = Button(title: "Cancel", action: .cancel, isPrimary: false)
}
