import Foundation
import WatchtowerCore

/// What the Quick Connections driver uses of `ExternalConnectionsViewModel`:
/// the add sheet's own add (and sign-in), the Enabled switch and the tool
/// list, under its one-command rule (`isBusy`).
@MainActor
protocol QuickConnectionConnectModel: AnyObject {
    var isBusy: Bool { get }
    var error: String? { get }
    var connections: [ExternalConnection] { get }
    var toolLists: [Int: ExternalConnectionTools] { get }
    func addConnection(
        name: String, kind: String, command: String, args: [String], url: String, secretJSON: String?, useOAuth: Bool
    ) async
    func setEnabled(_ connection: ExternalConnection, enabled: Bool) async
    func loadTools(_ connection: ExternalConnection) async
    func cancelSignIn()
    func refreshAsync() async
}

extension ExternalConnectionsViewModel: QuickConnectionConnectModel {}

/// The quick-connections playbook's driver
/// (docs/guide/connect/quick-connections.md). `set_fields` collects the
/// server; `connect_start` adds it (and signs in with `oauth`), or
/// `request_secret mcp_secret` adds it with the key on stdin under
/// `header`/`variable`. A connection is added off: `connect_start` with
/// `enable` turns it on behind the customer's confirm card, and never for a
/// connection `AllowedQuickConnections` refuses.
@MainActor
final class QuickConnectionConnectDriver: ConnectServiceDriving {
    let service = "quickConnections"
    let secretKinds: Set<String> = ["mcp_secret"]
    let flows = ConnectFlowBook(service: "quickconnections")

    private let model: any QuickConnectionConnectModel
    private let policy: @MainActor () -> ManagedPolicy
    private var fields: [String: String] = [:]
    /// The connection the last confirm card named: only that start enables.
    private var confirmedEnable: String?

    static let fieldKeys: Set<String> = ["name", "kind", "command", "args", "url", "oauth", "header", "variable"]

    init(model: any QuickConnectionConnectModel, policy: @escaping @MainActor () -> ManagedPolicy) {
        self.model = model
        self.policy = policy
    }

    private var rows: [ConnectAccountRow] {
        model.connections.map { ConnectAccountRow(id: $0.id, ConnectionAccountState($0)) }
    }

    func status() async -> ConnectStatus {
        ConnectStatus(service: service, accounts: rows.map(\.account), policyLocked: !policyAllows(), flow: flows.statusFlow())
    }

