import Foundation
import WatchtowerCore

/// What the mail driver uses of `EmailAccountsViewModel`: the add sheet's
/// own IMAP add and Outlook sign-in, under its one-flow rule (`isRunning`).
@MainActor
protocol EmailConnectModel: AnyObject {
    var isRunning: Bool { get }
    var error: String? { get }
    var connectRows: [ConnectAccountRow] { get }
    /// The running `connectOutlook` sign-in.
    var outlookTask: Task<Void, Never>? { get }
    func addImapAccount(
        host: String, port: Int, username: String, password: String, folder: String, security: String
    ) async -> Bool
    func connectOutlook()
    func cancelConnect()
    func refreshAsync() async
}

extension EmailAccountsViewModel: EmailConnectModel {
    var connectRows: [ConnectAccountRow] { accounts.map { ConnectAccountRow(id: $0.id, ConnectionAccountState($0)) } }
}

/// The mail playbook's driver (docs/guide/connect/mail.md): `outlook` starts
/// the Outlook sign-in; IMAP takes its settings through `set_fields` and the
/// password through `request_secret imap_password`, which runs `imap add`
/// with the password on stdin.
@MainActor
final class EmailConnectDriver: ConnectServiceDriving {
    let service = "email"
    let secretKinds: Set<String> = ["imap_password"]
    let flows = ConnectFlowBook(service: "email")

    private let model: any EmailConnectModel
    private let policy: @MainActor () -> ManagedPolicy
    private var fields: [String: String] = [:]

    static let fieldKeys: Set<String> = ["host", "port", "security", "username", "folder"]

    init(model: any EmailConnectModel, policy: @escaping @MainActor () -> ManagedPolicy) {
        self.model = model
        self.policy = policy
    }

    func status() async -> ConnectStatus {
        ConnectStatus(service: service, accounts: model.connectRows.map(\.account),
                      policyLocked: !policyAllows(), flow: flows.statusFlow())
    }

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        if let refusal = ConnectOptions.unknown(options, allowed: ["outlook"], service: service) { return .failure(refusal) }
        guard options["outlook"] == "true" else {
            return .failure(.badArgs("connect_start runs the Outlook sign-in; IMAP takes set_fields and request_secret"))
        }
        guard !model.isRunning, flows.current == nil else { return .failure(.busy) }
        let before = Set(model.connectRows.map(\.id))
        model.connectOutlook()
        guard model.isRunning, let task = model.outlookTask else {
            return .failure(.failed(model.error ?? "Outlook did not start the sign-in"))
        }
        return .success(flows.begin { [model, flows] id in
            await task.value
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

    func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        let extra = fields.keys.filter { !Self.fieldKeys.contains($0) }.sorted()
        guard extra.isEmpty else { return .failure(.badArgs("mail has no field \(extra.joined(separator: ", "))")) }
        var next = self.fields.merging(fields) { $1 }
        next = next.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let port = next["port"], Self.port(port) == nil {
            return .failure(.badArgs("port is a number from 1 to 65535"))
        }
        if let security = next["security"], !["ssl", "starttls", "none"].contains(security) {
            return .failure(.badArgs("security is ssl, starttls or none"))
        }
        if next["security"] == "none", CleartextRefusal.refusesNoTLS(host: next["host"] ?? "") {
            return .failure(.badArgs(CleartextRefusal.imapCaption))
        }
        self.fields = next
        return .success(())
    }

    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        guard kind == "imap_password" else { return .failure(.badArgs("mail takes no secret \(kind)")) }
        guard policyAllows() else { return .failure(.policy) }
        guard let host = fields["host"], !host.isEmpty, let username = fields["username"], !username.isEmpty else {
            return .failure(.badArgs("call set_fields with host and username first"))
        }
        guard !model.isRunning else { return .failure(.busy) }
        let before = Set(model.connectRows.map(\.id))
        let added = await model.addImapAccount(
            host: host, port: Self.port(fields["port"] ?? "") ?? 993, username: username, password: value,
            folder: fields["folder"].flatMap { $0.isEmpty ? nil : $0 } ?? "INBOX",
            security: fields["security"] ?? "ssl")
        guard added else {
            return .failure(ConnectSecret.failure(model.error, secret: value, fallback: "imap add failed"))
        }
        await model.refreshAsync()
        let name = model.connectRows.first { !before.contains($0.id) }?.name ?? username
        return .success(ConnectSecretResult.data(state: "connected", account: name))
    }

    func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        .failure(.badArgs("mail has nothing to choose"))
    }

    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        nil
    }

    func policyAllows() -> Bool {
        PolicySourceMap.allowed(service, policy: policy())
    }

    private static func port(_ text: String) -> Int? {
        Int(text).flatMap { (1...65535).contains($0) ? $0 : nil }
    }
}
