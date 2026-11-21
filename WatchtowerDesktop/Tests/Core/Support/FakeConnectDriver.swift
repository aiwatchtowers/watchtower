import Foundation
@testable import WatchtowerCore

/// A connect driver that records every call. `wait` holds until the test
/// ends it (`endWait`), or answers a queued outcome at once.
@MainActor
class FakeConnectDriver: ConnectServiceDriving {
    let service: String
    var secretKinds: Set<String>
    var allowed = true
    var currentStatus: ConnectStatus
    var confirms: [String: ConnectAssistantConfirm] = [:]
    var startResults: [Result<String, ConnectDriverError>] = []
    var secretResult: Result<Data, ConnectDriverError> = .success(Data(#"{"stage":"install"}"#.utf8))

    private(set) var starts: [[String: String]] = []
    private(set) var waits: [String] = []
    private(set) var cancels: [String] = []
    private(set) var secrets: [(kind: String, value: String)] = []
    private(set) var fields: [[String: String]] = []
    private var heldWait: CheckedContinuation<ConnectWaitOutcome, Never>?
    private var flowCount = 0

    init(service: String = "slack", secretKinds: Set<String> = ["slack_config_token"]) {
        self.service = service
        self.secretKinds = secretKinds
        currentStatus = ConnectStatus(service: service)
    }

    func status() async -> ConnectStatus { currentStatus }

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        starts.append(options)
        if !startResults.isEmpty { return startResults.removeFirst() }
        flowCount += 1
        return .success("flow-\(flowCount)")
    }

    var isWaiting: Bool { heldWait != nil }

    func wait(flowID: String) async -> ConnectWaitOutcome {
        waits.append(flowID)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { heldWait = $0 }
        } onCancel: {
            Task { @MainActor in self.endWait(.waiting) }
        }
    }

    /// Ends the held `wait` with `outcome`.
    func endWait(_ outcome: ConnectWaitOutcome) {
        heldWait?.resume(returning: outcome)
        heldWait = nil
    }

    func cancel(flowID: String) async { cancels.append(flowID) }

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
        return confirms[tool]
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
        return await withCheckedContinuation { heldCheck = $0 }
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