    // MARK: - Start: add, or enable

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        if let refusal = ConnectOptions.unknown(options, allowed: ["enable"], service: service) { return .failure(refusal) }
        guard !model.isBusy, flows.current == nil else { return .failure(.busy) }
        if let name = options["enable"] { return await enable(name) }
        return add()
    }

    private func enable(_ name: String) async -> Result<String, ConnectDriverError> {
        defer { confirmedEnable = nil }
        await model.refreshAsync()
        guard let connection = model.connections.first(where: { $0.name == name }) else {
            return .failure(.badArgs("no Quick Connection named \(name)"))
        }
        guard connection.allowed(by: policy()) else { return .failure(.policy) }
        guard confirmedEnable == name else { return .failure(.failed("turning \(name) on needs the customer's confirm")) }
        guard !model.isBusy else { return .failure(.busy) }
        return .success(flows.begin { [model] _ in
            await model.setEnabled(connection, enabled: true)
            if let error = model.error { return .failed(reason: error) }
            await model.loadTools(connection)
            let count = model.toolLists[connection.id]?.tools.filter(\.readOnly).count
            return .connected(account: count.map { "\(name) (\($0) read-only tools)" } ?? name)
        })
    }

    private func add() -> Result<String, ConnectDriverError> {
        let server: Server
        switch readServer(withKey: false) {
        case let .success(value): server = value
        case let .failure(error): return .failure(error)
        }
        let before = Set(rows.map(\.id))
        return .success(flows.begin { [model, flows] id in
            await model.addConnection(name: server.name, kind: server.kind, command: server.command, args: server.args,
                                      url: server.url, secretJSON: nil, useOAuth: server.oauth)
            await model.refreshAsync()
            if model.error == nil, let row = model.connections.first(where: { $0.name == server.name }) {
                return .connected(account: row.name)
            }
            return ConnectOutcome.of(error: model.error, before: before, after: [],
                                     cancelled: flows.wasCancelled(id), noun: "connection")
        })
    }

    func wait(flowID: String) async -> ConnectWaitOutcome {
        flows.outcome(of: flowID)
    }

    func cancel(flowID: String) async {
        if flows.cancel(flowID) { model.cancelSignIn() }
    }

    // MARK: - Fields and the key

    func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        let extra = fields.keys.filter { !Self.fieldKeys.contains($0) }.sorted()
        guard extra.isEmpty else {
            return .failure(.badArgs("Quick Connections has no field \(extra.joined(separator: ", "))"))
        }
        let next = self.fields.merging(fields) { $1 }
        if let kind = next["kind"], !["stdio", "http"].contains(kind) { return .failure(.badArgs("kind is stdio or http")) }
        if let oauth = next["oauth"], !["true", "false"].contains(oauth) { return .failure(.badArgs("oauth is true or false")) }
        if let args = next["args"], (try? CommandArgsTokenizer.tokenize(args)) == nil {
            return .failure(.badArgs("args contain a quote that is never closed"))
        }
        self.fields = next
        return .success(())
    }

    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        guard kind == "mcp_secret" else { return .failure(.badArgs("Quick Connections takes no secret \(kind)")) }
        let server: Server
        switch readServer(withKey: true) {
        case let .success(value): server = value
        case let .failure(error): return .failure(error)
        }
        guard !model.isBusy, flows.current == nil else { return .failure(.busy) }
        let json: String?
        do {
            json = try ExternalConnectionSecretBuilder.json(kind: server.kind, pairs: [(key: server.keyName, value: value)])
        } catch {
            return .failure(.failed("Could not encode the secret"))
        }
        guard let json else { return .failure(.badArgs("call set_fields with header or variable first")) }
        await model.addConnection(name: server.name, kind: server.kind, command: server.command, args: server.args,
                                  url: server.url, secretJSON: json, useOAuth: false)
        if let error = model.error { return .failure(ConnectSecret.failure(error, secret: value, fallback: "")) }
        return .success(ConnectSecretResult.data(state: "added", account: server.name))
    }

    /// The `set_fields` server, checked as the add sheet checks it.
    private struct Server {
        let name, kind, command, url, keyName: String
        let args: [String]
        let oauth: Bool
    }

    private func readServer(withKey: Bool) -> Result<Server, ConnectDriverError> {
        let value = { (key: String) in (self.fields[key] ?? "").trimmingCharacters(in: .whitespaces) }
        let name = value("name"), kind = value("kind"), command = value("command"), url = value("url")
        guard !name.isEmpty, !kind.isEmpty else { return .failure(.badArgs("call set_fields with name and kind first")) }
        guard kind == "stdio" ? !command.isEmpty : !url.isEmpty else {
            return .failure(.badArgs(kind == "stdio" ? "a stdio server needs command" : "an http server needs url"))
        }
        let keyName = value(kind == "http" ? "header" : "variable")
        if withKey {
            guard !keyName.isEmpty else {
                return .failure(.badArgs(kind == "http" ? "call set_fields with header first" : "call set_fields with variable first"))
            }
            if kind == "http", ExternalConnectionTransportRule.sendsSecretInCleartext(url: url) {
                return .failure(.badArgs(ExternalConnectionTransportRule.caption))
            }
        } else if !keyName.isEmpty {
            return .failure(.badArgs("this server takes a key: call request_secret with mcp_secret instead"))
        }
        guard policy().connectionAllowed(kind: kind, url: url, command: command) else { return .failure(.policy) }
        let args = (try? CommandArgsTokenizer.tokenize(fields["args"] ?? "")) ?? []
        return .success(Server(name: name, kind: kind, command: kind == "stdio" ? command : "",
                               url: kind == "http" ? url : "", keyName: keyName,
                               args: kind == "stdio" ? args : [], oauth: kind == "http" && fields["oauth"] == "true"))
    }

    // MARK: - Rest

    func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        .failure(.badArgs("Quick Connections has nothing to choose"))
    }

    /// The `enable` card, unless the policy refuses that connection: then
    /// the start refuses it with no card.
    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        confirmedEnable = nil
        guard tool == "connect_start", let name = options["enable"] else { return nil }
        if let connection = model.connections.first(where: { $0.name == name }), !connection.allowed(by: policy()) {
            return nil
        }
        confirmedEnable = name
        return .quickConnection(name: name)
    }

    /// Off when the policy allows no Quick Connection at all; one it
    /// refuses is refused at its add or enable.
    func policyAllows() -> Bool {
        PolicySourceMap.allowed(service, policy: policy()) && policy().allowedQuickConnections?.isEmpty != true
    }
}
