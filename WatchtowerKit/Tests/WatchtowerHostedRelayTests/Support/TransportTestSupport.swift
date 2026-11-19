import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync

/// A `RelayHTTP` in front of another: `answer` may replace an op's answer (or throw, as a
/// lost network would) before the request reaches the backend; `download` and `upload` may
/// replace a blob GET's or PUT's status. Every GET and PUT it lets through or answers is counted, and
/// every op it is posted (`ops`).
final class InterceptingRelayHTTP: RelayHTTP, @unchecked Sendable {
    private struct State {
        var answer: ((Relay_V1_Request) throws -> Relay_V1_Response?)?
        var download: ((URL) -> Int?)?
        var upload: ((URL) -> Int?)?
        var gets: [URL] = []
        var puts: [URL] = []
        var ops: [String] = []
        var hold: ((Relay_V1_Request) -> Bool)?
        var held: CheckedContinuation<Void, Never>?
        var park: ((Relay_V1_Request) -> Bool)?
        var nextParked = 0
        var parked: [Int: (request: Relay_V1_Request, continuation: CheckedContinuation<Void, any Error>)] = [:]
    }

    private let base: any RelayHTTP
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ base: any RelayHTTP) {
        self.base = base
    }

    /// The op hook: nil lets the request through.
    func answer(_ hook: ((Relay_V1_Request) throws -> Relay_V1_Response?)?) {
        state.withLock { $0.answer = hook }
    }

    /// The blob GET hook: a status answers the GET with it and writes nothing.
    func download(_ hook: ((URL) -> Int?)?) {
        state.withLock { $0.download = hook }
    }

    /// The blob PUT hook: a status answers the PUT with it and stores nothing.
    func upload(_ hook: ((URL) -> Int?)?) {
        state.withLock { $0.upload = hook }
    }

    var gets: [URL] {
        state.withLock { $0.gets }
    }

    /// Holds the next op `matches` accepts until `release()` (`holding` once it waits).
    func holdNext(where matches: @escaping (Relay_V1_Request) -> Bool) {
        state.withLock { $0.hold = matches }
    }

    var holding: Bool {
        state.withLock { $0.held != nil }
    }

    func release() {
        let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state.held = nil }
            return state.held
        }
        held?.resume()
    }

    /// Parks every op `matches` accepts until `releaseParked()` (nil parks nothing more). A parked op whose task
    /// is cancelled ends with `CancellationError`, as a cancelled `URLSession` request does.
    func park(where matches: ((Relay_V1_Request) -> Bool)?) {
        state.withLock { $0.park = matches }
    }

    /// The ops parked now, in arrival order.
    var parked: [Relay_V1_Request] {
        state.withLock { $0.parked.sorted { $0.key < $1.key }.map(\.value.request) }
    }

    /// Lets every parked op go on.
    func releaseParked() {
        let all = state.withLock { state in
            defer { state.parked = [:] }
            return state.parked.values.map(\.continuation)
        }
        for continuation in all { continuation.resume() }
    }

    var puts: [URL] {
        state.withLock { $0.puts }
    }

    /// The case names of the ops posted over HTTPS, in order.
    var ops: [String] {
        state.withLock { $0.ops }
    }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let parsed = try? Relay_V1_Request(serializedBytes: body)
        if let op = parsed?.op {
            state.withLock { $0.ops.append(Mirror(reflecting: op).children.first?.label ?? "unknown") }
        }
        if let request = parsed,
           state.withLock({ state in
               guard let hold = state.hold, hold(request) else { return false }
               state.hold = nil
               return true
           }) {
            await withCheckedContinuation { continuation in state.withLock { $0.held = continuation } }
        }
        if let request = parsed, state.withLock({ $0.park?(request) ?? false }) {
            try await parkUntilReleased(request)
        }
        let hook = state.withLock { $0.answer }
        if let hook, let request = parsed, let response = try hook(request) {
            return (200, try response.serializedData())
        }
        return try await base.post(url, body: body, headers: headers)
    }

    private func parkUntilReleased(_ request: Relay_V1_Request) async throws {
        let id = state.withLock { state in
            state.nextParked += 1
            return state.nextParked
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    if Task.isCancelled { return true }
                    state.parked[id] = (request, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let parked = state.withLock { $0.parked.removeValue(forKey: id) }
            parked?.continuation.resume(throwing: CancellationError())
        }
    }

    func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
        let hook = state.withLock { state -> ((URL) -> Int?)? in
            state.puts.append(url)
            return state.upload
        }
        if let status = hook?(url) { return status }
        return try await base.put(url, file: file, headers: headers)
    }

    func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
        let hook = state.withLock { state -> ((URL) -> Int?)? in
            state.gets.append(url)
            return state.download
        }
        if let status = hook?(url) { return status }
        return try await base.get(url, to: file, maxBytes: maxBytes, headers: headers)
    }
}

/// Collects what a transport reports: its `relayEvents` and its `TransportEvent`s.
final class TransportEventLog: @unchecked Sendable {
    private let relay = OSAllocatedUnfairLock<[HostedRelayEvent]>(initialState: [])
    private let transport = OSAllocatedUnfairLock<[TransportEvent]>(initialState: [])
    private let fetched = OSAllocatedUnfairLock(initialState: 0)
    private var reader: Task<Void, Never>?

    func attach(to subject: HostedRelayTransport) async {
        let stream = subject.relayEvents
        reader = Task { [relay] in
            for await event in stream { relay.withLock { $0.append(event) } }
        }
        await subject.setEventHandler { [transport] event in transport.withLock { $0.append(event) } }
        await subject.setEngineFetchedHandler { [fetched] in fetched.withLock { $0 += 1 } }
    }

    var relayEvents: [HostedRelayEvent] {
        relay.withLock { $0 }
    }

    var transportEvents: [TransportEvent] {
        transport.withLock { $0 }
    }

    /// How many times the engine-fetched handler fired.
    var fetches: Int {
        fetched.withLock { $0 }
    }

    func cancel() {
        reader?.cancel()
    }
}
