import Foundation
import WatchtowerCore

/// What the calendar driver uses of `CalendarAccountsViewModel`: the add
/// sheet's own CalDAV and ICS adds, under its one-run rule (`isRunning`).
@MainActor
protocol CalendarConnectModel: AnyObject {
    var isRunning: Bool { get }
    var error: String? { get }
    var connectRows: [ConnectAccountRow] { get }
    func addCalDAV(url: String, username: String, password: String) async -> Bool
    func addICS(feedURL: String) async -> Bool
    func refreshAsync() async
}

extension CalendarAccountsViewModel: CalendarConnectModel {
    var connectRows: [ConnectAccountRow] { accounts.map { ConnectAccountRow(id: $0.id, ConnectionAccountState($0)) } }
}

/// The calendar playbook's driver (docs/guide/connect/calendar.md). Both
/// paths end in a secret: `caldav_password` runs `caldav add` with the
/// `set_fields` URL and username, `ics_url` runs `caldav add-ics`; each
/// value reaches the CLI on stdin. There is no browser sign-in, so no flow.
@MainActor
final class CalendarConnectDriver: ConnectServiceDriving {
    let service = "calendar"
    let secretKinds: Set<String> = ["caldav_password", "ics_url"]

    private let model: any CalendarConnectModel
    private let policy: @MainActor () -> ManagedPolicy
    private var fields: [String: String] = [:]

    init(model: any CalendarConnectModel, policy: @escaping @MainActor () -> ManagedPolicy) {
        self.model = model
        self.policy = policy
    }

    func status() async -> ConnectStatus {
        ConnectStatus(service: service, accounts: model.connectRows.map(\.account), policyLocked: !policyAllows())
    }

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        .failure(.badArgs("a calendar connects through set_fields and request_secret, not connect_start"))
    }

    func wait(flowID: String) async -> ConnectWaitOutcome {
        .failed(reason: ConnectFlowBook.unknownFlow)
    }

    func cancel(flowID: String) async {}

    func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        let extra = fields.keys.filter { !["url", "username"].contains($0) }.sorted()
        guard extra.isEmpty else { return .failure(.badArgs("calendar has no field \(extra.joined(separator: ", "))")) }
        let next = self.fields.merging(fields) { $1 }.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let url = next["url"], CleartextRefusal.refusesCalDAV(url: url) {
            return .failure(.badArgs(CleartextRefusal.caldavCaption))
        }
        self.fields = next
        return .success(())
    }

    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        guard secretKinds.contains(kind) else { return .failure(.badArgs("calendar takes no secret \(kind)")) }
        guard policyAllows() else { return .failure(.policy) }
        let url = fields["url"] ?? "", username = fields["username"] ?? ""
        if kind == "caldav_password", url.isEmpty || username.isEmpty {
            return .failure(.badArgs("call set_fields with url and username first"))
        }
        guard !model.isRunning else { return .failure(.busy) }
        let before = Set(model.connectRows.map(\.id))
        let added = kind == "ics_url"
            ? await model.addICS(feedURL: value.trimmingCharacters(in: .whitespacesAndNewlines))
            : await model.addCalDAV(url: url, username: username, password: value)
        guard added else {
            return .failure(ConnectSecret.failure(model.error, secret: value, fallback: "the calendar was not added"))
        }
        await model.refreshAsync()
        let name = model.connectRows.first { !before.contains($0.id) }?.name ?? "calendar"
        return .success(ConnectSecretResult.data(state: "connected", account: ConnectSecret.scrub(name, value)))
    }

    /// The CalDAV server and login `caldav add` would use. nil for an ICS
    /// address (the secret is the place itself) and before url and username
    /// are set (the Send then refuses as `submitSecret` does).
    func secretDestination(kind: String) -> String? {
        guard kind == "caldav_password", let url = fields["url"], !url.isEmpty,
              let username = fields["username"], !username.isEmpty else { return nil }
        return ConnectAssistantPresentation.calendarDestination(url: url, username: username)
    }

    func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        .failure(.badArgs("calendar has nothing to choose"))
    }

    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        nil
    }

    func policyAllows() -> Bool {
        PolicySourceMap.allowed(service, policy: policy())
    }
}
