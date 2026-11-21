import Foundation
@testable import WatchtowerCore

/// A connect driver that records every call. Its status follows the flows
/// it starts. `wait` answers a queued outcome (`waitAnswers`) at once, else
/// holds until the test ends it (`endWait`); with `holdStatus` set,
/// `status()` holds until `releaseStatus()`. `until(_:)` waits, without
/// real time, for a condition on the fake.
@MainActor
class FakeConnectDriver: ConnectServiceDriving {
    let service: String
    var secretKinds: Set<String>
    var allowed = true
    var currentStatus: ConnectStatus
    var confirms: [String: ConnectAssistantConfirm] = [:]
    var startResults: [Result<String, ConnectDriverError>] = []
    var secretResult: Result<Data, ConnectDriverError> = .success(Data(#"{"stage":"install"}"#.utf8))
    var waitAnswers: [ConnectWaitOutcome] = []
    var holdStatus = false

    private(set) var starts: [[String: String]] = []
    private(set) var waits: [String] = []
    private(set) var cancels: [String] = []
    private(set) var secrets: [(kind: String, value: String)] = []
    private(set) var fields: [[String: String]] = []
    private(set) var heldWait: CheckedContinuation<ConnectWaitOutcome, Never>?
    private(set) var heldStatus: [CheckedContinuation<Void, Never>] = []
    private var flowCount = 0
    private var watchers: [(condition: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    init(service: String = "slack", secretKinds: Set<String> = ["slack_config_token"]) {
        self.service = service
        self.secretKinds = secretKinds
        currentStatus = ConnectStatus(service: service)
    }

    /// Returns once `condition` holds.
    func until(_ condition: @escaping () -> Bool) async {
        if condition() { return }
        await withCheckedContinuation { watchers.append((condition, $0)) }
    }

    func changed() {
        let ready = watchers.filter { $0.condition() }
        watchers.removeAll { $0.condition() }
        ready.forEach { $0.continuation.resume() }
    }

    func setFlow(_ flowID: String?) {
        let s = currentStatus
        currentStatus = ConnectStatus(service: s.service, accounts: s.accounts, policyLocked: s.policyLocked,
                                      flow: flowID.map { .init(id: $0, state: "waiting_callback") }, setup: s.setup)
    }

    func status() async -> ConnectStatus {
        if holdStatus {
            await withCheckedContinuation { heldStatus.append($0); changed() }
        }
        return currentStatus
    }

    func releaseStatus() {
        holdStatus = false
        heldStatus.forEach { $0.resume() }
        heldStatus = []
    }

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        starts.append(options)
        if !startResults.isEmpty { return startResults.removeFirst() }
        flowCount += 1
        setFlow("flow-\(flowCount)")
        return .success("flow-\(flowCount)")
    }

    func wait(flowID: String) async -> ConnectWaitOutcome {
        waits.append(flowID)
        defer { changed() }
        if !waitAnswers.isEmpty { return waitAnswers.removeFirst() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .waiting) }
                heldWait = continuation
                changed()
            }
        } onCancel: {
            Task { @MainActor in self.endWait(.waiting) }
        }
    }

    /// Ends the held `wait` with `outcome`; a finished flow leaves the status.
    func endWait(_ outcome: ConnectWaitOutcome) {
        if outcome != .waiting { setFlow(nil) }
        heldWait?.resume(returning: outcome)
        heldWait = nil
    }

    func cancel(flowID: String) async {
        cancels.append(flowID)
        setFlow(nil)
    }

    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        secrets.append((kind, value))
        return secretResult
    }

    func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        self.fields.append(fields)
        return .success(())
    }

    func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        .success([ConnectChoice(id: "10", name: "Acme board", selected: select?.contains("10") ?? false)])
    }

    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        if tool == "connect_start" {
            return options.keys.sorted().lazy.compactMap { self.confirms[$0] }.first
        }
        return options["vendor"].flatMap { confirms["\(tool):\($0)"] } ?? confirms[tool]
    }

    func policyAllows() -> Bool { allowed }
}

/// The company setup's fake: its draft view carries the stored client
/// secrets as a careless driver might; the controller must drop them.
@MainActor
final class FakeCompanyDriver: FakeConnectDriver, ConnectCompanyDriving {
    var draft = Data()
    private(set) var published: [String] = []
    private(set) var checks: [String] = []
    private var heldCheck: CheckedContinuation<Result<Data, ConnectDriverError>, Never>?

    init() {
        super.init(service: "company", secretKinds: ["google_client_secret", "atlassian_client_secret", "slack_config_token"])
        confirms["company_publish"] = .companyPublish(company: "Acme")
    }

    func draftView() -> Data { draft }

    func saveDraft(vendor: String, fields: [String: String]) async -> Result<Void, ConnectDriverError> { .success(()) }

    var isChecking: Bool { heldCheck != nil }

    func check(vendor: String) async -> Result<Data, ConnectDriverError> {
        checks.append(vendor)
        return await withCheckedContinuation {
            heldCheck = $0
            changed()
        }
    }

    func endCheck(_ result: Result<Data, ConnectDriverError>) {
        heldCheck?.resume(returning: result)
        heldCheck = nil
    }

    func publish(token: String) async -> Result<Data, ConnectDriverError> {
        published.append(token)
        return .success(Data(#"{"published":true}"#.utf8))
    }
}

/// A Slack driver that can run the Slack Live probe.
@MainActor
final class FakeProbingDriver: FakeConnectDriver, ConnectLiveProbing {
    private(set) var probes: [String] = []

    func liveProbe(provider: String) async -> Result<Data, ConnectDriverError> {
        probes.append(provider)
        return .success(Data(#"{"status":"ok"}"#.utf8))
    }
}

/// A clock that moves only when the test advances it. `sleepers(_:)` waits,
/// without real time, until that many sleeps are registered.
final class ConnectTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleeping: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleeping[id] = (deadline, continuation)
                let ready = takeWatchers()
                lock.unlock()
                ready.forEach { $0.resume() }
                // A cancel that landed before the sleep was registered found
                // nothing to remove: end the sleep here instead.
                if Task.isCancelled {
                    let entry = lock.withLock { sleeping.removeValue(forKey: id) }
                    entry?.continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let entry = lock.withLock { sleeping.removeValue(forKey: id) }
            entry?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time on; every sleep due by then wakes.
    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleeping.filter { $0.value.deadline <= current }
        due.keys.forEach { sleeping.removeValue(forKey: $0) }
        lock.unlock()
        due.values.forEach { $0.continuation.resume() }
    }

    /// Returns once at least `count` sleeps are registered.
    func sleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            watchers.append((count, continuation))
            let ready = takeWatchers()
            lock.unlock()
            ready.forEach { $0.resume() }
        }
    }

    /// Called under the lock.
    private func takeWatchers() -> [CheckedContinuation<Void, Never>] {
        let ready = watchers.filter { $0.count <= sleeping.count }.map(\.continuation)
        watchers.removeAll { $0.count <= sleeping.count }
        return ready
    }
}
