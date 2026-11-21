import Foundation
import WatchtowerCore

// What the personal connect drivers (agent connect spec §5.3) share: the
// account rows `connect_status` lists, the book of flows a driver started,
// and the secret hygiene of every `request_secret` verb.

/// One account as `connect_status` lists it, with the id a driver diffs on
/// to find the account a sign-in added.
struct ConnectAccountRow: Equatable {
    let id: String
    let name: String
    /// "ok", "off" for a disabled account, else what needs attention.
    let status: String

    init(id: some CustomStringConvertible, _ state: ConnectionAccountState) {
        self.id = id.description
        name = state.name
        status = !state.enabled ? "off" : state.isOK ? "ok" : state.problem
    }

    var account: ConnectStatus.Account { ConnectStatus.Account(name: name, status: status) }
}

/// The sign-in flows one driver started. Each runs its view model call to
/// the end in its own task and books the outcome, so `wait` answers a
/// finished or unknown flow at once and never waits on a flow it did not
/// start (`ConnectServiceDriving.wait`).
@MainActor
final class ConnectFlowBook {
    private let service: String
    private(set) var current: String?
    private var outcomes: [String: ConnectWaitOutcome] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var cancelledIDs: Set<String> = []

    init(service: String) {
        self.service = service
    }

    /// Starts `run` as a new flow and returns its id; `run` gets that id.
    func begin(_ run: @escaping @MainActor (String) async -> ConnectWaitOutcome) -> String {
        let id = "\(service)-\(UUID().uuidString.prefix(12).lowercased())"
        current = id
        tasks[id] = Task { [weak self] in
            let outcome = await run(id)
            self?.end(id, outcome)
        }
        return id
    }

    /// Marks the running flow `id` cancelled; false (nothing to do) for any
    /// other id, so a cancel never reaches a flow it did not name.
    func cancel(_ id: String) -> Bool {
        guard current == id else { return false }
        cancelledIDs.insert(id)
        return true
    }

    func wasCancelled(_ id: String) -> Bool {
        cancelledIDs.contains(id)
    }

    private func end(_ id: String, _ outcome: ConnectWaitOutcome) {
        outcomes[id] = outcome
        tasks[id] = nil
        if current == id { current = nil }
    }

    func outcome(of id: String) -> ConnectWaitOutcome {
        if let outcome = outcomes[id] { return outcome }
        if id == current { return .waiting }
        return .failed(reason: Self.unknownFlow)
    }

    /// `connect_status`'s flow: the one this driver runs, if any.
    func statusFlow(state: String = "running") -> ConnectStatus.Flow? {
        current.map { ConnectStatus.Flow(id: $0, state: state) }
    }

    /// Awaits the flow's end (tests).
    func finished(_ id: String) async {
        await tasks[id]?.value
    }

    nonisolated static let unknownFlow =
        "Watchtower does not know this sign-in: it ended before this app run, or another window ended it"
    nonisolated static let cancelled = "the sign-in was cancelled"
}

/// How the personal drivers read a view model's end.
enum ConnectOutcome {
    /// The account a sign-in added: `error` wins, then a row not in `before`;
    /// without either the flow was cancelled, or it re-signed an account
    /// already listed (the agent reads `connect_status`).
    static func of(
        error: String?, before: Set<String>, after: [ConnectAccountRow], cancelled: Bool, noun: String
    ) -> ConnectWaitOutcome {
        if let error, !error.isEmpty { return .failed(reason: error) }
        if let added = after.first(where: { !before.contains($0.id) }) { return .connected(account: added.name) }
        if cancelled { return .failed(reason: ConnectFlowBook.cancelled) }
        return .failed(reason: "the sign-in ended without adding a \(noun): it was cancelled, or the \(noun) "
            + "was already connected; call connect_status to see the \(noun)s")
    }
}

/// A `request_secret` verb's result: never the secret.
struct ConnectSecretResult: Encodable {
    let state: String
    let account: String

    static func data(state: String, account: String) -> Data {
        (try? JSONEncoder().encode(Self(state: state, account: account))) ?? Data("{}".utf8)
    }
}

enum ConnectOptions {
    /// Refuses an option the service's playbook does not name.
    static func unknown(_ options: [String: String], allowed: Set<String>, service: String) -> ConnectDriverError? {
        let extra = options.keys.filter { !allowed.contains($0) }.sorted()
        guard !extra.isEmpty else { return nil }
        return .badArgs("\(service) takes no option \(extra.joined(separator: ", "))")
    }
}
