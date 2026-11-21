import Foundation

/// **Use my own Google project** through the connect assistant (agent
/// connect spec §5.4, preflight F5): its own path, on the page's model
/// (`AppState.ownGoogleProject`). The customer pastes the client secret into
/// the panel's card (`google_client_secret`), which goes to the model's
/// client form; `connect_start` with `own_client` (the Client ID the agent
/// read on **Credentials**) waits on the `.ownGoogleClient` confirm card,
/// then runs the page's **Connect** (`google add … --client-secret-stdin`).
///
/// Writers: only the model, as the page's buttons; Go stores the bundle and
/// ties the account after the sign-in. A JSON dropped on the page later
/// replaces the pasted secret (the last client given wins). The model has no
/// cancel: a flow ends when Go's sign-in does, and `cancel(flowID:)` does
/// nothing (the controller's Retry then waits for that end, `busy`).
@MainActor
package final class OwnGoogleProjectConnectDriver: ConnectServiceDriving {
    package let service = "google_own_project"
    package let secretKinds: Set<String> = [secretKind]

    package static let secretKind = "google_client_secret"
    package static let clientOption = "own_client"

    private let model: OwnGoogleProjectModel
    private let policy: @MainActor () -> ManagedPolicy
    private let accounts: @MainActor () -> [ConnectStatus.Account]
    /// The flow this driver started, while it runs.
    private var running: String?
    /// How each flow this driver started ended.
    private var ended: [String: ConnectWaitOutcome] = [:]
    private var waiters: [Int: (flowID: String, continuation: CheckedContinuation<ConnectWaitOutcome, Never>)] = [:]
    private var nextWaiter = 0
    private var flowCount = 0

    /// `accounts`: the Google accounts the done line counts.
    package init(
        model: OwnGoogleProjectModel,
        policy: @escaping @MainActor () -> ManagedPolicy,
        accounts: @escaping @MainActor () -> [ConnectStatus.Account] = { [] }
    ) {
        self.model = model
        self.policy = policy
        self.accounts = accounts
    }

    /// Google allowed, and own projects too (`AllowOwnGoogleProject`, POLICY-01).
    package func policyAllows() -> Bool {
        let policy = policy()
        return PolicySourceMap.allowed("google", policy: policy) && policy.ownGoogleProjectAllowed
    }

    package func status() async -> ConnectStatus {
        let flow = running.map { ConnectStatus.Flow(id: $0, state: "waiting_callback") }
        return ConnectStatus(service: service, accounts: accounts(), policyLocked: !policyAllows(), flow: flow)
    }

    package func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        tool == "connect_start" && options[Self.clientOption] != nil ? .ownGoogleClient : nil
    }

    package func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        guard kind == Self.secretKind else { return .failure(.badArgs("kind \(kind) is not an own Google project secret")) }
        guard policyAllows() else { return refusePolicy() }
        if model.isRunning { return .failure(.busy) }
        guard model.enterClientSecret(value) else { return .failure(.badArgs("the secret is empty")) }
        return .success(Data(#"{"result":"saved"}"#.utf8))
    }

    package func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        guard policyAllows() else { return refusePolicy() }
        guard options.keys.allSatisfy({ $0 == Self.clientOption }),
              let clientID = options[Self.clientOption]?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty
        else { return .failure(.badArgs("connect_start takes own_client: the new client's Client ID")) }
        if running != nil || model.isRunning || model.externalBusy() { return .failure(.busy) }
        guard model.hasTypedSecret else {
            return .failure(.badArgs("call request_secret with kind google_client_secret before connect_start"))
        }
        model.open()
        model.enterClientID(clientID)
        guard model.canConnect else { return .failure(.busy) }
        flowCount += 1
        let id = "own-google-\(flowCount)"
        running = id
        let model = model
        Task { [weak self] in
            await model.connect()
            let outcome: ConnectWaitOutcome = switch model.phase {
            case let .done(email): .connected(account: email.isEmpty ? "your Google account" : email)
            case let .failed(line): .failed(reason: line)
            case .idle, .checking: .failed(reason: OwnGoogleProjectModel.failedLine(""))
            }
            self?.finished(id, outcome)
        }
        return .success(id)
    }

    private func finished(_ id: String, _ outcome: ConnectWaitOutcome) {
        ended[id] = outcome
        if running == id { running = nil }
        for (key, waiter) in waiters where waiter.flowID == id {
            waiters[key] = nil
            waiter.continuation.resume(returning: outcome)
        }
    }

    package func wait(flowID: String) async -> ConnectWaitOutcome {
        if let outcome = ended[flowID] { return outcome }
        guard running == flowID else { return .failed(reason: Self.unknownFlow) }
        let key = nextWaiter
        nextWaiter += 1
        // A cancelled wait answers `.waiting` (the controller re-polls); the sign-in goes on.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .waiting) }
                waiters[key] = (flowID, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dropWaiter(key) }
        }
    }

    private func dropWaiter(_ key: Int) {
        waiters.removeValue(forKey: key)?.continuation.resume(returning: .waiting)
    }

    /// The page's sign-in has no cancel: the flow ends when Go's does.
    package func cancel(flowID: String) async {}

    package func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        .failure(.badArgs("the own Google project takes no fields: the Client ID is connect_start's own_client"))
    }

    package func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        .failure(.badArgs("the own Google project has nothing to choose"))
    }

    /// The organization's policy closes the page and drops its client (the detail shows the lock).
    private func refusePolicy<T>() -> Result<T, ConnectDriverError> {
        model.applyPolicy(allowed: false)
        return .failure(.policy)
    }

    package static let unknownFlow = "This sign-in ended before the assistant could see how. Check Connections → Google."
}
