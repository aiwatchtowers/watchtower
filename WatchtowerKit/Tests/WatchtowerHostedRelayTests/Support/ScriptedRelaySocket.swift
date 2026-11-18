import Foundation
import os
import SwiftProtobuf
import WatchtowerHostedRelay
import WatchtowerRelayProto
import XCTest

/// The server end of one scripted WebSocket. It answers `Hello` and each
/// `Request` from its script as soon as the client sends them, and lets the
/// test push frames or close the socket from the server's side.
final class ScriptedRelaySocket: RelaySocket, @unchecked Sendable {
    enum HelloReply: Sendable {
        case ok
        case close(Int)
        case silent
    }

    enum Answer: Sendable {
        case ok
        case error(Relay_V1_ErrorCode)
        case silent
    }

    struct ClosedByClient: Error {}

    private struct State {
        var inbound: [RelaySocketMessage] = []
        var receiver: CheckedContinuation<RelaySocketMessage, any Error>?
        var sent: [Relay_V1_Frame] = []
        var pings = 0
        var pingWaiters: [CheckedContinuation<Void, any Error>] = []
        var closedWith: Int?
        /// Request writes held by `hangsRequests`, resumed (throwing) by the client's close or the writer's cancellation.
        var hungWrites: [Int: CheckedContinuation<Void, any Error>] = [:]
        var nextWrite = 0
        var cancelledWrites = 0
        /// The request write held by `stuckWrites` (the first one only): only `releaseStuck()` ends it.
        var stuck: [CheckedContinuation<Void, Never>] = []
        var stuckClaimed = false

        mutating func claimStuck() -> Bool {
            defer { stuckClaimed = true }
            return !stuckClaimed
        }
    }

    private let hello: HelloReply
    private let pongs: Bool
    private let subscribeAnswers: [String: Answer]
    private let requestAnswers: [String: Answer]
    private let hangsRequests: Bool
    private let stuckWrites: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `subscribe`: the answer per zone (every other zone, and every other op, gets `Ok`). `requests`:
    /// the answer per op case name (`getDownload`, ...) for the ops but `subscribe`. `hangsRequests`: a
    /// `Request` write never returns until the client closes the socket (`Hello` is still answered).
    init(
        hello: HelloReply = .ok,
        pongs: Bool = true,
        subscribe: [String: Answer] = [:],
        requests: [String: Answer] = [:],
        hangsRequests: Bool = false,
        stuckWrites: Bool = false
    ) {
        self.hello = hello
        self.pongs = pongs
        self.subscribeAnswers = subscribe
        self.requestAnswers = requests
        self.hangsRequests = hangsRequests
        self.stuckWrites = stuckWrites
    }

    // MARK: - What the test sees

    /// Every frame the client sent, in order.
    var sent: [Relay_V1_Frame] {
        state.withLock { $0.sent }
    }

    /// The zones of every `subscribe` the client sent, one list per request.
    var subscribes: [[String]] {
        sent.compactMap { frame in
            guard case .subscribe(let subscribe) = frame.request.op else { return nil }
            return subscribe.zones
        }
    }

    var pings: Int {
        state.withLock { $0.pings }
    }

    /// The close code the client closed with, nil while it has not.
    var closedWith: Int? {
        state.withLock { $0.closedWith }
    }

    /// True once the client waits in `receive` with nothing left to read:
    /// everything pushed so far has been handled.
    var drained: Bool {
        state.withLock { $0.receiver != nil && $0.inbound.isEmpty }
    }

    func waitForPings(_ count: Int) async {
        await spin { self.pings >= count }
    }

    func waitUntilDrained() async {
        await spin { self.drained }
    }

    func waitUntilClosedByClient() async {
        await spin { self.closedWith != nil }
    }

    // MARK: - The server's side

    func push(_ frame: Relay_V1_Frame) {
        // swiftlint:disable:next force_try
        deliver(.binary(try! frame.serializedData()))
    }

    /// `records` as a relay with "records_inline" sends them; `record` alone as an older one does.
    func pushZoneChanged(_ zone: String, seq: UInt64, records: [Relay_V1_Record] = [], record: Relay_V1_Record? = nil) {
        var changed = Relay_V1_ZoneChanged()
        changed.zone = zone
        changed.seq = seq
        changed.records = records
        if let record { changed.record = record }
        var frame = Relay_V1_Frame()
        frame.event.zoneChanged = changed
        push(frame)
    }

    func pushControl(_ kind: Relay_V1_ControlKind, detail: String = "") {
        var control = Relay_V1_Control()
        control.kind = kind
        control.detail = detail
        var frame = Relay_V1_Frame()
        frame.event.control = control
        push(frame)
    }

