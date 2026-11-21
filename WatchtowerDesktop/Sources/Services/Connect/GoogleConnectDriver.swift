import Foundation
import WatchtowerCore

/// What the Google driver uses of `GoogleAccountsViewModel`: the add sheet's
/// own sign-in, so its one-flow rule (`isConnecting`) holds for both.
@MainActor
protocol GoogleConnectModel: AnyObject {
    var isConnecting: Bool { get }
    var error: String? { get }
    var connectRows: [ConnectAccountRow] { get }
    /// The running `addAccount` sign-in.
    var addTask: Task<Void, Never>? { get }
    func addAccount(
        calendar: Bool, gmail: Bool, clientID: String, clientSecret: String, daemonPolicy: DaemonRestartPolicy
    ) -> Bool
    func cancelConnect()
    func refreshAsync() async
}

extension GoogleAccountsViewModel: GoogleConnectModel {
    var connectRows: [ConnectAccountRow] { accounts.map { ConnectAccountRow(id: $0.id, ConnectionAccountState($0)) } }
}

/// The google playbook's driver (docs/guide/connect/google.md): `scopes`
/// picks Calendar, Gmail or both; the sign-in runs on Watchtower's own
/// client. A bring-your-own client is the own Google project's driver.
@MainActor
final class GoogleConnectDriver: ConnectServiceDriving {
    let service = "google"
    let secretKinds: Set<String> = []
    let flows = ConnectFlowBook(service: "google")

    private let model: any GoogleConnectModel
    private let policy: @MainActor () -> ManagedPolicy

    init(model: any GoogleConnectModel, policy: @escaping @MainActor () -> ManagedPolicy) {
        self.model = model
        self.policy = policy
    }

    func status() async -> ConnectStatus {
        ConnectStatus(service: service, accounts: model.connectRows.map(\.account),
                      policyLocked: !policyAllows(), flow: flows.statusFlow())
    }

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        if let refusal = ConnectOptions.unknown(options, allowed: ["scopes"], service: service) { return .failure(refusal) }
        let scopes = Set((options["scopes"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        guard !scopes.isEmpty, scopes.isSubset(of: ["calendar", "gmail"]) else {
            return .failure(.badArgs("scopes is calendar, gmail or calendar,gmail"))
        }
        guard !model.isConnecting, flows.current == nil else { return .failure(.busy) }
        let before = Set(model.connectRows.map(\.id))
        guard model.addAccount(calendar: scopes.contains("calendar"), gmail: scopes.contains("gmail"),
                               clientID: "", clientSecret: "", daemonPolicy: .restart) else {
            return .failure(.failed(model.error ?? "Google did not start the sign-in"))
        }
        let task = model.addTask
        return .success(flows.begin { [model, flows] id in
            await task?.value
            await model.refreshAsync()
            return ConnectOutcome.of(error: model.error, before: before, after: model.connectRows,
                                     cancelled: flows.wasCancelled(id), noun: "account")
        })
    }

    func wait(flowID: String) async -> ConnectWaitOutcome {
        flows.outcome(of: flowID)
    }

    func cancel(flowID: String) async {
        if flows.cancel(flowID) { model.cancelConnect() }
    }

    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        .failure(.badArgs("Google takes no secret here"))
    }

    func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        .failure(.badArgs("Google takes no fields"))
    }

    func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        .failure(.badArgs("Google has nothing to choose"))
    }

    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        nil
    }

    func policyAllows() -> Bool {
        PolicySourceMap.allowed(service, policy: policy())
    }
}
