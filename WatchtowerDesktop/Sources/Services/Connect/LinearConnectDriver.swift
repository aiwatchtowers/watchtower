import Foundation
import WatchtowerCore

/// What the Linear driver uses of `LinearAccountsViewModel`: the add sheet's
/// own sign-in, API-key add and team picks, under its one-command rule
/// (`isBusy`).
@MainActor
protocol LinearConnectModel: AnyObject {
    var isBusy: Bool { get }
    var error: String? { get }
    var accounts: [LinearAccount] { get }
    var teams: [Int64: [LinearTeam]] { get }
    var teamErrors: [Int64: String] { get }
    func addWithOAuth(daemonPolicy: DaemonRestartPolicy) async
    func addWithAPIKey(_ key: String, daemonPolicy: DaemonRestartPolicy) async -> Bool
    func loadTeams(for account: LinearAccount) async
    func setTeam(_ team: LinearTeam, selected: Bool, for account: LinearAccount) async
    func cancelConnect()
    func refreshAsync() async
}

extension LinearAccountsViewModel: LinearConnectModel {}

/// The linear playbook's driver (docs/guide/connect/linear.md): `oauth`
/// starts the sign-in, `linear_api_key` runs `linear add --api-key` with the
/// key on stdin, and `linear_teams` lists or picks the teams of the
/// workspace this run connected (else the newest one).
@MainActor
final class LinearConnectDriver: ConnectServiceDriving {
    let service = "linear"
    let secretKinds: Set<String> = ["linear_api_key"]
    let flows = ConnectFlowBook(service: "linear")

    private let model: any LinearConnectModel
    private let policy: @MainActor () -> ManagedPolicy
    /// The workspace this driver connected last: `choose` picks its teams.
    private var connectedID: Int64?
    /// `AppState.accountDaemonPolicy`: onboarding defers the restart, as the sheet does.
    private let daemonPolicy: @MainActor () -> DaemonRestartPolicy

    init(
        model: any LinearConnectModel,
        policy: @escaping @MainActor () -> ManagedPolicy,
        daemonPolicy: @escaping @MainActor () -> DaemonRestartPolicy = { .restart }
    ) {
        self.model = model
        self.policy = policy
        self.daemonPolicy = daemonPolicy
    }

    private var rows: [ConnectAccountRow] {
        model.accounts.map { ConnectAccountRow(id: $0.id, ConnectionAccountState($0)) }
    }

    func status() async -> ConnectStatus {
        ConnectStatus(service: service, accounts: rows.map(\.account), policyLocked: !policyAllows(), flow: flows.statusFlow())
    }

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        if let refusal = ConnectOptions.unknown(options, allowed: ["oauth"], service: service) { return .failure(refusal) }
        guard options["oauth"] == "true" else {
            return .failure(.badArgs("connect_start runs the Linear sign-in (oauth); a key goes through request_secret"))
        }
        guard !model.isBusy, flows.current == nil else { return .failure(.busy) }
        let before = Set(rows.map(\.id))
        let restart = daemonPolicy()
        return .success(flows.begin { [model, flows, weak self] id in
            await model.addWithOAuth(daemonPolicy: restart)
            await model.refreshAsync()
            let after = model.accounts
            self?.noteConnected(after, before: before)
            return ConnectOutcome.of(
                error: model.error, before: before,
                after: after.map { ConnectAccountRow(id: $0.id, ConnectionAccountState($0)) },
                cancelled: flows.wasCancelled(id), noun: "workspace")
        })
    }

    func wait(flowID: String) async -> ConnectWaitOutcome {
        flows.outcome(of: flowID)
    }

    func cancel(flowID: String) async {
        if flows.cancel(flowID) { model.cancelConnect() }
    }

    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        guard kind == "linear_api_key" else { return .failure(.badArgs("Linear takes no secret \(kind)")) }
        guard policyAllows() else { return .failure(.policy) }
        guard !model.isBusy else { return .failure(.busy) }
        let before = Set(rows.map(\.id))
        guard await model.addWithAPIKey(value, daemonPolicy: daemonPolicy()) else {
            return .failure(ConnectSecret.failure(model.error, secret: value, fallback: "linear add failed"))
        }
        noteConnected(model.accounts, before: before)
        let name = model.accounts.first { $0.id == connectedID }.map { ConnectionAccountState($0).name } ?? "workspace"
        return .success(ConnectSecretResult.data(state: "connected", account: ConnectSecret.scrub(name, value)))
    }

    private func noteConnected(_ accounts: [LinearAccount], before: Set<String>) {
        if let added = accounts.first(where: { !before.contains(String($0.id)) }) { connectedID = added.id }
    }

    func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        .failure(.badArgs("Linear takes no fields"))
    }

    func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        guard kind == "linear_teams" else { return .failure(.badArgs("Linear chooses only linear_teams")) }
        let account = model.accounts.first { $0.id == connectedID } ?? model.accounts.max { $0.id < $1.id }
        guard let account else { return .failure(.failed("no Linear workspace is connected")) }
        await model.loadTeams(for: account)
        if let error = model.teamErrors[account.id] { return .failure(.failed(error)) }
        var teams = model.teams[account.id] ?? []
        if let select {
            let wanted = Set(select)
            let unknown = wanted.subtracting(teams.map(\.key)).sorted()
            guard unknown.isEmpty else { return .failure(.badArgs("no team \(unknown.joined(separator: ", "))")) }
            // Only the picked teams sync: each team whose state differs flips.
            for team in teams where wanted.contains(team.key) != team.selected {
                await model.setTeam(team, selected: wanted.contains(team.key), for: account)
                if let error = model.error { return .failure(.failed(error)) }
            }
            if let error = model.teamErrors[account.id] { return .failure(.failed(error)) }
            teams = model.teams[account.id] ?? []
        }
        return .success(teams.map { ConnectChoice(id: $0.key, name: $0.name, selected: $0.selected) })
    }

    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        nil
    }

    func policyAllows() -> Bool {
        PolicySourceMap.allowed(service, policy: policy())
    }
}