    func pushGoingAway() {
        var frame = Relay_V1_Frame()
        frame.goingAway = Relay_V1_GoingAway()
        push(frame)
    }

    func closeFromServer(_ code: Int) {
        deliver(.closed(code: code))
    }

    /// Answers every ping waiting for its pong (a socket built with `pongs: false`).
    func pong() {
        let waiters = state.withLock { state in
            defer { state.pingWaiters = [] }
            return state.pingWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - RelaySocket

    func send(_ data: Data) async throws {
        let frame = try Relay_V1_Frame(serializedBytes: data)
        if hangsRequests, case .request = frame.kind { try await hang() }
        if stuckWrites, case .request = frame.kind, state.withLock({ $0.claimStuck() }) {
            // A write that never returns, not on close and not on cancel (a stuck send).
            await withCheckedContinuation { continuation in state.withLock { $0.stuck.append(continuation) } }
            throw ClosedByClient()
        }
        try state.withLock { state in
            guard state.closedWith == nil else { throw ClosedByClient() }
            state.sent.append(frame)
        }
        switch frame.kind {
        case .hello:
            switch hello {
            case .ok:
                var reply = Relay_V1_Frame()
                reply.helloOk = Relay_V1_HelloOk()
                push(reply)
            case .close(let code):
                closeFromServer(code)
            case .silent:
                break
            }
        case .request(let request):
            answer(request)
        default:
            break
        }
    }

    /// Request writes stuck now (`stuckWrites`).
    var stuckCount: Int {
        state.withLock { $0.stuck.count }
    }

    /// Ends every stuck write (throwing, nothing written).
    func releaseStuck() {
        let all = state.withLock { state in
            defer { state.stuck = [] }
            return state.stuck
        }
        for continuation in all { continuation.resume() }
    }

    /// Request writes held now (`hangsRequests`).
    var hangingWrites: Int {
        state.withLock { $0.hungWrites.count }
    }

    /// Request writes given up because their writer was cancelled.
    var cancelledWrites: Int {
        state.withLock { $0.cancelledWrites }
    }

    /// A request write that never completes (nothing is written): it ends, throwing, when the client closes
    /// the socket or cancels the writer.
    private func hang() async throws {
        let id = state.withLock { state in
            state.nextWrite += 1
            return state.nextWrite
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let refusal: (any Error)? = state.withLock { state in
                    if Task.isCancelled {
                        state.cancelledWrites += 1
                        return CancellationError()
                    }
                    if state.closedWith != nil { return ClosedByClient() }
                    state.hungWrites[id] = continuation
                    return nil
                }
                if let refusal { continuation.resume(throwing: refusal) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let waiter = state.hungWrites.removeValue(forKey: id) else { return nil }
                state.cancelledWrites += 1
                return waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func receive() async throws -> RelaySocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<RelaySocketMessage, any Error>? = state.withLock { state in
                if !state.inbound.isEmpty { return .success(state.inbound.removeFirst()) }
                if state.closedWith != nil { return .failure(ClosedByClient()) }
                state.receiver = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let result: Result<Void, any Error>? = state.withLock { state in
                if state.closedWith != nil { return .failure(ClosedByClient()) }
                state.pings += 1
                if pongs { return .success(()) }
                state.pingWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func close(code: Int) async {
        let (receiver, waiters) = state.withLock { state in
            if state.closedWith == nil { state.closedWith = code }
            defer {
                state.receiver = nil
                state.pingWaiters = []
                state.hungWrites = [:]
            }
            return (state.receiver, state.pingWaiters + Array(state.hungWrites.values))
        }
        receiver?.resume(throwing: ClosedByClient())
        for waiter in waiters { waiter.resume(throwing: ClosedByClient()) }
    }

    // MARK: - Private

    private func answer(_ request: Relay_V1_Request) {
        var response = Relay_V1_Response()
        response.id = request.id
        var answer = Answer.ok
        if case .subscribe(let subscribe) = request.op, let zone = subscribe.zones.first {
            answer = subscribeAnswers[zone] ?? .ok
        } else if let op = request.op, let scripted = requestAnswers[Mirror(reflecting: op).children.first?.label ?? ""] {
            answer = scripted
        }
        switch answer {
        case .ok:
            response.ok = Relay_V1_Ok()
        case .error(let code):
            var error = Relay_V1_Error()
            error.code = code
            response.error = error
        case .silent:
            return
        }
        var frame = Relay_V1_Frame()
        frame.response = response
        push(frame)
    }

    private func deliver(_ message: RelaySocketMessage) {
        let receiver: CheckedContinuation<RelaySocketMessage, any Error>? = state.withLock { state in
            guard let receiver = state.receiver else {
                state.inbound.append(message)
                return nil
            }
            state.receiver = nil
            return receiver
        }
        receiver?.resume(returning: message)
    }
}

/// A `RelaySocketDialer` that hands out scripted sockets, one step per dial:
/// a socket, an HTTP status refusing the upgrade, or no answer. A dial with
/// nothing scripted gets a default `ScriptedRelaySocket`.
final class ScriptedRelayDialer: RelaySocketDialer, @unchecked Sendable {
    enum Step: Sendable {
        case socket(ScriptedRelaySocket)
        /// The socket, once the dial has waited this long on the clock (a cancelled wait fails the dial).
        case delayed(Duration, ScriptedRelaySocket)
        /// The socket, once `releaseHeld()` is called: a dial that does not end when cancelled.
        case held(ScriptedRelaySocket)
        case http(Int)
        case unreachable
    }

    struct Dial: Sendable {
        let url: URL
        let headers: [String: String]
        let at: Date
        /// The socket this dial returned, nil when it failed.
        let socket: ScriptedRelaySocket?
    }

    private struct State {
        var steps: [Step] = []
        var dials: [Dial] = []
        var held: [CheckedContinuation<Void, Never>] = []
    }

    /// Dials held now (`.held`).
    var heldCount: Int {
        state.withLock { $0.held.count }
    }

    /// Lets every held dial return its socket.
    func releaseHeld() {
        let all = state.withLock { state in
            defer { state.held = [] }
            return state.held
        }
        for continuation in all { continuation.resume() }
    }

    private let clock: any RelayClock
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(clock: any RelayClock) {
        self.clock = clock
    }

    func script(_ steps: [Step]) {
        state.withLock { $0.steps.append(contentsOf: steps) }
    }

    var dials: [Dial] {
        state.withLock { $0.dials }
    }

    /// The sockets dials returned, in order.
    var sockets: [ScriptedRelaySocket] {
        dials.compactMap(\.socket)
    }

    func waitForDials(_ count: Int) async {
        await spin { self.dials.count >= count }
    }

    func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
        let now = clock.now()
        let step: Step = state.withLock { state in
            state.steps.isEmpty ? .socket(ScriptedRelaySocket()) : state.steps.removeFirst()
        }
        var socket: ScriptedRelaySocket?
        if case .socket(let scripted) = step { socket = scripted }
        if case .delayed(_, let scripted) = step { socket = scripted }
        if case .held(let scripted) = step { socket = scripted }
        state.withLock { $0.dials.append(Dial(url: url, headers: headers, at: now, socket: socket)) }
        switch step {
        case .socket(let scripted):
            return scripted
        case let .delayed(wait, scripted):
            try await clock.sleep(for: wait)
            return scripted
        case .held(let scripted):
            await withCheckedContinuation { continuation in state.withLock { $0.held.append(continuation) } }
            return scripted
        case .http(let status):
            throw RelayDialError.http(status: status)
        case .unreachable:
            throw RelayDialError.unreachable
        }
    }
}

/// Yields until `condition` holds. No wall-clock cap: a condition that never holds hangs the
/// run (the Kit has no per-test watchdog; the CI step's timeout ends it). Always returns true
/// (callers kept their `guard`).
@discardableResult
func spin(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async -> Bool {
    while !condition() {
        await Task.yield()
    }
    return true
}

/// Reads a connection's events, each read waiting like `spin` (no wall-clock cap);
/// nil once the stream ended.
/// `pump`, when given, runs on every wait step (a scenario moves its manual clock there).
final class EventProbe: @unchecked Sendable {
    private var iterator: AsyncStream<HostedRelayClientEvent>.Iterator
    private let pump: (@Sendable () -> Void)?

    init(_ connection: HostedRelayConnection, pump: (@Sendable () -> Void)? = nil) {
        iterator = connection.events.makeAsyncIterator()
        self.pump = pump
    }

    func next(file: StaticString = #filePath, line: UInt = #line) async -> HostedRelayClientEvent? {
        let result = OSAllocatedUnfairLock<HostedRelayClientEvent??>(initialState: nil)
        Task {
            let event = await self.advance()
            result.withLock { $0 = .some(event) }
        }
        await spin(file: file, line: line) {
            if result.withLock({ $0 != nil }) { return true }
            pump?()
            return false
        }
        return result.withLock { $0 }.flatMap { $0 }
    }

    private func advance() async -> HostedRelayClientEvent? {
        await iterator.next()
    }
}
